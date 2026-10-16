import CFuseShim
import Foundation
import os

/// libfuse 高階 API 與 `POSIXFileSystem` 之間的 C ABI 膠水層。
///
/// 職責只有三件：C 型別 ↔ Swift 型別、`DAVError` → `-errno`、填 `struct stat`。
/// 不含任何 WebDAV 知識。
///
/// 為什麼用全域狀態：libfuse 的 callback 是 C 函式指標，Swift 閉包轉成 `@convention(c)` 時
/// 不能捕捉任何內容，只能透過全域取得檔案系統實例。每個 worker 行程只掛載一個檔案系統
/// （多實例＝多行程），所以全域單例是安全且最簡單的做法；`run` 之前設定、之後不再改動。
public enum FuseHost {
    nonisolated(unsafe) private static var fs: (any POSIXFileSystem)!
    nonisolated(unsafe) private static var onMounted: (@Sendable () -> Void)?
    private static let log = Logger(subsystem: "idv.hassen.nasbridge", category: "fuse")

    /// 掛載並進入 FUSE 事件迴圈；卸載（umount、Finder 退出、SIGTERM）後返回 libfuse 的結束碼。
    /// - Parameter options: `-o` 掛載選項（不含逗號跳脫，呼叫端負責清理值）。
    /// - Parameter onMounted: 核心完成 FUSE_INIT 交握（掛載生效）時呼叫一次。
    public static func run(fs: any POSIXFileSystem, mountPoint: String, options: [String],
                           onMounted: @escaping @Sendable () -> Void) throws -> Int32 {
        let (_, fuseMain) = try FuseLibrary.load()
        Self.fs = fs
        Self.onMounted = onMounted

        var ops = makeOperations()
        // -f：前景執行（由我們的父行程管理生命週期，不要 daemonize）
        let args = ["NASBridge", mountPoint, "-f", "-o", options.joined(separator: ",")]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        return fuseMain(Int32(args.count), &argv, &ops, MemoryLayout<fuse_operations>.size, nil)
    }

    // MARK: - callback 表

    private static func makeOperations() -> fuse_operations {
        var ops = fuse_operations()

        ops.`init` = { _ in
            FuseHost.onMounted?()
            return nil
        }
        ops.getattr = { path, st in
            FuseHost.call(path) { p in
                FuseHost.fill(st!, try FuseHost.fs.attributes(p))
                return 0
            }
        }
        ops.fgetattr = { path, st, _ in
            FuseHost.call(path) { p in
                FuseHost.fill(st!, try FuseHost.fs.attributes(p))
                return 0
            }
        }
        ops.readdir = { path, buf, filler, _, _ in
            FuseHost.call(path) { p in
                let entries = try FuseHost.fs.list(p)
                _ = filler?(buf, ".", nil, 0)
                _ = filler?(buf, "..", nil, 0)
                var st = stat()
                for e in entries {
                    FuseHost.fill(&st, e.attributes)
                    _ = filler?(buf, e.name, &st, 0)
                }
                return 0
            }
        }
        ops.statfs = { path, sv in
            FuseHost.call(path) { _ in
                let (total, free) = try FuseHost.fs.statfs()
                let block: UInt = 1 << 20   // 以 1 MiB 為單位，避免 32 位元的 fsblkcnt 溢位
                sv!.pointee = statvfs()
                sv!.pointee.f_bsize = block
                sv!.pointee.f_frsize = block
                sv!.pointee.f_blocks = fsblkcnt_t(clamping: total / Int64(block))
                sv!.pointee.f_bfree = fsblkcnt_t(clamping: free / Int64(block))
                sv!.pointee.f_bavail = fsblkcnt_t(clamping: free / Int64(block))
                sv!.pointee.f_namemax = 255
                return 0
            }
        }

        ops.open = { path, fi in
            FuseHost.call(path) { p in
                fi!.pointee.fh = try FuseHost.fs.open(p, flags: fi!.pointee.flags)
                return 0
            }
        }
        ops.create = { path, _, fi in
            FuseHost.call(path) { p in
                fi!.pointee.fh = try FuseHost.fs.create(p)
                return 0
            }
        }
        ops.read = { path, buf, size, offset, fi in
            FuseHost.call(path) { _ in
                let data = try FuseHost.fs.read(handle: fi!.pointee.fh, offset: Int64(offset), count: size)
                data.copyBytes(to: UnsafeMutableRawPointer(buf!).assumingMemoryBound(to: UInt8.self), count: data.count)
                return Int32(data.count)
            }
        }
        ops.write = { path, buf, size, offset, fi in
            FuseHost.call(path) { _ in
                let data = Data(bytes: buf!, count: size)
                try FuseHost.fs.write(handle: fi!.pointee.fh, offset: Int64(offset), data: data)
                return Int32(size)
            }
        }
        ops.flush = { path, fi in
            FuseHost.call(path) { _ in try FuseHost.fs.flush(handle: fi!.pointee.fh); return 0 }
        }
        ops.fsync = { path, _, fi in
            FuseHost.call(path) { _ in try FuseHost.fs.flush(handle: fi!.pointee.fh); return 0 }
        }
        ops.release = { path, fi in
            FuseHost.call(path) { _ in try FuseHost.fs.release(handle: fi!.pointee.fh); return 0 }
        }

        ops.truncate = { path, size in
            FuseHost.call(path) { p in try FuseHost.fs.truncate(p, size: Int64(size)); return 0 }
        }
        ops.ftruncate = { path, size, _ in
            FuseHost.call(path) { p in try FuseHost.fs.truncate(p, size: Int64(size)); return 0 }
        }
        ops.mkdir = { path, _ in
            FuseHost.call(path) { p in try FuseHost.fs.mkdir(p); return 0 }
        }
        ops.unlink = { path in
            FuseHost.call(path) { p in try FuseHost.fs.unlink(p); return 0 }
        }
        ops.rmdir = { path in
            FuseHost.call(path) { p in try FuseHost.fs.rmdir(p); return 0 }
        }
        ops.rename = { from, to in
            FuseHost.call(from) { p in try FuseHost.fs.rename(p, to: String(cString: to!)); return 0 }
        }

        // WebDAV 沒有權限／擁有者／時間戳可設定：回報成功，讓 cp、Finder 拷貝不因此失敗。
        // （唯讀掛載時核心會先擋下寫入類操作，不會走到這裡。）
        ops.chmod = { _, _ in 0 }
        ops.chown = { _, _, _ in 0 }
        ops.utimens = { _, _ in 0 }
        return ops
    }

    // MARK: - 共用

    /// 執行 callback 本體並把錯誤轉成 `-errno`。ENOENT 是 Finder 探測的常態，不記錄。
    private static func call(_ path: UnsafePointer<CChar>?, _ body: (String) throws -> Int32) -> Int32 {
        let p = path.map { String(cString: $0) } ?? "/"
        do {
            return try body(p)
        } catch let e as DAVError {
            if e.code != ENOENT { log.error("\(p, privacy: .public): \(e.message, privacy: .public)") }
            return -e.code
        } catch {
            log.error("\(p, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return -EIO
        }
    }

    /// FileAttributes → struct stat。擁有者固定為執行 worker 的使用者，權限為 0755 目錄／0644 檔案；
    /// 唯讀掛載時去掉寫入位元，讓 Finder 正確顯示鎖頭。
    static func fill(_ st: UnsafeMutablePointer<stat>, _ a: FileAttributes) {
        var mode: mode_t = a.isDirectory ? (S_IFDIR | 0o755) : (S_IFREG | 0o644)
        if fs?.isReadOnly == true { mode &= ~mode_t(0o222) }
        st.pointee = stat()
        st.pointee.st_mode = mode
        st.pointee.st_nlink = a.isDirectory ? 2 : 1
        st.pointee.st_uid = getuid()
        st.pointee.st_gid = getgid()
        st.pointee.st_size = off_t(a.size)
        st.pointee.st_blksize = 1 << 16
        st.pointee.st_blocks = blkcnt_t((a.size + 511) / 512)
        let m = timespec(tv_sec: Int(a.modified.timeIntervalSince1970), tv_nsec: 0)
        st.pointee.st_mtimespec = m
        st.pointee.st_ctimespec = m
        st.pointee.st_atimespec = m
        st.pointee.st_birthtimespec = timespec(tv_sec: Int(a.created.timeIntervalSince1970), tv_nsec: 0)
    }
}
