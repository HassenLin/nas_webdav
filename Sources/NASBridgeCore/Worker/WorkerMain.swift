import Foundation

/// worker 子行程進入點：一個行程＝一個掛載。
///
/// 流程：讀 stdin 設定 → 檢查 FUSE → 連線驗證（先失敗先回報，不掛一個壞掉的磁碟）
/// → 探測部分寫入 → 建掛載點 → 進入 FUSE 迴圈（阻塞到卸載）→ 以 libfuse 結束碼結束。
public enum WorkerMain {
    public static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let config: WorkerConfig
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            config = try JSONDecoder().decode(WorkerConfig.self, from: data)
        } catch {
            fail("invalid worker config: \(error.localizedDescription)")
        }
        let (account, profile) = (config.account, config.mount)
        if let msg = account.validationError() ?? profile.validationError() { fail(msg) }
        guard FuseLibrary.detect() != nil else { fail("macFUSE is not installed") }

        guard let client = WebDAVClient(account: account, remotePath: profile.remotePath, password: config.password) else {
            fail("Server URL is invalid.")
        }
        do {
            guard let root = try client.propfind("/", depth: 0).first, root.isDirectory else {
                fail("Remote path is not a folder.")
            }
        } catch let e as DAVError {
            fail(e.code == EACCES ? "Authentication failed (\(e.message))" : e.message)
        } catch {
            fail(error.localizedDescription)
        }
        let method = profile.readOnly ? PartialWriteMethod.none : client.probePartialWrite(in: "/")
        emit(.connected(writeMethod: method.rawValue))

        let mountPoint = profile.resolvedMountPoint
        do {
            try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        } catch {
            fail("Cannot create mount point \(mountPoint): \(error.localizedDescription)")
        }

        watchParent(mountPoint: mountPoint)
        let fs = WebDAVFileSystem(client: client, readOnly: profile.readOnly, writeMethod: method)
        do {
            let code = try FuseHost.run(fs: fs, mountPoint: mountPoint, options: mountOptions(profile, account: account)) {
                emit(.ready)
            }
            exit(code)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// macFUSE 掛載選項。值中的逗號會破壞 `-o` 解析，一律換掉。
    static func mountOptions(_ p: MountProfile, account: Account) -> [String] {
        let clean = { (s: String) in s.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "=", with: "-") }
        var opts = [
            "volname=\(clean(p.name))",
            "fsname=nasbridge@\(clean(account.url?.host() ?? "webdav"))",
            "noappledouble",      // 不產生 ._ 檔（WebDAV 上只會是垃圾）
            // 不可加 noapplexattr：它讓核心以 EPERM 拒絕 com.apple.* 延伸屬性，而 macOS 新檔案幾乎都帶
            // com.apple.provenance／quarantine，Finder 拷貝會因此整個失敗。延伸屬性改由 FuseHost 的
            // VolatileXattrStore 接住（只存在記憶體）。
            "iosize=1048576",     // 與讀取區塊大小一致，減少請求數
            "daemon_timeout=120", // 慢速網路上大檔上傳（release 時）可能較久
        ]
        if p.readOnly { opts.append("rdonly") }
        return opts
    }

    /// 主 app 結束或當掉時，自行卸載，不留下沒人管的掛載。
    /// （正常結束時主 app 會先卸載；這是保險。）
    private static func watchParent(mountPoint: String) {
        let parent = getppid()
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
        source.setEventHandler {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/umount")
            p.arguments = ["-f", mountPoint]
            try? p.run()
        }
        source.resume()
        parentWatcher = source
    }

    nonisolated(unsafe) private static var parentWatcher: DispatchSourceProcess?

    static func emit(_ event: WorkerEvent) {
        FileHandle.standardOutput.write(Data((event.line + "\n").utf8))
    }

    private static func fail(_ message: String) -> Never {
        emit(.error(message))
        exit(1)
    }
}
