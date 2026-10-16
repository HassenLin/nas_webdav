import Foundation

/// 一個開啟中的檔案 handle（`WebDAVFileSystem` 內部使用）。
///
/// 兩種儲存策略，在 open 時依「是否寫入」與「伺服器是否支援部分寫入」決定，之後不變：
///
/// | 情境 | storage | 讀 | 寫 |
/// |---|---|---|---|
/// | 唯讀開啟 | `.remote` | Range GET（1 MiB 區塊快取） | — |
/// | 寫入＋支援部分寫入 | `.remote` | 同上 | 合併連續寫入後以部分寫入送出（webdavfs 做法） |
/// | 寫入＋不支援 | `.local` | 讀本機暫存檔 | 寫本機暫存檔，flush/release 時整檔 PUT |
///
/// 併發：同一 handle 上的操作以 `lock` 序列化；`path` 可能被 rename 更新，也在 `lock` 內讀寫。
final class OpenFile: @unchecked Sendable {
    enum Storage {
        case remote
        /// fd：本機暫存檔的 POSIX 檔案描述子
        case local(fd: Int32, url: URL)
    }

    let lock = NSLock()
    var path: String
    let writable: Bool
    let storage: Storage
    /// 目前檔案大小（含尚未送出的寫入）。
    var size: Int64
    /// `.local`：暫存檔有尚未上傳的變更。
    var dirty = false
    /// `.remote` 寫入合併緩衝：連續寫入累積到上限或遇到不連續寫入才送出，
    /// 避免核心每 64 KiB 一次 write 就變成一個 HTTP 請求。
    var pending: (offset: Int64, data: Data)?
    /// `.remote` 讀取快取：最近一次取回的區塊；`short` 為 true 表示該區塊已到檔尾。
    var readCache: (offset: Int64, data: Data, short: Bool)?

    init(path: String, writable: Bool, storage: Storage, size: Int64) {
        self.path = path
        self.writable = writable
        self.storage = storage
        self.size = size
    }
}
