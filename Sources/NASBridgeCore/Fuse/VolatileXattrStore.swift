import Foundation

/// 延伸屬性（xattr）的記憶體暫存。
///
/// 為什麼需要：WebDAV 無法儲存延伸屬性，但 macOS 新檔案幾乎都帶 `com.apple.provenance`、
/// `com.apple.quarantine` 等屬性，Finder／cp 拷貝時寫不進去會讓整個拷貝失敗。
/// 這裡接受並保存在 worker 記憶體中：同一次掛載期間讀得到（行為與本機一致），
/// **不會寫到 NAS，卸載後消失**。
///
/// 語意對照 setxattr(2)：XATTR_CREATE（已存在→EEXIST）、XATTR_REPLACE（不存在→ENOATTR）、
/// position（資源分支的寫入位移）。單一值上限 1 MiB，避免資源分支把記憶體撐爆。
final class VolatileXattrStore: @unchecked Sendable {
    static let maxValueSize = 1 << 20

    private let lock = NSLock()
    private var attrs: [String: [String: Data]] = [:]   // path → name → value

    func set(_ path: String, _ name: String, _ value: Data, flags: Int32, position: UInt32) throws {
        try lock.withLock {
            var map = attrs[path] ?? [:]
            let exists = map[name] != nil
            if flags & XATTR_CREATE != 0, exists { throw DAVError.posix(EEXIST) }
            if flags & XATTR_REPLACE != 0, !exists { throw DAVError.posix(ENOATTR) }
            var data = position == 0 ? Data() : (map[name] ?? Data())
            let end = Int(position) + value.count
            guard end <= Self.maxValueSize else { throw DAVError.posix(E2BIG) }
            if data.count < end { data.append(Data(count: end - data.count)) }
            data.replaceSubrange(Int(position)..<end, with: value)
            map[name] = data
            attrs[path] = map
        }
    }

    func get(_ path: String, _ name: String) throws -> Data {
        guard let v = lock.withLock({ attrs[path]?[name] }) else { throw DAVError.posix(ENOATTR) }
        return v
    }

    func names(_ path: String) -> [String] {
        lock.withLock { attrs[path].map { Array($0.keys).sorted() } ?? [] }
    }

    func remove(_ path: String, _ name: String) throws {
        try lock.withLock {
            guard attrs[path]?.removeValue(forKey: name) != nil else { throw DAVError.posix(ENOATTR) }
        }
    }

    /// 檔案或目錄被刪除：丟掉其（含子樹）屬性。
    func drop(_ path: String) {
        lock.withLock {
            let prefix = path + "/"
            attrs = attrs.filter { $0.key != path && !$0.key.hasPrefix(prefix) }
        }
    }

    /// 改名：屬性（含子樹）跟著搬；目的地原有的屬性被覆蓋。
    func rename(_ from: String, to: String) {
        lock.withLock {
            let prefix = from + "/"
            attrs = attrs.filter { $0.key != to && !$0.key.hasPrefix(to + "/") }
            for (k, v) in attrs where k == from || k.hasPrefix(prefix) {
                attrs[k] = nil
                attrs[to + k.dropFirst(from.count)] = v
            }
        }
    }
}
