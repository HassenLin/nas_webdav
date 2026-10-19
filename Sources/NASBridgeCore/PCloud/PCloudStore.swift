import Foundation

/// `RemoteStore` 的 pCloud 實作（HTTP JSON API，https://docs.pcloud.com；移植自 SmartphoneFileManager 並改為同步）。
///
/// - **地區**：美國帳號只能打 `api.pcloud.com`、歐洲帳號只能打 `eapi.pcloud.com`（`PCloudRegion`）。
/// - 認證：帳號密碼登入（`PCloudLogin`，在帳號編輯器做一次）取得的 auth token，每個請求帶 `auth=` 參數。
///   這裡只拿到 token；token 失效時的自動重新登入在主 app（`MountManager.pcloudToken`）。
/// - 回應一律 HTTP 200，成敗看 JSON 的 `result`（0＝成功），錯誤碼對應見 `error(_:_:method:)`。
/// - 所有操作以**路徑**指定（`path=`／`topath=`），與 FUSE 的路徑模型一致，不需維護 id 對照。
/// - 讀取：`getfilelink` 取得 CDN 連結後 Range GET；連結有效數小時，每個路徑快取 10 分鐘，寫入／改名／刪除即失效。
///   連結被拒（非 206/200/416）時換新連結重試一次。整檔下載（`download`）也以 Range 分區塊進行，
///   斷線時區塊就地重試，不丟已下載的部分。
/// - 寫入：不支援部分寫入（RemoteFileSystem 改走暫存檔，關檔時整檔上傳）。不超過一段（`uploadChunk`）用 `uploadfile`
///   一次送完；較大的走上傳工作階段（`upload_create`／`upload_write`／`upload_save`），斷線時以 `upload_info`
///   查伺服器已收到的位置接著寫——單一 `uploadfile` 傳大檔常逾時或斷線整份重來（SmartphoneFileManager 實測）。
///
/// 為什麼是同步 API：呼叫者是 FUSE 的工作執行緒（同 `WebDAVClient`），**不可在 main thread 呼叫**。
public final class PCloudStore: RemoteStore, @unchecked Sendable {
    public var supportsRangeRead: Bool { true }
    public var partialWrite: PartialWriteMethod { .none }
    /// renamefile 遇到已存在的目的檔：行為未明文保證 → 由 RemoteFileSystem 先刪
    public var renameReplacesTarget: Bool { false }

    let region: PCloudRegion
    private let root: RemoteRoot
    private let auth: String
    private let session: URLSession
    private let lock = NSLock()
    private var links: [String: (url: URL, expiry: Date)] = [:]

    init(region: PCloudRegion, remotePath: String, token: String, timeout: TimeInterval) {
        self.region = region
        self.root = RemoteRoot(remotePath)
        self.auth = token
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
        /// 資料夾 id（`upload_save` 只接受 folderid）
        var folderid: UInt64? = nil
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
        /// `upload_create` 的工作階段 ID
        let uploadid: UInt64?
        /// `upload_info`：工作階段已寫入的位元組數
        let size: Int64?

        private enum CodingKeys: String, CodingKey {
            case result, error, metadata, hosts, path, email, quota, usedquota, uploadid, size
        }

        /// 雷：`metadata` 多數方法是單一物件，但 `uploadfile` 回傳**陣列**（每個上傳檔一筆）——
        /// 只接受物件時，成功的上傳會被當成「unexpected response」。兩種都接受（取第一筆），
        /// 其他欄位也寬鬆解碼：只有 `result` 必要，多一個意料外的型別不該讓成功的操作變成失敗。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            result = try c.decode(Int.self, forKey: .result)
            error = try? c.decodeIfPresent(String.self, forKey: .error)
            metadata = (try? c.decodeIfPresent(Metadata.self, forKey: .metadata))
                ?? (try? c.decodeIfPresent([Metadata].self, forKey: .metadata))?.first
            hosts = try? c.decodeIfPresent([String].self, forKey: .hosts)
            path = try? c.decodeIfPresent(String.self, forKey: .path)
            email = try? c.decodeIfPresent(String.self, forKey: .email)
            quota = try? c.decodeIfPresent(Int64.self, forKey: .quota)
            usedquota = try? c.decodeIfPresent(Int64.self, forKey: .usedquota)
            uploadid = try? c.decodeIfPresent(UInt64.self, forKey: .uploadid)
            size = try? c.decodeIfPresent(Int64.self, forKey: .size)
        }
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

    /// 每個請求都帶 `auth=`（官方的 token 傳遞方式；HTTPS 下 URL 也是加密的）。
    /// 不用 POST 本文：`uploadfile` 的本文是檔案內容，token 只能放查詢參數，全部一致較單純。
    func request(_ method: String, _ parameters: [String: String], httpMethod: String = "GET") -> URLRequest {
        var params = parameters
        params["auth"] = auth
        var req = URLRequest(url: url(method, params))
        req.httpMethod = httpMethod
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
            // 附上回應開頭以利診斷（回應本文不含 token）
            let head = String(decoding: (reply.0 ?? Data()).prefix(200), as: UTF8.self)
            throw DAVError.posix(EIO, "pCloud \(method): unexpected response: \(head)")
        }
        guard env.result == 0 else {
            // 帶 token 的請求回登入類錯誤＝token 失效（登出、過期、改密碼）：告訴使用者怎麼做，
            // 而不是看不懂的「Log in failed. (2000)」
            if Self.expiredTokenCodes.contains(env.result) {
                throw DAVError.posix(EACCES, "pCloud sign-in has expired. Edit the account and sign in again.")
            }
            throw Self.error(env.result, env.error ?? "", method: method)
        }
        return env
    }

    /// 1000 未登入、2000 登入失敗、2094 token 無效、2095 token 已撤銷
    static let expiredTokenCodes: Set<Int> = [1000, 2000, 2094, 2095]

    /// pCloud 錯誤碼 → errno（https://docs.pcloud.com/errors/）
    static func error(_ code: Int, _ message: String, method: String) -> DAVError {
        let detail = message.isEmpty ? "pCloud \(method): error \(code)" : "\(message) (\(code))"
        let errno: Int32 = switch code {
        case 1000, 2000, 2094, 2095, 4000: EACCES       // 未登入、token 失效、登入失敗、登入嘗試過多
        case 2002, 2005, 2009, 2055, 2067: ENOENT       // 路徑中的資料夾／檔案不存在；2067＝上傳工作階段不存在／過期
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

    /// 連結數小時後失效，大檔可能讀不完：區塊請求被拒時換一個新連結重試該區塊一次
    public func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        do {
            return try readRange(path, offset: offset, length: length)
        } catch let e as DAVError where e.message.contains("HTTP") {
            return try readRange(path, offset: offset, length: length)   // readRange 已讓舊連結失效
        }
    }

    private func readRange(_ path: String, offset: Int64, length: Int) throws -> Data {
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

    /// 整檔下載＝逐塊 Range 讀取並寫入本機檔：斷線時只重試那一塊（`retrying`），不丟已下載的部分
    public func download(_ path: String, to local: URL) throws {
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let out = try FileHandle(forWritingTo: local)
        defer { try? out.close() }
        var offset: Int64 = 0
        while true {
            let block = try retrying("download \(path)") {
                try read(path, offset: offset, length: Self.downloadBlock)
            }
            try out.write(contentsOf: block)
            offset += Int64(block.count)
            if block.count < Self.downloadBlock { return }   // 短讀＝到檔尾
        }
    }

    // MARK: - 上傳

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
        let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > Int64(Self.uploadChunk) else {
            let req = uploadRequest(path)
            let reply = wait { done in session.uploadTask(with: req, fromFile: local) { done(($0, $1, $2)) } }
            try decode(reply, method: "uploadfile")
            return
        }
        try uploadSession(path, file: local, size: size)
    }

    /// 上傳工作階段（官方文件未列出、官方 Swift SDK 使用；SmartphoneFileManager 實作）：
    /// `upload_create` 建立 → `upload_write` 依位移寫入多段 → `upload_save` 存成檔案。
    /// 工作階段在 `upload_save` 前不會出現在資料夾裡，所以中途失敗不會留下殘缺檔。
    ///
    /// 與 SmartphoneFileManager 的差別：那邊把工作階段 ID 存檔、重開 app 後還能接著傳；
    /// 這裡的來源是 FUSE handle 的暫存檔，關檔失敗後就不存在了，只在這次呼叫內續傳（`retrying` 後以 `upload_info` 對位）。
    private func uploadSession(_ path: String, file local: URL, size: Int64) throws {
        guard let id = try call("upload_create", [:]).uploadid else {
            throw DAVError.posix(EIO, "pCloud upload_create: no upload id")
        }
        let reader = try FileHandle(forReadingFrom: local)
        defer { try? reader.close() }
        var offset: Int64 = 0
        while offset < size {
            let start = offset
            offset = try retrying("upload \(path)", resync: {
                // 斷線時那一段可能寫了一半：以伺服器實際收到的大小為準
                try self.call("upload_info", ["uploadid": String(id)]).size ?? start
            }) { from in
                try reader.seek(toOffset: UInt64(from))
                guard let chunk = try reader.read(upToCount: Self.uploadChunk), !chunk.isEmpty else {
                    throw DAVError.posix(EIO, "pCloud upload: local file became shorter while uploading")
                }
                var req = request("upload_write", ["uploadid": String(id), "uploadoffset": String(from)], httpMethod: "POST")
                req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let reply = wait { done in session.uploadTask(with: req, from: chunk) { done(($0, $1, $2)) } }
                try decode(reply, method: "upload_write")
                return from + Int64(chunk.count)
            } start: { start }
        }
        let parent = p(path).parentPath
        guard let folderID = try call("listfolder", ["path": parent, "nofiles": "1", "noshares": "1"]).metadata?.folderid else {
            throw DAVError.posix(ENOENT, "pCloud: \(parent)")
        }
        // 同名檔直接覆寫（與 uploadfile 相同）
        _ = try retrying("upload_save \(path)") {
            try call("upload_save", ["uploadid": String(id), "folderid": String(folderID),
                                     "name": (p(path) as NSString).lastPathComponent])
        }
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

    // MARK: - 暫時性錯誤重試

    /// 上傳每段大小：夠大才不會被請求往返拖慢，夠小才讓一次斷線只損失一段（同 SmartphoneFileManager）
    static let uploadChunk = 32 << 20
    /// 整檔下載每塊大小
    static let downloadBlock = 8 << 20
    /// 重試前的等待（秒）。總和不可太長：呼叫者是一個 FUSE 請求，受 `daemon_timeout` 限制
    static let retryDelays: [UInt32] = [1, 3, 10]

    /// 斷線、逾時、5xx 等「等一下可能就好」的錯誤；帳密錯誤、不存在、空間不足不會因等待而好轉
    static func isTransient(_ error: Error) -> Bool {
        guard let e = error as? DAVError else { return false }
        return [ETIMEDOUT, EHOSTUNREACH, EIO].contains(e.code)
    }

    private func retrying<T>(_ what: String, _ body: () throws -> T) throws -> T {
        try retrying(what, resync: { 0 }, { _ in try body() }, start: { 0 })
    }

    /// 執行 `body(位置)`；暫時性錯誤時等一下，以 `resync()` 重新取得起點後再試，次數用完才拋出
    private func retrying<T>(_ what: String, resync: () throws -> Int64, _ body: (Int64) throws -> T,
                             start: () -> Int64) throws -> T {
        var from = start()
        for delay in Self.retryDelays {
            do {
                return try body(from)
            } catch where Self.isTransient(error) {
                NSLog("pCloud %@: %@ — retry in %us", what, "\(error)", delay)
                sleep(delay)
                if let resumed = try? resync() { from = resumed }
            }
        }
        return try body(from)
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
