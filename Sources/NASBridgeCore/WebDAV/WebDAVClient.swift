import Foundation

/// 一筆 PROPFIND 結果。
public struct DAVEntry: Sendable, Equatable {
    /// 相對於 baseURL 的已解碼路徑：`/` 開頭、不帶結尾 `/`；根目錄為 `/`。
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date?
    public var created: Date?
}

public struct DAVQuota: Sendable, Equatable {
    public var available: Int64?
    public var used: Int64?
}

/// 伺服器支援的「部分寫入」方式（WebDAV 標準沒有定義，見 BACKGROUND.md）。
public enum PartialWriteMethod: String, Sendable {
    /// Apache mod_dav：`PUT` + `Content-Range: bytes a-b/*`
    case contentRange
    /// SabreDAV（Nextcloud 等）：`PATCH` + `X-Update-Range`
    case sabrePatch
    /// 不支援：寫入改走「本機暫存檔 + 關檔時整檔 PUT」
    case none
}

/// 同步（阻塞式）WebDAV 用戶端。
///
/// 為什麼是同步 API：呼叫者是 FUSE 的工作執行緒，FUSE callback 本身就是阻塞式，
/// 在這裡以 semaphore 等待 URLSession 完成最直接；**不可在 main thread 呼叫**。
/// 執行緒安全：URLSession 本身可並行，類別內無可變狀態。
public final class WebDAVClient: @unchecked Sendable {
    public let baseURL: URL
    private let session: URLSession
    private let trust: TLSTrustDelegate
    private let authorization: String

    /// 最近一次 TLS 交握看到的伺服器憑證指紋（供「信任此憑證」用）。
    public var lastSeenFingerprint: String? { trust.lastSeenFingerprint }
    /// 最近一次連線是否因伺服器憑證不受信任而失敗。
    public var trustRejected: Bool { trust.trustRejected }

    public init(baseURL: URL, username: String, password: String,
                pinnedSHA256: String = "", timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.trust = TLSTrustDelegate(pinnedSHA256: pinnedSHA256, username: username, password: password)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpMaximumConnectionsPerHost = 8
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
        // 預先帶 Basic：省掉每個請求一次 401 往返。只允許 HTTPS（MountProfile.validationError），不會明文外洩。
        self.authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    public convenience init?(profile: MountProfile, password: String, timeout: TimeInterval = 30) {
        guard let url = profile.baseURL else { return nil }
        self.init(baseURL: url, username: profile.username, password: password,
                  pinnedSHA256: profile.pinnedCertSHA256, timeout: timeout)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: - 路徑 ↔ URL

    /// 路徑片段允許的字元：urlPathAllowed 去掉分隔用的 `/` 與 `;`。
    private static let segmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;"))

    /// FUSE 路徑（`/a/b`）→ 完整 URL。
    /// macOS 傳入的檔名可能是 NFD（分解形式），Synology 端以 NFC 儲存，所以先正規化為 NFC。
    public func url(for path: String) -> URL {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let encoded = path.precomposedStringWithCanonicalMapping
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? String($0) }
        comps.percentEncodedPath = comps.percentEncodedPath + (encoded.isEmpty ? "/" : "/" + encoded.joined(separator: "/"))
        return comps.url!
    }

    /// 伺服器回傳的 href（絕對 URL 或絕對路徑，百分比編碼）→ 相對 baseURL 的解碼路徑。
    func relativePath(fromHref href: String) -> String? {
        guard let url = URL(string: href, relativeTo: baseURL) else { return nil }
        let full = url.absoluteURL.path(percentEncoded: false).precomposedStringWithCanonicalMapping
        let base = baseURL.path(percentEncoded: false).precomposedStringWithCanonicalMapping
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard full.hasPrefix(trimmedBase) else { return nil }
        var rel = String(full.dropFirst(trimmedBase.count))
        while rel.hasSuffix("/") { rel.removeLast() }
        return rel.isEmpty ? "/" : (rel.hasPrefix("/") ? rel : "/" + rel)
    }

    // MARK: - 請求基礎

    private func request(_ method: String, _ path: String, headers: [String: String] = [:]) -> URLRequest {
        var req = URLRequest(url: url(for: path))
        req.httpMethod = method
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    /// 阻塞等待一個 URLSessionTask 完成。
    private func wait<T: Sendable>(_ start: (@escaping @Sendable (T) -> Void) -> URLSessionTask) -> T {
        let sem = DispatchSemaphore(value: 0)
        let box = Box<T>()
        let task = start { box.value = $0; sem.signal() }
        task.resume()
        sem.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }

    private typealias Reply = (Data?, URLResponse?, Error?)

    /// 送出請求；回傳 2xx（或 `accept` 內）的資料與回應，其餘轉成 DAVError。
    @discardableResult
    private func send(_ req: URLRequest, body: Data? = nil, accept: Set<Int> = [], what: String) throws -> (Data, HTTPURLResponse) {
        let reply: Reply = wait { done in
            if let body {
                return session.uploadTask(with: req, from: body) { done(($0, $1, $2)) }
            }
            return session.dataTask(with: req) { done(($0, $1, $2)) }
        }
        return try check(reply, accept: accept, what: what)
    }

    private func check(_ reply: Reply, accept: Set<Int>, what: String) throws -> (Data, HTTPURLResponse) {
        if let error = reply.2 { throw DAVError.transport(error, what) }
        guard let http = reply.1 as? HTTPURLResponse else { throw DAVError.posix(EIO, "\(what): no HTTP response") }
        guard (200..<300).contains(http.statusCode) || accept.contains(http.statusCode) else {
            throw DAVError.http(http.statusCode, what)
        }
        return (reply.0 ?? Data(), http)
    }

    // MARK: - 讀取類

    private static let propfindBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop>
        <d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:creationdate/>
        </d:prop></d:propfind>
        """.utf8)

    /// PROPFIND。depth 0：只有 path 本身；depth 1：本身＋直接子項。
    public func propfind(_ path: String, depth: Int) throws -> [DAVEntry] {
        let req = request("PROPFIND", path, headers: ["Depth": "\(depth)", "Content-Type": "application/xml; charset=utf-8"])
        let (data, http) = try send(req, body: Self.propfindBody, what: "PROPFIND \(path)")
        guard http.statusCode == 207 else { throw DAVError.http(http.statusCode, "PROPFIND \(path)") }
        return MultistatusParser.parse(data).compactMap { r in
            guard let p = relativePath(fromHref: r.href) else { return nil }
            return DAVEntry(path: p, isDirectory: r.isCollection, size: r.contentLength ?? 0,
                            modified: r.lastModified, created: r.creationDate)
        }
    }

    /// RFC 4331 配額（Synology 有回報；不支援的伺服器回傳兩個 nil）。
    public func quota() throws -> DAVQuota {
        let body = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:"><d:prop><d:quota-available-bytes/><d:quota-used-bytes/></d:prop></d:propfind>
            """.utf8)
        let req = request("PROPFIND", "/", headers: ["Depth": "0", "Content-Type": "application/xml; charset=utf-8"])
        let (data, _) = try send(req, body: body, what: "PROPFIND quota")
        let first = MultistatusParser.parse(data).first
        return DAVQuota(available: first?.quotaAvailable, used: first?.quotaUsed)
    }

    /// 回傳 OPTIONS 的 `DAV` 標頭（用於偵測 sabredav-partialupdate）。
    public func davCapabilities() throws -> String {
        let (_, http) = try send(request("OPTIONS", "/"), what: "OPTIONS")
        return http.value(forHTTPHeaderField: "DAV") ?? ""
    }

    /// Range GET：讀取 [offset, offset+length)。到檔尾時回傳較短資料；超出檔尾回傳空資料。
    /// 伺服器忽略 Range（回 200 整檔）時自行切片，結果仍正確，只是較慢。
    public func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        let req = request("GET", path, headers: ["Range": "bytes=\(offset)-\(offset + Int64(length) - 1)"])
        let (data, http) = try send(req, accept: [416], what: "GET \(path)")
        switch http.statusCode {
        case 416: return Data()
        case 206: return data
        default:
            guard offset < Int64(data.count) else { return Data() }
            let start = Int(offset)
            return data.subdata(in: start..<min(start + length, data.count))
        }
    }

    /// 整檔下載到本機檔案（覆寫）。
    public func download(_ path: String, to dest: URL) throws {
        let req = request("GET", path)
        let reply: (URL?, URLResponse?, Error?) = wait { done in
            session.downloadTask(with: req) { tmp, resp, err in
                // 暫存檔在 handler 返回後即被刪除，必須在這裡搬走
                var moveError: Error?
                if let tmp {
                    do {
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.moveItem(at: tmp, to: dest)
                    } catch { moveError = error }
                }
                done((tmp == nil ? nil : dest, resp, err ?? moveError))
            }
        }
        _ = try check((nil, reply.1, reply.2), accept: [], what: "GET \(path)")
    }

    // MARK: - 寫入類

    public func put(_ path: String, data: Data) throws {
        try send(request("PUT", path), body: data, what: "PUT \(path)")
    }

    public func put(_ path: String, file: URL) throws {
        let req = request("PUT", path)
        let reply: Reply = wait { done in
            session.uploadTask(with: req, fromFile: file) { done(($0, $1, $2)) }
        }
        _ = try check(reply, accept: [], what: "PUT \(path)")
    }

    /// 部分寫入：把 data 寫到 path 的 offset 處（可延伸檔尾）。method 必須是探測過可用的方式。
    public func write(_ path: String, offset: Int64, data: Data, method: PartialWriteMethod) throws {
        let range = "\(offset)-\(offset + Int64(data.count) - 1)"
        switch method {
        case .contentRange:
            let req = request("PUT", path, headers: ["Content-Range": "bytes \(range)/*"])
            try send(req, body: data, what: "PUT(range) \(path)")
        case .sabrePatch:
            let req = request("PATCH", path, headers: ["Content-Type": "application/x-sabredav-partialupdate",
                                                       "X-Update-Range": "bytes=\(range)"])
            try send(req, body: data, what: "PATCH \(path)")
        case .none:
            throw DAVError.posix(ENOTSUP, "partial write not supported")
        }
    }

    public func delete(_ path: String) throws {
        try send(request("DELETE", path), what: "DELETE \(path)")
    }

    public func mkcol(_ path: String) throws {
        try send(request("MKCOL", path), what: "MKCOL \(path)")
    }

    public func move(_ from: String, to: String, overwrite: Bool = true) throws {
        let req = request("MOVE", from, headers: ["Destination": url(for: to).absoluteString,
                                                   "Overwrite": overwrite ? "T" : "F"])
        try send(req, what: "MOVE \(from)")
    }

    // MARK: - 部分寫入探測

    /// 以實際試寫判斷伺服器是否支援部分寫入（只信實測，不信標頭宣稱）。
    ///
    /// 若伺服器默默忽略 Content-Range，`PUT` 會把整檔覆寫成那一小段——拿真檔案試就會毀資料，
    /// 所以只在 `dir` 下建立隱藏的探測檔：寫 "AAAA" → 於 offset 2 寫 "B"（覆寫中段）
    /// → 於 offset 4 寫 "CC"（延伸檔尾）→ 讀回必須是 "AABACC"，結束後刪除。
    public func probePartialWrite(in dir: String) -> PartialWriteMethod {
        let probe = (dir == "/" ? "" : dir) + "/.nasbridge-probe-\(UUID().uuidString)"
        defer { try? delete(probe) }
        var candidates: [PartialWriteMethod] = [.contentRange]
        if let dav = try? davCapabilities(), dav.lowercased().contains("sabredav-partialupdate") {
            candidates.insert(.sabrePatch, at: 0)
        }
        for method in candidates {
            do {
                try put(probe, data: Data("AAAA".utf8))
                try write(probe, offset: 2, data: Data("B".utf8), method: method)
                try write(probe, offset: 4, data: Data("CC".utf8), method: method)
                if try read(probe, offset: 0, length: 64) == Data("AABACC".utf8) { return method }
            } catch {
                continue
            }
        }
        return .none
    }
}
