import Foundation

/// 屬性與目錄列表的短期快取（TTL）。
///
/// 目的：Finder 開一個資料夾會對每個項目連續呼叫 getattr 數次、並探測大量不存在的檔案
/// （`.DS_Store`、`.localized`…），不快取每次都是一個 HTTP 往返。
/// 也快取「不存在」（負向快取），TTL 較短。
/// 一致性：本機的變更操作會立即失效相關鍵；他人在 NAS 上的變更最多延遲 TTL 秒才看到。
final class MetadataCache: @unchecked Sendable {
    private struct Entry<T> { let value: T; let expiry: Date }

    private let lock = NSLock()
    private var attrs: [String: Entry<FileAttributes?>] = [:]   // nil 值＝已知不存在
    private var listings: [String: Entry<[String]>] = [:]
    private let ttl: TimeInterval
    private let negativeTTL: TimeInterval

    init(ttl: TimeInterval = 5, negativeTTL: TimeInterval = 2) {
        self.ttl = ttl
        self.negativeTTL = negativeTTL
    }

    /// 回傳 `.some(nil)` 表示快取確定此路徑不存在；`nil` 表示未命中。
    func attributes(_ path: String) -> FileAttributes?? {
        lock.withLock {
            guard let e = attrs[path], e.expiry > Date() else { return nil }
            return .some(e.value)
        }
    }

    func setAttributes(_ a: FileAttributes?, for path: String) {
        lock.withLock {
            attrs[path] = Entry(value: a, expiry: Date().addingTimeInterval(a == nil ? negativeTTL : ttl))
        }
    }

    func listing(_ path: String) -> [String]? {
        lock.withLock {
            guard let e = listings[path], e.expiry > Date() else { return nil }
            return e.value
        }
    }

    func setListing(_ names: [String], for path: String) {
        lock.withLock { listings[path] = Entry(value: names, expiry: Date().addingTimeInterval(ttl)) }
    }

    /// 失效單一路徑（屬性）及其父目錄列表。
    func invalidate(_ path: String) {
        lock.withLock {
            attrs[path] = nil
            listings[path] = nil
            listings[path.parentPath] = nil
        }
    }

    /// 失效整棵子樹（目錄改名／刪除後用）。
    func invalidateTree(_ path: String) {
        lock.withLock {
            let prefix = path == "/" ? "/" : path + "/"
            attrs = attrs.filter { $0.key != path && !$0.key.hasPrefix(prefix) }
            listings = listings.filter { $0.key != path && !$0.key.hasPrefix(prefix) }
            listings[path.parentPath] = nil
        }
    }
}
