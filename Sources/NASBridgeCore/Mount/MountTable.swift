import Foundation

/// 查詢系統掛載表與執行外部卸載工具。
enum MountTable {
    /// path 目前是否為某個檔案系統的掛載點。
    static func isMountPoint(_ path: String) -> Bool {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return false }
        let on = withUnsafeBytes(of: st.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let real = (path as NSString).resolvingSymlinksInPath
        return on == real || on == path
    }

    /// 執行 `/sbin/umount`，回傳是否成功與錯誤輸出。
    static func unmount(_ path: String, force: Bool) async -> (ok: Bool, output: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/umount")
            p.arguments = force ? ["-f", path] : [path]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                cont.resume(returning: (proc.terminationStatus == 0, text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do { try p.run() } catch { cont.resume(returning: (false, error.localizedDescription)) }
        }
    }
}
