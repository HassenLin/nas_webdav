import Foundation

/// 寫入方式（掛載後顯示用，也決定 `RemoteFileSystem` 開檔時的儲存策略）。
public enum PartialWriteMethod: String, Sendable {
    /// WebDAV／Apache mod_dav：`PUT` + `Content-Range: bytes a-b/*`
    case contentRange
    /// WebDAV／SabreDAV（Nextcloud 等）：`PATCH` + `X-Update-Range`
    case sabrePatch
    /// 只能在檔尾接續寫（續傳式）：FTP／FTPS `REST <遠端大小>`＋`STOR`、SFTP 從該 offset 寫（lftp `put -c`）。
    /// 循序寫入（拷貝進來的檔案）直接送遠端；改寫既有內容時，該 handle 當場轉為本機暫存檔模式。
    case append
    /// 不支援部分寫入：寫入改走「本機暫存檔 + 關檔時整檔上傳」（pCloud、探測失敗的 FTP 伺服器）
    case none
}

/// 一個目錄項目（`RemoteStore.list` 的結果）。
public struct RemoteEntry: Sendable, Equatable {
    public var name: String
    public var attributes: FileAttributes

    public init(name: String, attributes: FileAttributes) {
        self.name = name
        self.attributes = attributes
    }
}

/// 遠端儲存的最小操作集合：`RemoteFileSystem`（POSIX 語意、快取、開檔 handle）唯一依賴的抽象。
///
/// 分工：
///   - `RemoteStore` 只做「一個操作＝一次遠端請求」的翻譯（WebDAV 請求、lftp 指令、pCloud API），
///     不快取、不知道 handle、不模擬 POSIX。
///   - `RemoteFileSystem` 負責 POSIX 語意：屬性快取、開檔策略（遠端 Range 讀／本機暫存檔）、寫入合併、
///     rmdir 非空檢查、rename 覆蓋目的、截斷。
///
/// 契約：
///   - 路徑為「掛載根」內的絕對路徑（`/` 開頭，根為 `/`）；實作自行加上帳號的遠端根路徑。
///   - 失敗一律丟 `DAVError`（`code` 即 errno）；不存在必須是 `ENOENT`（快取依此做負向快取）。
///   - 阻塞式、會被多條 FUSE 執行緒並行呼叫，實作必須執行緒安全；**不可在 main thread 呼叫**。
///   - 能力旗標不支援的方法（`read`、`write`）不會被呼叫。
public protocol RemoteStore: AnyObject, Sendable {
    /// 可讀取任意區段（WebDAV／pCloud 的 HTTP Range）。false 時開檔先整檔下載到本機暫存檔。
    var supportsRangeRead: Bool { get }
    /// 部分寫入方式；`.none` 時寫入走本機暫存檔＋關檔時整檔上傳。
    var partialWrite: PartialWriteMethod { get }
    /// `rename` 是否會覆蓋已存在的目的檔（POSIX 語意）。false 時 `RemoteFileSystem` 先刪除目的檔。
    var renameReplacesTarget: Bool { get }
    /// Range 讀的區塊大小：每次讀取的固定成本越高（FTP 每次 RETR 要開一條資料連線）越該取大。
    var readChunkSize: Int { get }

    func stat(_ path: String) throws -> FileAttributes
    /// 直接子項目（不含 `.`、`..` 與自己）。
    func list(_ path: String) throws -> [RemoteEntry]
    /// 配額；不支援時回傳兩個 nil。
    func quota() throws -> (used: Int64?, available: Int64?)

    /// 讀取 [offset, offset+length)；到檔尾回傳較短資料，超出檔尾回傳空資料。
    func read(_ path: String, offset: Int64, length: Int) throws -> Data
    /// 整檔下載到本機檔案（覆寫）。
    func download(_ path: String, to local: URL) throws
    /// 建立或覆寫整個檔案。
    func upload(_ path: String, data: Data) throws
    func upload(_ path: String, file local: URL) throws
    /// 部分寫入（可延伸檔尾）。`.append` 時呼叫者保證 offset＝目前遠端檔案大小。
    func write(_ path: String, offset: Int64, data: Data) throws

    func mkdir(_ path: String) throws
    /// 刪除檔案，或（isDirectory）刪除**空**目錄。
    func remove(_ path: String, isDirectory: Bool) throws
    func rename(_ from: String, to: String) throws
}

public extension RemoteStore {
    var readChunkSize: Int { 1 << 20 }   // 1 MiB：HTTP Range 的固定成本低
}

/// 依帳號協定建立 `RemoteStore` 的唯一對應（worker 與「測試連線」共用）。
public enum RemoteStoreFactory {
    /// 建立並驗證：連線、認證、遠端路徑存在且為資料夾。
    /// - Parameter probeWrites: 是否實測部分寫入（WebDAV、FTP／SFTP 會在遠端建立並刪除一個隱藏檔）；
    ///   唯讀掛載不探測（不能寫探測檔）：WebDAV 視為不支援、FTP／SFTP 假設 REST 讀可用（RFC 3659，幾乎都支援）。
    /// - Parameter credential: 密碼（WebDAV／FTP／SFTP）或 auth token（pCloud，`PCloudLogin` 取得）。
    public static func connect(_ account: Account, remotePath: String, credential: String,
                               probeWrites: Bool, timeout: TimeInterval = 30) throws -> any RemoteStore {
        if let msg = account.validationError() { throw DAVError.posix(EINVAL, msg) }
        let notFolder = DAVError.posix(ENOTDIR, "Remote path is not a folder.")
        switch account.protocol {
        case .webdav:
            return try WebDAVStore.connect(account, remotePath: remotePath, password: credential,
                                           probeWrites: probeWrites, timeout: timeout)
        case .ftp, .sftp:
            let store = try LftpStore(account: account, remotePath: remotePath, password: credential, timeout: timeout)
            guard try store.stat("/").isDirectory else { throw notFolder }
            if probeWrites { store.probeOffsetTransfers(in: "/") }
            return store
        case .pcloud:
            guard !credential.isEmpty else { throw DAVError.posix(EACCES, "Sign in to pCloud first.") }
            let store = PCloudStore(region: account.pcloudRegion, remotePath: remotePath, token: credential, timeout: timeout)
            guard try store.stat("/").isDirectory else { throw notFolder }
            return store
        }
    }
}

/// 遠端根路徑＋掛載內路徑 → 伺服器上的絕對路徑（FTP／SFTP／pCloud 用；WebDAV 併入 baseURL）。
/// macOS 傳入的檔名可能是 NFD（分解形式），伺服器多以 NFC 儲存，所以先正規化為 NFC。
struct RemoteRoot: Sendable {
    let root: String

    init(_ remotePath: String) {
        let parts = remotePath.split(separator: "/")
        root = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
    }

    func absolute(_ path: String) -> String {
        let p = path.precomposedStringWithCanonicalMapping
        if p == "/" { return root.isEmpty ? "/" : root }
        return root + p
    }
}
