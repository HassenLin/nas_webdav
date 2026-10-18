import Foundation

/// `RemoteStore` 的 FTP／FTPS（explicit、implicit；主動、被動）與 SFTP 實作，透過常駐 lftp 行程。
///
/// 為什麼用 lftp 而不自寫協定：一個工具涵蓋 FTP 主動／被動、FTPS 兩種模式、SFTP（密碼或金鑰），
/// 自寫 FTP 的資料通道、TLS session reuse（許多 FTPS 伺服器要求資料通道沿用控制通道的 session）成本很高。
///
/// 能力（與續傳同一套協定機制，掛載時以隱藏探測檔實測，`probeOffsetTransfers`）：
///
/// | 方向 | lftp 指令 | 協定上 |
/// |---|---|---|
/// | 讀任意區段 | `get1 --source-region=起-訖`（訖不含） | FTP／FTPS `REST <offset>`＋`RETR`，讀到區段尾即關閉資料連線；SFTP 從該 offset 讀 |
/// | 檔尾接續寫 | `put -c`（先查遠端大小，從那裡接著送） | FTP／FTPS `REST <遠端大小>`＋`STOR`；SFTP 從該 offset 寫 |
///
/// 接續寫只能寫在檔尾：改寫既有內容時由 `RemoteFileSystem` 把該 handle 轉為本機暫存檔（關檔整檔上傳）。
/// 伺服器不支援時（例如 ProFTPD 未開 `AllowStoreRestart`）退回整檔下載／上傳。
/// 連線池：`poolSize` 個 session，FUSE 執行緒各自借用；大檔傳輸只佔住一條，其他操作仍可進行。
///
/// 併發：能力旗標只在 `RemoteStoreFactory.connect` 階段（交給 FUSE 之前、單執行緒）寫入，之後唯讀。
public final class LftpStore: RemoteStore, @unchecked Sendable {
    /// 唯讀掛載不探測：REST＋RETR 幾乎所有伺服器都支援（RFC 3659），預設可用
    public private(set) var supportsRangeRead = true
    public private(set) var partialWrite: PartialWriteMethod = .none
    /// 每次 Range 讀都要 REST＋RETR＋開一條資料連線（數個 RTT），區塊取大一點
    public var readChunkSize: Int { 4 << 20 }
    /// SFTP rename 遇到已存在的目的檔會失敗；FTP 依伺服器而定 → 一律由 RemoteFileSystem 先刪
    public var renameReplacesTarget: Bool { false }

    static let poolSize = 3

    private let root: RemoteRoot
    private let timeout: TimeInterval
    private let available: DispatchSemaphore
    private let lock = NSLock()
    private var idle: [LftpSession]

    /// - Throws: 找不到 lftp 時丟出含安裝指令的錯誤。
    init(account: Account, remotePath: String, password: String, timeout: TimeInterval) throws {
        guard let lftp = ToolLocator.lftp else { throw DAVError.posix(ENOENT, "FTP and SFTP need lftp: brew install lftp") }
        root = RemoteRoot(remotePath)
        self.timeout = timeout
        let command = LftpCommand(account: account, timeout: Int(timeout), knownHostsFile: Self.knownHostsFile.path)
        var env = ["LC_ALL": "C", "LANG": "C", "LFTP_PASSWORD": password]
        if account.protocol == .ftp, account.ftpSecurity != .none, let conf = Self.tls12Config {
            env["OPENSSL_CONF"] = conf.path
        }
        idle = (0..<Self.poolSize).map { _ in LftpSession(executable: lftp, prelude: command.prelude, environment: env) }
        available = DispatchSemaphore(value: Self.poolSize)
    }

    /// SFTP 主機金鑰（app 專用 known_hosts，首次連線記住）
    public static var knownHostsFile: URL { ConfigStore.directory.appendingPathComponent("known_hosts") }

    /// FTPS 一律限制在 TLS 1.2：**lftp 4.9.3＋OpenSSL 3 在 TLS 1.3 資料通道上傳會截斷檔尾**
    /// （SmartphoneFileManager 實測：1.5 MiB 上傳只存到 1.1～1.4 MiB，且 lftp 回報成功）。
    /// `ssl:priority` 只對 GnuTLS 版有效（Homebrew 的 lftp 連結 OpenSSL），所以改以 `OPENSSL_CONF`
    /// 指向只含 `MaxProtocol = TLSv1.2` 的設定檔，只影響 lftp 行程。上傳後另有大小驗證（`upload`）。
    static let tls12Config: URL? = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nasbridge-lftp-openssl-tls12.cnf")
        let text = """
            # NAS Bridge：lftp FTPS 限制 TLS 1.2（避開 lftp 的 TLS 1.3 上傳截斷）
            openssl_conf = nb_conf
            [nb_conf]
            ssl_conf = nb_ssl
            [nb_ssl]
            system_default = nb_tls
            [nb_tls]
            MaxProtocol = TLSv1.2

            """
        return (try? Data(text.utf8).write(to: url, options: .atomic)) == nil ? nil : url
    }()

    // MARK: - 連線池

    /// 借一條 session 執行指令。metadata 類設總時限；傳輸類（transfer）不設，斷線由 lftp `net:timeout` 偵測。
    @discardableResult
    private func run(_ command: String, transfer: Bool = false) throws -> [String] {
        available.wait()
        let session = lock.withLock { idle.removeLast() }
        defer {
            lock.withLock { idle.append(session) }
            available.signal()
        }
        // 每次嘗試的逾時 × 重試次數再加緩衝（lftp 內部會重連重試）
        return try session.run(command, timeout: transfer ? nil : timeout * 4 + 15)
    }

    private func q(_ path: String) throws -> String { try LftpCommand.quote(root.absolute(path)) }

    // MARK: - RemoteStore

    public func stat(_ path: String) throws -> FileAttributes {
        let abs = root.absolute(path)
        if path == "/" {
            // 掛載根：`cls -d` 對伺服器根目錄沒有父目錄可列；改用 `cd` 驗證存在且為資料夾。
            // 這也是 RemoteStoreFactory.connect 的連線檢查——lftp 的 open 是延遲連線，必須真的送一個指令才會登入
            try run("cd " + LftpCommand.quote(abs))
            return FileAttributes(isDirectory: true, size: 0, modified: .distantPast, created: .distantPast)
        }
        let lines = try run("cls -d -l --time-style=+%s " + LftpCommand.quoteGlob(abs))
        guard let item = LftpListingParser.parse(lines).first else { throw DAVError.posix(ENOENT) }
        return Self.attributes(item)
    }

    public func list(_ path: String) throws -> [RemoteEntry] {
        let abs = root.absolute(path)
        let lines = try run("cls -l -a --time-style=+%s " + LftpCommand.quoteGlob(abs == "/" ? "/" : abs + "/"))
        return LftpListingParser.parse(lines)
            .filter { $0.path.parentPath == abs }
            .map { RemoteEntry(name: ($0.path as NSString).lastPathComponent, attributes: Self.attributes($0)) }
    }

    /// FTP 沒有配額指令；SFTP 的 statvfs 擴充 lftp 不支援 → 不回報（FUSE 層給一個很大的值）
    public func quota() throws -> (used: Int64?, available: Int64?) { (nil, nil) }

    /// 讀 [offset, offset+length)：`get1 --source-region` 只取該區段到本機暫存檔再讀回。
    public func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        let tmp = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try run("get1 --source-region=\(offset)-\(offset + Int64(length)) " + q(path) + " -o " + LftpCommand.quote(tmp.path),
                    transfer: true)
        } catch let e as DAVError where e.message.contains("file size decreased") {
            // 區段跨過檔尾（最後一個區塊）：lftp 已把讀到檔尾為止的資料寫入暫存檔，才抱怨長度不足——這正是要的結果。
            // 不先 stat 截短區段，是為了省下每個區塊一次額外往返
        }
        return (try? Data(contentsOf: tmp)) ?? Data()   // 起點已超出檔尾時 lftp 不建立檔案
    }

    public func download(_ path: String, to local: URL) throws {
        try run("get " + q(path) + " -o " + LftpCommand.quote(local.path), transfer: true)
    }

    public func upload(_ path: String, data: Data) throws {
        let tmp = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp)
        try upload(path, file: tmp)
    }

    public func upload(_ path: String, file local: URL) throws {
        try run("put " + LftpCommand.quote(local.path) + " -o " + q(path), transfer: true)
        // lftp 偶有回報成功但檔尾不完整的情況（見 `tls12Config`）：大小不符一律視為失敗，不讓使用者以為已存好
        let expected = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? nil
        let remote = try stat(path).size
        if let expected, remote != expected {
            throw DAVError.posix(EIO, "Upload incomplete: \(remote) of \(expected) bytes reached the server")
        }
    }

    /// 檔尾接續寫（呼叫者保證 offset＝遠端大小）：本機做一個「前 offset bytes 為洞、之後是 data」的稀疏檔，
    /// `put -c` 查到遠端大小＝offset 後只送 data 那段（REST offset＋STOR）。稀疏檔在 APFS 上不佔洞的空間。
    public func write(_ path: String, offset: Int64, data: Data) throws {
        let tmp = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fd = Darwin.open(tmp.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw DAVError.posix(errno) }
        let n = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }
        close(fd)
        guard n == data.count else { throw DAVError.posix(EIO, "temp write failed") }
        try run("put -c " + LftpCommand.quote(tmp.path) + " -o " + q(path), transfer: true)
        // 伺服器若忽略 REST（從 0 覆寫）或 lftp 截斷，大小就會不符：一律視為失敗
        let remote = try stat(path).size
        guard remote == offset + Int64(data.count) else {
            throw DAVError.posix(EIO, "Append incomplete: server has \(remote) of \(offset + Int64(data.count)) bytes")
        }
    }

    /// 以隱藏探測檔實測 Range 讀與檔尾接續寫（只信實測：伺服器忽略 REST 時 STOR 會把探測檔覆寫成片段）。
    /// 寫 "ABCD" → 接續寫 "EF" → 讀 [1,3) 必須是 "BC"、整檔必須是 "ABCDEF"；結束後刪除。
    func probeOffsetTransfers(in dir: String) {
        let probe = dir.appendingPathSegment(".nasbridge-probe-\(UUID().uuidString)")
        defer { try? remove(probe, isDirectory: false) }
        do {
            try upload(probe, data: Data("ABCD".utf8))
        } catch {
            return   // 連探測檔都寫不進去（唯讀帳號）：保持預設
        }
        supportsRangeRead = (try? read(probe, offset: 1, length: 2)) == Data("BC".utf8)
        do {
            try write(probe, offset: 4, data: Data("EF".utf8))
            let tmp = Self.tempURL()
            defer { try? FileManager.default.removeItem(at: tmp) }
            try download(probe, to: tmp)
            partialWrite = (try? Data(contentsOf: tmp)) == Data("ABCDEF".utf8) ? .append : .none
        } catch {
            partialWrite = .none
        }
    }

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nasbridge-\(UUID().uuidString)")
    }

    public func mkdir(_ path: String) throws { try run("mkdir " + q(path)) }

    public func remove(_ path: String, isDirectory: Bool) throws {
        try run((isDirectory ? "rmdir " : "rm ") + q(path))
    }

    public func rename(_ from: String, to: String) throws { try run("mv " + q(from) + " " + q(to)) }

    static func attributes(_ item: LftpListingParser.Item) -> FileAttributes {
        FileAttributes(isDirectory: item.isDirectory, size: item.size, modified: item.modified, created: item.modified)
    }
}
