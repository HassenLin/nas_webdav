import Foundation

/// `RemoteStore` 的 pCloud 實作（HTTP JSON API，https://docs.pcloud.com；移植自 SmartphoneFileManager 並改為同步）。
///
/// - **地區**：美國帳號只能打 `api.pcloud.com`、歐洲帳號只能打 `eapi.pcloud.com`（`PCloudRegion`）。
/// - 認證：OAuth2 access token，以 `Authorization: Bearer` 送出（不放 URL，避免出現在 log／proxy）。
/// - 回應一律 HTTP 200，成敗看 JSON 的 `result`（0＝成功），錯誤碼對應見 `error(_:_:method:)`。
/// - 所有操作以**路徑**指定（`path=`／`topath=`），與 FUSE 的路徑模型一致，不需維護 id 對照。
/// - 讀取：`getfilelink` 取得 CDN 連結後 Range GET；連結有效數小時，每個路徑快取 10 分鐘，寫入／改名／刪除即失效。
/// - 寫入：`uploadfile` 只能整檔上傳 → 部分寫入不支援（RemoteFileSystem 改走暫存檔）。
///
/// 為什麼是同步 API：呼叫者是 FUSE 的工作執行緒（同 `WebDAVClient`），**不可在 main thread 呼叫**。
public final class PCloudStore: RemoteStore, @unchecked Sendable {
    public var supportsRangeRead: Bool { true }
    public var partialWrite: PartialWriteMethod { .none }
    /// renamefile 遇到已存在的目的檔：行為未明文保證 → 由 RemoteFileSystem 先刪
    public var renameReplacesTarget: Bool { false }

    let region: PCloudRegion
    private let root: RemoteRoot
    private let token: String
    private let session: URLSession
    private let lock = NSLock()
    private var links: [String: (url: URL, expiry: Date)] = [:]

    init(region: PCloudRegion, remotePath: String, token: String, timeout: TimeInterval) {
        self.region = region
        self.root = RemoteRoot(remotePath)
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpMaximumConnectionsPerHost = 8
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: - 回應模型

    struct Metadata: Decodable, Sendable {
        let name: String
        let isfolder: Bool
        let size: Int64?
        let modified: String?
        let created: String?
        let contents: [Metadata]?
    }

    struct Envelope: Decodable, Sendable {
        let result: Int
        let error: String?
        let metadata: Metadata?
        let hosts: [String]?
        let path: String?
        let email: String?
        let quota: Int64?
        let usedquota: Int64?
    }

    // MARK: - 請求

    func url(_ method: String, _ parameters: [String: String]) -> URL {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = region.apiHost
        comps.path = "/" + method
        comps.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLQueryItem 不會編碼 `+`，伺服器會把它當空白——檔名含 + 時必須自行編碼
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url!
    }

    private func request(_ method: String, _ parameters: [String: String], httpMethod: String = "GET") -> URLRequest {
        var req = URLRequest(url: url(method, parameters))
        req.httpMethod = httpMethod
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private typealias Reply = (Data?, URLResponse?, Error?)

    /// 阻塞等待一個 URLSessionTask 完成（同 WebDAVClient）。
    private func wait(_ start: (@escaping @Sendable (Reply) -> Void) -> URLSessionTask) -> Reply {
        let sem = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        let task = start { box.value = $0; sem.signal() }
        task.resume()
        sem.wait()
        return box.value ?? (nil, nil, nil)
    }

    private final class ReplyBox: @unchecked Sendable { var value: Reply? }

    @discardableResult
    private func call(_ method: String, _ parameters: [String: String]) throws -> Envelope {
        let req = request(method, parameters)
        let reply = wait { done in session.dataTask(with: req) { done(($0, $1, $2)) } }
        return try decode(reply, method: method)
    }

    @discardableResult
    private func decode(_ reply: Reply, method: String) throws -> Envelope {
        if let error = reply.2 { throw DAVError.transport(error, "pCloud \(method)") }
        guard let data = reply.0, let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw DAVError.posix(EIO, "pCloud \(method): unexpected response")
        }
        guard env.result == 0 else { throw Self.error(env.result, env.error ?? "", method: method) }
        return env
    }

    /// pCloud 錯誤碼 → errno（https://docs.pcloud.com/errors/）
    static func error(_ code: Int, _ message: String, method: String) -> DAVError {
        let detail = message.isEmpty ? "pCloud \(method): error \(code)" : "\(message) (\(code))"
        let errno: Int32 = switch code {
        case 1000, 2000, 2094, 2095, 4000: EACCES       // 未登入、token 失效、登入失敗
        case 2002, 2005, 2009, 2055: ENOENT             // 路徑中的資料夾／檔案不存在
        case 2004: EEXIST                               // 資料夾已存在
        case 2006: ENOTEMPTY                            // 資料夾非空
        case 2003: EACCES                               // 無權限
        case 2008: ENOSPC                               // 超過配額
        case 2001: EINVAL                               // 名稱不合法
        default: EIO
        }
        return DAVError(code: errno, message: detail)
    }

    private func p(_ path: String) -> String { root.absolute(path) }

    private func invalidateLink(_ path: String) { lock.withLock { links[p(path)] = nil } }

    // MARK: - RemoteStore

    /// `stat` 只適用於檔案，資料夾改用 `listfolder nofiles=1`（只回傳子資料夾，最省流量的資料夾查詢）。
    public func stat(_ path: String) throws -> FileAttributes {
        let abs = p(path)
        do {
            if let m = try call("stat", ["path": abs]).metadata { return Self.attributes(m) }
        } catch let e as DAVError where e.code == EACCES {
            throw e
        } catch {
            // 對資料夾 stat 會回非「不存在」的錯誤，一律改查資料夾
        }
        guard let m = try call("listfolder", ["path": abs, "nofiles": "1", "noshares": "1"]).metadata else {
            throw DAVError.posix(ENOENT)
        }
        return Self.attributes(m)
    }

    public func list(_ path: String) throws -> [RemoteEntry] {
        (try call("listfolder", ["path": p(path)]).metadata?.contents ?? []).map {
            RemoteEntry(name: $0.name.precomposedStringWithCanonicalMapping, attributes: Self.attributes($0))
        }
    }

    public func quota() throws -> (used: Int64?, available: Int64?) {
        let info = try call("userinfo", [:])
        guard let total = info.quota, let used = info.usedquota else { return (nil, nil) }
        return (used, max(0, total - used))
    }

    /// 帳號 email（登入後顯示用）
    public func userEmail() throws -> String? { try call("userinfo", [:]).email }

    private func fileLink(_ path: String) throws -> URL {
        let abs = p(path)
        if let l = lock.withLock({ links[abs] }), l.expiry > Date() { return l.url }
        let env = try call("getfilelink", ["path": abs, "forcedownload": "1"])
        guard let host = env.hosts?.first, let linkPath = env.path, let url = URL(string: "https://\(host)\(linkPath)") else {
            throw DAVError.posix(EIO, "pCloud getfilelink: no download link")
        }
        lock.withLock { links[abs] = (url, Date().addingTimeInterval(600)) }
        return url
    }

    public func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        var req = URLRequest(url: try fileLink(path))
        req.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let reply = wait { done in session.dataTask(with: req) { done(($0, $1, $2)) } }
        if let error = reply.2 { throw DAVError.transport(error, "pCloud read \(path)") }
        guard let http = reply.1 as? HTTPURLResponse else { throw DAVError.posix(EIO, "pCloud read: no HTTP response") }
        let data = reply.0 ?? Data()
        switch http.statusCode {
        case 206: return data
        case 416: return Data()                       // 超出檔尾（含空檔）
        case 200:                                     // CDN 忽略 Range：自行切片
            guard offset < Int64(data.count) else { return Data() }
            return data.subdata(in: Int(offset)..<min(Int(offset) + length, data.count))
        default:
            invalidateLink(path)                      // 連結可能已過期，下次重取
            throw DAVError.http(http.statusCode, "pCloud read \(path)")
        }
    }

    public func download(_ path: String, to local: URL) throws {
        let req = URLRequest(url: try fileLink(path))
        let reply = wait { done in
            session.downloadTask(with: req) { tmp, resp, err in
                // 暫存檔在 handler 返回後即被刪除，必須在這裡搬走
                var moveError: Error?
                if let tmp {
                    do {
                        try? FileManager.default.removeItem(at: local)
                        try FileManager.default.moveItem(at: tmp, to: local)
                    } catch { moveError = error }
                }
                done((nil, resp, err ?? moveError))
            }
        }
        if let error = reply.2 { throw DAVError.transport(error, "pCloud download \(path)") }
        guard let http = reply.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            invalidateLink(path)
            throw DAVError.http((reply.1 as? HTTPURLResponse)?.statusCode ?? 0, "pCloud download \(path)")
        }
    }

    /// `uploadfile` 以 PUT＋`filename` 參數時，請求本文即檔案內容（不需 multipart）；同名檔案直接覆寫。
    /// `nopartial=1`：中斷時伺服器不留下殘缺檔。
    private func uploadRequest(_ path: String) -> URLRequest {
        let abs = p(path)
        return request("uploadfile", ["path": abs.parentPath, "filename": (abs as NSString).lastPathComponent,
                                      "nopartial": "1"], httpMethod: "PUT")
    }

    public func upload(_ path: String, data: Data) throws {
        invalidateLink(path)
        let req = uploadRequest(path)
        let reply = wait { done in session.uploadTask(with: req, from: data) { done(($0, $1, $2)) } }
        try decode(reply, method: "uploadfile")
    }

    public func upload(_ path: String, file local: URL) throws {
        invalidateLink(path)
        let req = uploadRequest(path)
        let reply = wait { done in session.uploadTask(with: req, fromFile: local) { done(($0, $1, $2)) } }
        try decode(reply, method: "uploadfile")
    }

    public func write(_ path: String, offset: Int64, data: Data) throws {
        throw DAVError.posix(ENOTSUP, "partial write not supported")   // partialWrite == .none：不會被呼叫
    }

    public func mkdir(_ path: String) throws { try call("createfolder", ["path": p(path)]) }

    /// 刪除會移到 pCloud 自己的垃圾桶（網頁版可復原）。`deletefolder` 只刪空資料夾（非空回 2006）。
    public func remove(_ path: String, isDirectory: Bool) throws {
        invalidateLink(path)
        try call(isDirectory ? "deletefolder" : "deletefile", ["path": p(path)])
    }

    public func rename(_ from: String, to: String) throws {
        invalidateLink(from)
        invalidateLink(to)
        let isFolder = try stat(from).isDirectory
        try call(isFolder ? "renamefolder" : "renamefile", ["path": p(from), "topath": p(to)])
    }

    // MARK: - 轉換

    static func attributes(_ m: Metadata) -> FileAttributes {
        let mtime = parseDate(m.modified) ?? Date(timeIntervalSince1970: 0)
        return FileAttributes(isDirectory: m.isfolder, size: m.isfolder ? 0 : (m.size ?? 0),
                              modified: mtime, created: parseDate(m.created) ?? mtime)
    }

    /// `modified`：`Thu, 21 Mar 2013 18:31:57 +0000`
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    static func parseDate(_ text: String?) -> Date? { text.flatMap { dateFormatter.date(from: $0) } }
}
