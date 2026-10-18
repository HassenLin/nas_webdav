import Foundation
import Testing
@testable import NASBridgeCore

/// 記憶體中的 `RemoteStore`：驗證 `RemoteFileSystem` 的通用 POSIX 語意不依賴特定協定。
/// 能力旗標可調，分別模擬 WebDAV（Range 讀＋部分寫入）與 FTP／SFTP（皆無）、pCloud（只有 Range 讀）。
final class FakeStore: RemoteStore, @unchecked Sendable {
    let supportsRangeRead: Bool
    let partialWrite: PartialWriteMethod
    let renameReplacesTarget: Bool
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var dirs: Set<String> = ["/"]

    init(rangeRead: Bool, partialWrite: PartialWriteMethod, renameReplaces: Bool) {
        supportsRangeRead = rangeRead
        self.partialWrite = partialWrite
        renameReplacesTarget = renameReplaces
    }

    private func attrs(_ isDir: Bool, _ size: Int) -> FileAttributes {
        FileAttributes(isDirectory: isDir, size: Int64(size), modified: .distantPast, created: .distantPast)
    }

    func stat(_ path: String) throws -> FileAttributes {
        try lock.withLock {
            if dirs.contains(path) { return attrs(true, 0) }
            guard let d = files[path] else { throw DAVError.posix(ENOENT) }
            return attrs(false, d.count)
        }
    }

    func list(_ path: String) throws -> [RemoteEntry] {
        lock.withLock {
            let children = { (p: String) in p != path && p.parentPath == path }
            return dirs.filter(children).map { RemoteEntry(name: ($0 as NSString).lastPathComponent, attributes: attrs(true, 0)) }
                + files.filter { children($0.key) }.map {
                    RemoteEntry(name: ($0.key as NSString).lastPathComponent, attributes: attrs(false, $0.value.count))
                }
        }
    }

    func quota() throws -> (used: Int64?, available: Int64?) { (nil, nil) }

    func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        #expect(supportsRangeRead, "不支援 Range 讀的 store 不應被呼叫 read")
        let d = try lock.withLock { guard let d = files[path] else { throw DAVError.posix(ENOENT) }; return d }
        guard offset < Int64(d.count) else { return Data() }
        return d.subdata(in: Int(offset)..<min(d.count, Int(offset) + length))
    }

    func download(_ path: String, to local: URL) throws {
        let d = try lock.withLock { guard let d = files[path] else { throw DAVError.posix(ENOENT) }; return d }
        try d.write(to: local)
    }

    func upload(_ path: String, data: Data) throws {
        try lock.withLock {
            guard dirs.contains(path.parentPath) else { throw DAVError.posix(ENOENT) }
            files[path] = data
        }
    }

    func upload(_ path: String, file local: URL) throws { try upload(path, data: try Data(contentsOf: local)) }

    func write(_ path: String, offset: Int64, data: Data) throws {
        #expect(partialWrite != .none, "不支援部分寫入的 store 不應被呼叫 write")
        try lock.withLock {
            var d = files[path] ?? Data()
            if partialWrite == .append, Int(offset) != d.count {   // 模擬 REST＋STOR：只能接在檔尾
                throw DAVError.posix(EIO, "append at \(offset) but size is \(d.count)")
            }
            if d.count < Int(offset) + data.count { d.append(Data(count: Int(offset) + data.count - d.count)) }
            d.replaceSubrange(Int(offset)..<Int(offset) + data.count, with: data)
            files[path] = d
        }
    }

    func mkdir(_ path: String) throws {
        try lock.withLock {
            guard !dirs.contains(path), files[path] == nil else { throw DAVError.posix(EEXIST) }
            dirs.insert(path)
        }
    }

    func remove(_ path: String, isDirectory: Bool) throws {
        try lock.withLock {
            if isDirectory {
                guard dirs.remove(path) != nil else { throw DAVError.posix(ENOENT) }
            } else {
                guard files.removeValue(forKey: path) != nil else { throw DAVError.posix(ENOENT) }
            }
        }
    }

    func rename(_ from: String, to: String) throws {
        try lock.withLock {
            guard let d = files[from] else { throw DAVError.posix(ENOENT) }
            if files[to] != nil && !renameReplacesTarget { throw DAVError.posix(EEXIST) }   // 模擬 SFTP
            files[from] = nil
            files[to] = d
        }
    }
}

@Suite struct RemoteFileSystemTests {
    @Test(arguments: [
        (true, PartialWriteMethod.contentRange, true),    // WebDAV（Apache）
        (true, PartialWriteMethod.none, true),            // WebDAV（Synology）
        (true, PartialWriteMethod.none, false),           // pCloud
        (true, PartialWriteMethod.append, false),         // FTP／SFTP（lftp，支援 REST）
        (false, PartialWriteMethod.none, false),          // FTP（不支援 REST 的伺服器）
    ])
    func posixSemanticsOverAnyStore(rangeRead: Bool, partialWrite: PartialWriteMethod, renameReplaces: Bool) throws {
        let store = FakeStore(rangeRead: rangeRead, partialWrite: partialWrite, renameReplaces: renameReplaces)
        try FileSystemExercise.run(RemoteFileSystem(store: store, readOnly: false), dir: "/t")
    }

    /// 接續寫：循序寫直接送遠端（不落地）；改寫既有內容時 handle 轉本機暫存檔，關檔後內容正確
    @Test func appendModeConvertsOnRewrite() throws {
        let store = FakeStore(rangeRead: true, partialWrite: .append, renameReplaces: false)
        let fs = RemoteFileSystem(store: store, readOnly: false)
        let h = try fs.create("/f")
        try fs.write(handle: h, offset: 0, data: Data("hello".utf8))
        try fs.write(handle: h, offset: 5, data: Data(" world".utf8))
        try fs.flush(handle: h)
        #expect(try store.read("/f", offset: 0, length: 64) == Data("hello world".utf8))   // 已直接寫到遠端
        try fs.write(handle: h, offset: 0, data: Data("J".utf8))                              // 改寫開頭 → 轉本機
        try fs.write(handle: h, offset: 11, data: Data("!".utf8))
        #expect(try store.read("/f", offset: 0, length: 64) == Data("hello world".utf8))    // 關檔前遠端不變
        try fs.release(handle: h)
        #expect(try store.read("/f", offset: 0, length: 64) == Data("Jello world!".utf8))
        // 留洞寫（跳過檔尾）：補零後接續
        let g = try fs.open("/f", flags: O_WRONLY)
        try fs.write(handle: g, offset: 14, data: Data("x".utf8))
        try fs.release(handle: g)
        #expect(try store.read("/f", offset: 10, length: 64) == Data("d!\0\0x".utf8))
    }

    @Test func readOnlyRefusesWrites() throws {
        let fs = RemoteFileSystem(store: FakeStore(rangeRead: true, partialWrite: .contentRange, renameReplaces: true), readOnly: true)
        #expect(fs.writeMethod == .none)
        #expect(throws: DAVError.self) { try fs.mkdir("/x") }
        #expect(throws: DAVError.self) { try fs.create("/f") }
    }

    @Test func remoteRootJoinsAndNormalizes() {
        #expect(RemoteRoot("/").absolute("/") == "/")
        #expect(RemoteRoot("home/").absolute("/") == "/home")
        #expect(RemoteRoot("/home").absolute("/a") == "/home/a")
        // NFD（macOS 檔名）→ NFC
        #expect(RemoteRoot("/").absolute("/e\u{301}") == "/\u{e9}")
    }
}

@Suite struct AccountProtocolTests {
    @Test func legacyConfigDecodesAsWebDAV() throws {
        let json = #"{"id":"5A1C2A1E-0000-4000-8000-000000000001","name":"","serverURL":"https://nas:5006","username":"u","pinnedCertSHA256":""}"#
        let a = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        #expect(a.protocol == .webdav)
        #expect(a.ftpSecurity == .explicit && a.ftpMode == .passive)
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"accounts":[],"mounts":[]}"#.utf8))
        #expect(config.pcloudClientID == "")
    }

    @Test func validationPerProtocol() {
        var ftp = Account(protocol: .ftp)
        ftp.hostAndPort = "nas.local:2121"
        ftp.username = "u"
        #expect(ftp.serverURL == "ftp://nas.local:2121")
        #expect(ftp.validationError() == nil)
        #expect(ftp.effectivePort == 2121)
        ftp.hostAndPort = "ftp://nas.local"            // 貼上完整網址也接受
        #expect(ftp.serverURL == "ftp://nas.local")
        #expect(ftp.effectivePort == 21)
        ftp.ftpSecurity = .implicit
        #expect(ftp.effectivePort == 990)
        ftp.ftpSecurity = .none
        #expect(!ftp.isEncrypted && ftp.protocolLabel == "FTP")

        var sftp = Account(protocol: .sftp)
        sftp.hostAndPort = "nas"
        sftp.username = "u"
        sftp.sftpKeyPath = "/nonexistent/key"
        #expect(sftp.validationError() == "The private key file does not exist.")

        #expect(Account(protocol: .pcloud).validationError() == nil)
        var dav = Account()
        dav.serverURL = "ftp://nas"
        dav.username = "u"
        #expect(dav.validationError() == "Only https:// is allowed.")
    }

    @Test func switchProtocolKeepsHostOnly() {
        var a = Account()
        a.serverURL = "https://nas.local:5006/dav"
        a.switchProtocol(to: .sftp)
        #expect(a.serverURL == "sftp://nas.local")
        a.switchProtocol(to: .pcloud)
        #expect(a.serverURL == "" && a.url?.host() == "api.pcloud.com")
        a.switchProtocol(to: .ftp)
        #expect(a.serverURL == "ftp://")
    }

    @Test func keychainKeyDependsOnProtocol() {
        var a = Account()
        a.serverURL = "https://nas:5006"
        a.username = "u"
        var b = a
        b.id = UUID()
        #expect(KeychainStore.sameItem(a, b))
        b.switchProtocol(to: .sftp)
        #expect(!KeychainStore.sameItem(a, b))
        // pCloud token 以帳號 id 為鍵：兩個 pCloud 帳號互不共用
        #expect(!KeychainStore.sameItem(Account(protocol: .pcloud), Account(protocol: .pcloud)))
    }
}

@Suite struct LftpTests {
    func account(_ p: RemoteProtocol) -> Account {
        var a = Account(protocol: p)
        a.hostAndPort = "nas.local"
        a.username = "user \"x\""
        return a
    }

    @Test func quoting() throws {
        #expect(try LftpCommand.quote(#"a "b" \c"#) == #""a \"b\" \\c""#)
        #expect(try LftpCommand.quoteGlob("/a*[1].txt") == #""/a\\*\\[1\\].txt""#)
        #expect(throws: DAVError.self) { try LftpCommand.quote("a\nb") }
    }

    @Test func ftpsExplicitPassiveSettings() {
        var a = account(.ftp)
        a.ftpsTrustedFingerprint = "60:96:A0:01"
        let c = LftpCommand(account: a, timeout: 30, knownHostsFile: "/tmp/kh")
        #expect(c.url == "ftp://nas.local:21")
        #expect(c.settings.contains("set ftp:ssl-force yes"))
        #expect(c.settings.contains("set ftp:passive-mode on"))
        #expect(c.settings.contains("set cache:enable no"))
        #expect(c.settings.contains("set ssl:verify-certificate/60:96:A0:01 no"))
        #expect(c.open == #"open --env-password -u "user \"x\"" "ftp://nas.local:21""#)
    }

    @Test func ftpsImplicitActiveAndPlain() {
        var a = account(.ftp)
        a.ftpSecurity = .implicit
        a.ftpMode = .active
        let c = LftpCommand(account: a, timeout: 30, knownHostsFile: "/tmp/kh")
        #expect(c.url == "ftps://nas.local:990")
        #expect(c.settings.contains("set ftp:passive-mode off"))
        a.ftpSecurity = .none
        a.ftpsTrustedFingerprint = "60:96"
        let plain = LftpCommand(account: a, timeout: 30, knownHostsFile: "/tmp/kh")
        #expect(plain.settings.contains("set ftp:ssl-allow no"))
        #expect(!plain.settings.contains { $0.hasPrefix("set ssl:verify-certificate") })
    }

    @Test func sftpKeyAuthUsesEmptyPassword() throws {
        let key = FileManager.default.temporaryDirectory.appendingPathComponent("nb-key-\(UUID())")
        try Data().write(to: key)
        defer { try? FileManager.default.removeItem(at: key) }
        var a = account(.sftp)
        a.sftpKeyPath = key.path
        let c = LftpCommand(account: a, timeout: 30, knownHostsFile: "/Users/x/Application Support/kh")
        #expect(c.url == "sftp://nas.local:22")
        #expect(c.open.hasPrefix(#"open -u "user \"x\",""#))
        let ssh = try #require(c.settings.first { $0.hasPrefix("set sftp:connect-program") })
        #expect(ssh.contains("StrictHostKeyChecking=accept-new"))
        #expect(ssh.contains("Application Support"))
        #expect(ssh.contains("-i '\(key.path)'"))
    }

    @Test func listingParser() {
        let lines = [
            "---------- 501      0         3145728 1792325773 /big.bin",
            "d--------- 501      0              64 1792325754 /中文 資料夾/",
            "lrwxrwxrwx 0        0               7 1792325754 /link -> a.txt",
            "drwxr-xr-x 2 0 0 4096 1792325754 /./",
            "garbage",
        ]
        let items = LftpListingParser.parse(lines)
        #expect(items.map(\.path) == ["/big.bin", "/中文 資料夾", "/link"])
        #expect(items[0].size == 3_145_728 && !items[0].isDirectory)
        #expect(items[1].isDirectory && items[1].size == 0)
        #expect(items[0].modified == Date(timeIntervalSince1970: 1_792_325_773))
    }

    @Test func errorClassification() {
        #expect(LftpError.classify("cls: Login failed: 530 Login incorrect.").code == EACCES)
        #expect(LftpError.classify("Access failed: 550 No such file or directory. (/nope)").code == ENOENT)
        #expect(LftpError.classify("rmdir: Access failed: 550 Directory not empty.").code == ENOTEMPTY)
        #expect(LftpError.classify("mkdir: Access failed: 550 File exists").code == EEXIST)
        #expect(LftpError.classify("cls: max-retries exceeded").code == EHOSTUNREACH)
        let cert = LftpError.classify(
            "Fatal error: Certificate verification: self-signed certificate (60:96:A0:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11)")
        #expect(cert.code == EACCES)
        #expect(cert.untrustedFingerprint == "60:96:A0:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11")
    }
}

@Suite struct PCloudTests {
    @Test func regionHostsAndURLEncoding() {
        let store = PCloudStore(region: .eu, remotePath: "/", token: "t", timeout: 5)
        let url = store.url("stat", ["path": "/a+b c"])
        #expect(url.host() == "eapi.pcloud.com")
        #expect(url.absoluteString.contains("a%2Bb%20c"))
        #expect(PCloudRegion(locationID: "2") == .eu)
        #expect(PCloudRegion(apiHost: "API.pcloud.com") == .us)
        #expect(PCloudRegion(apiHost: "evil.example.com") == nil)
    }

    @Test func errorCodesMapToErrno() {
        #expect(PCloudStore.error(2094, "", method: "stat").code == EACCES)
        #expect(PCloudStore.error(2009, "", method: "stat").code == ENOENT)
        #expect(PCloudStore.error(2006, "", method: "deletefolder").code == ENOTEMPTY)
        #expect(PCloudStore.error(2008, "", method: "uploadfile").code == ENOSPC)
    }

    @Test func metadataConversion() {
        let m = PCloudStore.Metadata(name: "a.txt", isfolder: false, size: 12, modified: "Thu, 21 Mar 2013 18:31:57 +0000",
                                     created: nil, contents: nil)
        let a = PCloudStore.attributes(m)
        #expect(a.size == 12 && !a.isDirectory)
        #expect(a.modified == Date(timeIntervalSince1970: 1_363_890_717))
    }

    @Test func oauthCallbackChecksStateAndRegion() throws {
        let cb = try PCloudOAuth.parseCallback(
            requestLine: "GET /?code=abc&state=S&locationid=2&hostname=eapi.pcloud.com HTTP/1.1", expectedState: "S")
        #expect(cb.code == "abc" && cb.region == .eu)
        #expect(PCloudOAuth.tokenHost(for: cb, fallback: .us) == .eu)
        #expect(throws: DAVError.self) {
            try PCloudOAuth.parseCallback(requestLine: "GET /?code=abc&state=X HTTP/1.1", expectedState: "S")
        }
    }
}

/// 對真實 FTP／SFTP 伺服器的整合測試（預設略過）：
///
///   NB_LIVE_LFTP="ftp://u:p@127.0.0.1:2121 sftp://u@127.0.0.1:2222/tmp#~/.ssh/key" swift test --filter LiveLftp
///
/// scheme：`ftp`（純 FTP）、`ftpes`（FTPS explicit）、`ftps`（FTPS implicit）、`sftp`；網址路徑＝遠端根路徑；
/// SFTP 私鑰以 `#路徑` 指定；FTPS 自簽憑證指紋以 `NB_LIVE_FTPS_FP` 指定。
/// 只在伺服器上建立並清除一個 `nasbridge-test-<uuid>` 資料夾。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NB_LIVE_LFTP"] != nil))
struct LiveLftpTests {
    static func account(_ spec: String) -> (Account, String, String) {
        let comps = URLComponents(string: spec)!
        var a = Account(protocol: comps.scheme == "sftp" ? .sftp : .ftp)
        switch comps.scheme {
        case "ftp": a.ftpSecurity = .none
        case "ftps": a.ftpSecurity = .implicit
        default: a.ftpSecurity = .explicit
        }
        a.hostAndPort = comps.host! + (comps.port.map { ":\($0)" } ?? "")
        a.username = comps.user ?? ""
        if let key = comps.fragment { a.sftpKeyPath = (key as NSString).expandingTildeInPath }
        a.ftpsTrustedFingerprint = ProcessInfo.processInfo.environment["NB_LIVE_FTPS_FP"] ?? ""
        return (a, comps.password ?? "", comps.path.isEmpty ? "/" : comps.path)
    }

    @Test(arguments: ProcessInfo.processInfo.environment["NB_LIVE_LFTP", default: ""].split(separator: " ").map(String.init))
    func fileSystemRoundTrip(spec: String) throws {
        let (account, password, remotePath) = Self.account(spec)
        let store = try RemoteStoreFactory.connect(account, remotePath: remotePath, credential: password, probeWrites: true)
        print("\(spec.split(separator: "@").last ?? ""): rangeRead=\(store.supportsRangeRead) write=\(store.partialWrite)")
        let fs = RemoteFileSystem(store: store, readOnly: false)
        try FileSystemExercise.run(fs, dir: "/nasbridge-test-\(UUID().uuidString.prefix(8))")
    }
}
