import Foundation

/// worker 子行程進入點：一個行程＝一個掛載。
///
/// 流程：讀 stdin 設定 → 檢查 FUSE → 依協定建立 `RemoteStore` 並驗證連線（WebDAV 另探測部分寫入）
/// → 建掛載點 → 進入 FUSE 迴圈（阻塞到卸載）→ 以 libfuse 結束碼結束。
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

        // 連線驗證在掛載前完成：先失敗先回報，不掛一個壞掉的磁碟
        let store: any RemoteStore
        do {
            store = try RemoteStoreFactory.connect(account, remotePath: profile.remotePath, credential: config.credential,
                                                   probeWrites: !profile.readOnly)
        } catch let e as DAVError {
            fail(e.message)
        } catch {
            fail(error.localizedDescription)
        }
        emit(.connected(writeMethod: (profile.readOnly ? PartialWriteMethod.none : store.partialWrite).rawValue))

        let mountPoint = profile.resolvedMountPoint
        do {
            try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        } catch {
            fail("Cannot create mount point \(mountPoint): \(error.localizedDescription)")
        }

        watchParent(mountPoint: mountPoint)
        let fs = RemoteFileSystem(store: store, readOnly: profile.readOnly)
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
            "fsname=nasbridge@\(clean(account.url?.host() ?? account.protocol.rawValue))",
            "noappledouble",      // 不產生 ._ 檔（遠端上只會是垃圾）
            // 不可加 noapplexattr：它讓核心以 EPERM 拒絕 com.apple.* 延伸屬性，而 macOS 新檔案幾乎都帶
            // com.apple.provenance／quarantine，Finder 拷貝會因此整個失敗。延伸屬性改由 FuseHost 的
            // VolatileXattrStore 接住（只存在記憶體）。
            "iosize=1048576",     // 與讀取區塊大小一致，減少請求數
            // 單一 FUSE 請求的時限，超過 macFUSE 會把整個掛載視為失效。慢速網路上大檔上傳（release 時）可能較久；
            // FTP／SFTP 在伺服器不支援 REST、或改寫既有內容（handle 轉本機）時要整檔下載，給更長的時間
            "daemon_timeout=\(account.protocol.needsLftp ? 600 : 120)",
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
