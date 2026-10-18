import Foundation

/// 檔案屬性（WebDAV 能提供的子集；權限、擁有者由 FUSE 橋接層統一填入）。
public struct FileAttributes: Sendable, Equatable {
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
    public var created: Date

    public init(isDirectory: Bool, size: Int64, modified: Date, created: Date) {
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.created = created
    }
}

/// FUSE 橋接層（`FuseHost`）唯一依賴的檔案系統抽象：POSIX 語意的同步 API。
///
/// 契約：
///   - 路徑皆為掛載點內的絕對路徑（`/` 開頭，根為 `/`）。
///   - 失敗一律丟 `DAVError`，其 `code` 即回給核心的 errno；其他錯誤視為 EIO。
///   - 會被多條 FUSE 執行緒並行呼叫，實作必須執行緒安全。
///   - handle 由 `open`/`create` 發出，直到 `release` 前有效。
///
/// 唯一實作是 `RemoteFileSystem`（POSIX 語意），協定差異再往下藏在 `RemoteStore`（WebDAV／FTP／SFTP／pCloud）；
/// 新增協定（SMB、S3…）只需另一個 `RemoteStore`，FuseHost 與 worker 不用改。
public protocol POSIXFileSystem: AnyObject, Sendable {
    var isReadOnly: Bool { get }

    func attributes(_ path: String) throws -> FileAttributes
    func list(_ path: String) throws -> [(name: String, attributes: FileAttributes)]
    func statfs() throws -> (total: Int64, free: Int64)

    func open(_ path: String, flags: Int32) throws -> UInt64
    func create(_ path: String) throws -> UInt64
    func read(handle: UInt64, offset: Int64, count: Int) throws -> Data
    func write(handle: UInt64, offset: Int64, data: Data) throws
    func flush(handle: UInt64) throws
    func release(handle: UInt64) throws

    func truncate(_ path: String, size: Int64) throws
    func mkdir(_ path: String) throws
    func unlink(_ path: String) throws
    func rmdir(_ path: String) throws
    func rename(_ from: String, to: String) throws
}

extension String {
    /// `/a/b/c` → `/a/b`；`/a` → `/`。
    var parentPath: String {
        guard let i = lastIndex(of: "/"), i != startIndex else { return "/" }
        return String(self[..<i])
    }

    /// `/a/b` + `c` → `/a/b/c`。
    func appendingPathSegment(_ name: String) -> String {
        self == "/" ? "/" + name : self + "/" + name
    }
}
