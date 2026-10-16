import Foundation

/// `POSIXFileSystem` 的 WebDAV 實作：把 POSIX 檔案語意翻譯成 WebDAV 請求。
///
/// 設計參考 miquels/webdavfs：讀取不落地（Range GET）、伺服器支援時寫入也不落地（部分寫入）。
/// 與 webdavfs 不同處：不支援部分寫入的伺服器（Synology 內建 WebDAV Server 屬此類的可能性高）
/// 不降為唯讀，而是退回「本機暫存檔＋整檔上傳」，仍可完整讀寫。
///
/// 已知限制（WebDAV 本身的限制）：
///   - 無權限／擁有者概念：chmod/chown 為 no-op（FuseHost 處理）。
///   - 同一檔案同時被多個 handle 以「暫存檔模式」寫入時，最後關閉者的內容勝出。
///   - 他人在 NAS 上的變更，最多延遲快取 TTL（5 秒）才看得到。
public final class WebDAVFileSystem: POSIXFileSystem, @unchecked Sendable {
    public let isReadOnly: Bool
    public let writeMethod: PartialWriteMethod

    static let readChunk = 1 << 20          // 讀取區塊：1 MiB
    static let writeCoalesceLimit = 4 << 20  // 寫入合併上限：4 MiB

    private let client: WebDAVClient
    private let cache = MetadataCache()
    private let tempDir: URL

    private let tableLock = NSLock()
    private var handles: [UInt64: OpenFile] = [:]
    private var nextHandle: UInt64 = 1
    private var quotaCache: (total: Int64, free: Int64, expiry: Date)?

    /// - Parameter writeMethod: 由呼叫端事先以 `WebDAVClient.probePartialWrite` 探測；
    ///   放在 init 外是為了讓建構子沒有網路副作用（測試可直接注入）。
    public init(client: WebDAVClient, readOnly: Bool, writeMethod: PartialWriteMethod) {
        self.client = client
        self.isReadOnly = readOnly
        self.writeMethod = writeMethod
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NASBridge-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: tempDir) }

    // MARK: - 屬性與目錄

    public func attributes(_ path: String) throws -> FileAttributes {
        var attrs = try remoteAttributes(path)
        overlayOpenHandle(path, &attrs)
        return attrs
    }

    public func list(_ path: String) throws -> [(name: String, attributes: FileAttributes)] {
        let entries = try client.propfind(path, depth: 1)
        var result: [(String, FileAttributes)] = []
        for e in entries where e.path != path {
            let name = (e.path as NSString).lastPathComponent
            var attrs = Self.attributes(of: e)
            cache.setAttributes(attrs, for: e.path)
            overlayOpenHandle(e.path, &attrs)
            result.append((name, attrs))
        }
        cache.setListing(result.map(\.0), for: path)
        return result
    }

    public func statfs() throws -> (total: Int64, free: Int64) {
        if let q = tableLock.withLock({ quotaCache }), q.expiry > Date() { return (q.total, q.free) }
        let quota = (try? client.quota()) ?? DAVQuota()
        // 伺服器不回報配額時給一個很大的值，避免 Finder 以為空間不足而拒絕拷貝
        let unknown: Int64 = 1 << 50
        let free = quota.available ?? unknown
        let total = quota.used.map { $0 + free } ?? unknown
        tableLock.withLock { quotaCache = (total, free, Date().addingTimeInterval(30)) }
        return (total, free)
    }

    private func remoteAttributes(_ path: String) throws -> FileAttributes {
        if let cached = cache.attributes(path) {
            guard let attrs = cached else { throw DAVError.posix(ENOENT) }
            return attrs
        }
        do {
            guard let e = try client.propfind(path, depth: 0).first else { throw DAVError.posix(ENOENT) }
            let attrs = Self.attributes(of: e)
            cache.setAttributes(attrs, for: path)
            return attrs
        } catch let error as DAVError where error.code == ENOENT {
            cache.setAttributes(nil, for: path)
            throw error
        }
    }

    /// 寫入中的檔案：大小以本機 handle 為準（遠端尚未更新）。
    private func overlayOpenHandle(_ path: String, _ attrs: inout FileAttributes) {
        guard let h = writableHandle(for: path) else { return }
        h.lock.withLock {
            attrs.size = h.size
            if h.dirty || h.pending != nil { attrs.modified = Date() }
        }
    }

    static func attributes(of e: DAVEntry) -> FileAttributes {
        let mtime = e.modified ?? Date(timeIntervalSince1970: 0)
        return FileAttributes(isDirectory: e.isDirectory, size: e.size, modified: mtime, created: e.created ?? mtime)
    }

    // MARK: - Handle 表

    private func register(_ h: OpenFile) -> UInt64 {
        tableLock.withLock {
            let id = nextHandle
            nextHandle += 1
            handles[id] = h
            return id
        }
    }

    private func handle(_ id: UInt64) throws -> OpenFile {
        guard let h = tableLock.withLock({ handles[id] }) else { throw DAVError.posix(EBADF) }
        return h
    }

    private func writableHandle(for path: String) -> OpenFile? {
        tableLock.withLock { handles.values.first { h in h.writable && h.lock.withLock { h.path } == path } }
    }

    // MARK: - 開檔

    public func open(_ path: String, flags: Int32) throws -> UInt64 {
        let writable = (flags & O_ACCMODE) != O_RDONLY
        let truncate = (flags & O_TRUNC) != 0
        if writable && isReadOnly { throw DAVError.posix(EROFS) }
        let base = try remoteAttributes(path)
        if base.isDirectory { throw DAVError.posix(EISDIR) }

        guard writable else {
            return register(OpenFile(path: path, writable: false, storage: .remote, size: base.size))
        }
        if truncate { cache.invalidate(path) }

        if writeMethod != .none {
            if truncate && base.size > 0 { try client.put(path, data: Data()) }
            return register(OpenFile(path: path, writable: true, storage: .remote, size: truncate ? 0 : base.size))
        }

        // 不支援部分寫入：整檔下載到暫存檔（O_TRUNC 時免下載）
        let url = tempDir.appendingPathComponent(UUID().uuidString)
        if truncate {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        } else {
            try client.download(path, to: url)
        }
        let h = try openLocal(path: path, url: url)
        h.dirty = truncate && base.size > 0
        return register(h)
    }

    public func create(_ path: String) throws -> UInt64 {
        if isReadOnly { throw DAVError.posix(EROFS) }
        // 立即建立空檔：之後的 getattr、他人列目錄都看得到，與本機檔案系統行為一致
        try client.put(path, data: Data())
        cache.invalidate(path)
        let now = Date()
        cache.setAttributes(FileAttributes(isDirectory: false, size: 0, modified: now, created: now), for: path)
        if writeMethod != .none {
            return register(OpenFile(path: path, writable: true, storage: .remote, size: 0))
        }
        let url = tempDir.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return register(try openLocal(path: path, url: url))
    }

    private func openLocal(path: String, url: URL) throws -> OpenFile {
        let fd = Darwin.open(url.path, O_RDWR)
        guard fd >= 0 else { throw DAVError.posix(errno, "open temp: \(String(cString: strerror(errno)))") }
        var st = stat()
        fstat(fd, &st)
        return OpenFile(path: path, writable: true, storage: .local(fd: fd, url: url), size: Int64(st.st_size))
    }

    // MARK: - 讀寫

    public func read(handle id: UInt64, offset: Int64, count: Int) throws -> Data {
        let h = try handle(id)
        return try h.lock.withLock {
            switch h.storage {
            case .local(let fd, _):
                var buf = Data(count: count)
                let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
                guard n >= 0 else { throw DAVError.posix(errno) }
                return buf.prefix(n)
            case .remote:
                try flushPending(h)
                return try readRemote(h, offset: offset, count: count)
            }
        }
    }

    /// 區塊對齊的 Range 讀取：核心常以 128 KiB～1 MiB 循序讀，1 MiB 區塊快取可大幅減少請求數。
    private func readRemote(_ h: OpenFile, offset: Int64, count: Int) throws -> Data {
        var out = Data()
        var pos = offset
        while out.count < count {
            if let c = h.readCache, pos >= c.offset, pos < c.offset + Int64(c.data.count) {
                let start = Int(pos - c.offset)
                let n = min(count - out.count, c.data.count - start)
                out.append(c.data.subdata(in: start..<start + n))
                pos += Int64(n)
                if c.short && pos >= c.offset + Int64(c.data.count) { break }   // 已到檔尾
                continue
            }
            let chunk = Int64(Self.readChunk)
            let chunkStart = pos - pos % chunk
            let need = Int(pos - chunkStart) + (count - out.count)
            let length = (need + Self.readChunk - 1) / Self.readChunk * Self.readChunk
            let data = Data(try client.read(h.path, offset: chunkStart, length: length))
            h.readCache = (chunkStart, data, data.count < length)
            if Int64(data.count) <= pos - chunkStart { break }                 // pos 已超出檔尾
        }
        return out
    }

    public func write(handle id: UInt64, offset: Int64, data: Data) throws {
        let h = try handle(id)
        guard h.writable else { throw DAVError.posix(EBADF) }
        try h.lock.withLock {
            switch h.storage {
            case .local(let fd, _):
                let n = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }
                guard n == data.count else { throw DAVError.posix(n < 0 ? errno : EIO) }
                h.dirty = true
            case .remote:
                h.readCache = nil
                if var p = h.pending, p.offset + Int64(p.data.count) == offset,
                   p.data.count + data.count <= Self.writeCoalesceLimit {
                    p.data.append(data)
                    h.pending = p
                } else {
                    try flushPending(h)
                    // 寫在檔尾之後（留洞）：部分寫入協定不保證補零，自行補上
                    h.pending = offset > h.size
                        ? (h.size, Data(count: Int(offset - h.size)) + data)
                        : (offset, data)
                }
                if h.pending!.data.count >= Self.writeCoalesceLimit { try flushPending(h) }
            }
            h.size = max(h.size, offset + Int64(data.count))
        }
    }

    /// 送出合併緩衝。失敗時丟棄緩衝並回報錯誤（避免同一批資料無限重送）。呼叫者須持有 h.lock。
    private func flushPending(_ h: OpenFile) throws {
        guard let p = h.pending else { return }
        h.pending = nil
        try client.write(h.path, offset: p.offset, data: p.data, method: writeMethod)
        cache.invalidate(h.path)
    }

    /// 把 handle 的變更送到伺服器。呼叫者須持有 h.lock。
    private func sync(_ h: OpenFile) throws {
        switch h.storage {
        case .remote:
            try flushPending(h)
        case .local(_, let url):
            guard h.dirty else { return }
            try client.put(h.path, file: url)
            h.dirty = false
            cache.invalidate(h.path)
        }
    }

    public func flush(handle id: UInt64) throws {
        let h = try handle(id)
        try h.lock.withLock { try sync(h) }
    }

    public func release(handle id: UInt64) throws {
        guard let h = tableLock.withLock({ handles.removeValue(forKey: id) }) else { throw DAVError.posix(EBADF) }
        try h.lock.withLock {
            defer {
                if case .local(let fd, let url) = h.storage {
                    close(fd)
                    try? FileManager.default.removeItem(at: url)
                }
            }
            try sync(h)
        }
    }

    // MARK: - 變更操作

    public func truncate(_ path: String, size: Int64) throws {
        if isReadOnly { throw DAVError.posix(EROFS) }
        defer { cache.invalidate(path) }
        if let h = writableHandle(for: path) {
            try h.lock.withLock {
                switch h.storage {
                case .local(let fd, _):
                    guard ftruncate(fd, off_t(size)) == 0 else { throw DAVError.posix(errno) }
                    h.dirty = true
                case .remote:
                    try flushPending(h)
                    h.readCache = nil
                    if size == 0 {
                        try client.put(h.path, data: Data())
                    } else if size > h.size {
                        try client.write(h.path, offset: h.size, data: Data(count: Int(size - h.size)), method: writeMethod)
                    } else if size < h.size {
                        try rewriteTruncated(h.path, size: size)
                    }
                }
                h.size = size
            }
            return
        }
        if size == 0 {
            try client.put(path, data: Data())
        } else {
            try rewriteTruncated(path, size: size)
        }
    }

    /// WebDAV 無法縮短檔案：下載 → 本機截斷 → 整檔上傳。
    private func rewriteTruncated(_ path: String, size: Int64) throws {
        let url = tempDir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try client.download(path, to: url)
        guard Darwin.truncate(url.path, off_t(size)) == 0 else { throw DAVError.posix(errno) }
        try client.put(path, file: url)
    }

    public func mkdir(_ path: String) throws {
        if isReadOnly { throw DAVError.posix(EROFS) }
        try client.mkcol(path)
        cache.invalidate(path)
    }

    public func unlink(_ path: String) throws {
        if isReadOnly { throw DAVError.posix(EROFS) }
        try client.delete(path)
        cache.invalidate(path)
    }

    /// WebDAV 的 DELETE 會遞迴刪除；POSIX rmdir 只能刪空目錄，必須先檢查。
    public func rmdir(_ path: String) throws {
        if isReadOnly { throw DAVError.posix(EROFS) }
        if try !list(path).isEmpty { throw DAVError.posix(ENOTEMPTY) }
        try client.delete(path)
        cache.invalidateTree(path)
    }

    public func rename(_ from: String, to: String) throws {
        if isReadOnly { throw DAVError.posix(EROFS) }
        // 先送出開啟中 handle 的緩衝，避免改名後寫到舊路徑
        for h in tableLock.withLock({ Array(handles.values) }) where h.writable {
            try h.lock.withLock { if h.path == from { try flushPending(h) } }
        }
        try client.move(from, to: to)
        cache.invalidateTree(from)
        cache.invalidateTree(to)
        // 更新開啟中 handle 的路徑（含子樹）
        let prefix = from + "/"
        for h in tableLock.withLock({ Array(handles.values) }) {
            h.lock.withLock {
                if h.path == from { h.path = to }
                else if h.path.hasPrefix(prefix) { h.path = to + h.path.dropFirst(from.count) }
            }
        }
    }
}
