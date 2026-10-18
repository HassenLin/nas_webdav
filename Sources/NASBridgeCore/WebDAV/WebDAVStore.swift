import Foundation

/// `RemoteStore` 的 WebDAV 實作：`WebDAVClient` 的薄轉接層，多帶「探測到的部分寫入方式」這一項狀態。
/// （client 本身維持無狀態、可單獨測試；探測結果放這裡，而不是讓 client 變成可變物件。）
public final class WebDAVStore: RemoteStore, @unchecked Sendable {
    public let client: WebDAVClient
    public let partialWrite: PartialWriteMethod
    public var supportsRangeRead: Bool { true }
    /// MOVE 帶 `Overwrite: T`
    public var renameReplacesTarget: Bool { true }

    public init(client: WebDAVClient, partialWrite: PartialWriteMethod) {
        self.client = client
        self.partialWrite = partialWrite
    }

    /// 連線驗證（根路徑存在且為資料夾）＋選擇性探測部分寫入。
    /// 憑證不受信任時丟出帶 `untrustedFingerprint` 的錯誤，UI 可一鍵釘選。
    static func connect(_ account: Account, remotePath: String, password: String,
                        probeWrites: Bool, timeout: TimeInterval) throws -> WebDAVStore {
        guard let client = WebDAVClient(account: account, remotePath: remotePath, password: password, timeout: timeout) else {
            throw DAVError.posix(EINVAL, "Server URL is invalid.")
        }
        do {
            guard let root = try client.propfind("/", depth: 0).first, root.isDirectory else {
                throw DAVError.posix(ENOTDIR, "Remote path is not a folder.")
            }
        } catch let e as DAVError {
            if client.trustRejected {
                throw DAVError(code: EACCES, message: "The server certificate is not trusted.",
                               untrustedFingerprint: client.lastSeenFingerprint)
            }
            throw e.code == EACCES ? DAVError(code: EACCES, message: "Authentication failed. (\(e.message))") : e
        }
        return WebDAVStore(client: client, partialWrite: probeWrites ? client.probePartialWrite(in: "/") : .none)
    }

    public func stat(_ path: String) throws -> FileAttributes {
        guard let e = try client.propfind(path, depth: 0).first else { throw DAVError.posix(ENOENT) }
        return Self.attributes(of: e)
    }

    public func list(_ path: String) throws -> [RemoteEntry] {
        try client.propfind(path, depth: 1).filter { $0.path != path }.map {
            RemoteEntry(name: ($0.path as NSString).lastPathComponent, attributes: Self.attributes(of: $0))
        }
    }

    public func quota() throws -> (used: Int64?, available: Int64?) {
        let q = try client.quota()
        return (q.used, q.available)
    }

    public func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        try client.read(path, offset: offset, length: length)
    }

    public func download(_ path: String, to local: URL) throws { try client.download(path, to: local) }
    public func upload(_ path: String, data: Data) throws { try client.put(path, data: data) }
    public func upload(_ path: String, file local: URL) throws { try client.put(path, file: local) }

    public func write(_ path: String, offset: Int64, data: Data) throws {
        try client.write(path, offset: offset, data: data, method: partialWrite)
    }

    public func mkdir(_ path: String) throws { try client.mkcol(path) }
    /// DELETE 對資料夾是遞迴的；「只刪空目錄」由 `RemoteFileSystem.rmdir` 先檢查保證。
    public func remove(_ path: String, isDirectory: Bool) throws { try client.delete(path) }
    public func rename(_ from: String, to: String) throws { try client.move(from, to: to) }

    static func attributes(of e: DAVEntry) -> FileAttributes {
        let mtime = e.modified ?? Date(timeIntervalSince1970: 0)
        return FileAttributes(isDirectory: e.isDirectory, size: e.size, modified: mtime, created: e.created ?? mtime)
    }
}
