import CFuseShim
import Foundation

/// 執行期載入 libfuse 2.x（macFUSE 優先，FUSE-T 為替代）。
///
/// 不在建置時連結的原因見 `CFuseShim.h`。app 端用 `FuseLibrary.detect()` 決定是否顯示安裝導引；
/// worker 端用 `load()` 取得 `fuse_main_real`。
public enum FuseLibrary {
    public enum Kind: String, Sendable {
        case macFUSE
        case fuseT = "FUSE-T"
    }

    public struct Installation: Sendable, Equatable {
        public let kind: Kind
        public let path: String
    }

    /// 依優先順序的候選路徑。macFUSE 安裝到 /usr/local/lib（與 Homebrew 前綴無關）。
    static let candidates: [(Kind, String)] = [
        (.macFUSE, "/usr/local/lib/libfuse.2.dylib"),
        (.macFUSE, "/usr/local/lib/libfuse.dylib"),
        (.fuseT, "/usr/local/lib/libfuse-t.dylib"),
        (.fuseT, "/opt/homebrew/lib/libfuse-t.dylib"),
    ]

    /// 只檢查檔案是否存在（不載入），供 UI 判斷。
    public static func detect() -> Installation? {
        candidates.first { FileManager.default.fileExists(atPath: $0.1) }
            .map { Installation(kind: $0.0, path: $0.1) }
    }

    /// 載入函式庫並取出 `fuse_main_real`。
    static func load() throws -> (Installation, fuse_main_real_fn) {
        var lastError = "macFUSE is not installed"
        for (kind, path) in candidates where FileManager.default.fileExists(atPath: path) {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                lastError = String(cString: dlerror())
                continue
            }
            guard let sym = dlsym(handle, "fuse_main_real") else {
                lastError = "\(path): fuse_main_real not found"
                continue
            }
            return (Installation(kind: kind, path: path), unsafeBitCast(sym, to: fuse_main_real_fn.self))
        }
        throw DAVError.posix(ENOENT, lastError)
    }
}
