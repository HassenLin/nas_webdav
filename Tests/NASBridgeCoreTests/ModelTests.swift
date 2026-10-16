import Foundation
import Testing
@testable import NASBridgeCore

@Suite struct AccountAndMountTests {
    func account(_ server: String) -> Account {
        var a = Account()
        a.serverURL = server
        a.username = "u"
        return a
    }

    func mount(_ remote: String, on a: Account) -> URL? {
        var m = MountProfile(accountID: a.id)
        m.remotePath = remote
        return m.baseURL(on: a)
    }

    @Test func baseURLJoinsRemotePath() {
        #expect(mount("/home", on: account("https://nas:5006"))?.absoluteString == "https://nas:5006/home")
        #expect(mount("home/", on: account("https://nas:5006/"))?.absoluteString == "https://nas:5006/home")
        #expect(mount("/", on: account("https://nas:9001"))?.absoluteString == "https://nas:9001")
        #expect(mount("/a b", on: account("https://nas/dav"))?.path(percentEncoded: false) == "/dav/a b")
    }

    @Test func onlyHTTPSAllowed() {
        #expect(account("http://nas:5005").validationError() == "Only https:// is allowed.")
        #expect(account("https://nas:5006").validationError() == nil)
        #expect(account("https://").validationError() == "Server URL is invalid.")
    }

    @Test func displayNameFallsBackToHost() {
        var a = account("https://www.hassen.myds.me:9001")
        #expect(a.displayName == "www.hassen.myds.me")
        a.name = "Home NAS"
        #expect(a.displayName == "Home NAS")
    }

    @Test func fingerprintNormalization() {
        let fp = "C8:00:5F:75:B6:3B:36:DD:A1:16:49:78:77:89:D1:B2:6D:B5:69:DB:8B:87:02:64:DB:7F:E5:4D:1D:B6:FA:2F"
        #expect(Account.normalizeFingerprint(fp).count == 64)
        var a = account("https://nas")
        a.pinnedCertSHA256 = "abc"
        #expect(a.validationError() != nil)
    }

    @Test func defaultMountPointUnderHomeVolumes() {
        var m = MountProfile(accountID: UUID())
        m.name = "My/NAS"
        #expect(m.resolvedMountPoint.hasSuffix("/Volumes/My-NAS"))
    }

    @Test func configRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nb-config-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = account("https://nas:5006")
        let config = AppConfig(accounts: [a], mounts: [MountProfile(accountID: a.id)])
        try ConfigStore.save(config, to: url)
        #expect(ConfigStore.load(from: url) == config)
    }

    /// 被掛載使用中的帳號不能刪；掛載不能指向不存在的帳號。（不碰鑰匙圈：password 傳 nil）
    @MainActor @Test func managerRefusesDanglingReferences() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nb-config-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = MountManager(configURL: url)
        let a = account("https://nas:5006")
        try manager.saveAccount(a, password: nil)
        #expect(throws: DAVError.self) { try manager.saveMount(MountProfile(accountID: UUID())) }
        try manager.saveMount(MountProfile(accountID: a.id))
        #expect(throws: DAVError.self) { try manager.deleteAccount(a.id) }
        #expect(manager.accounts.count == 1)
        #expect(MountManager(configURL: url).mounts.count == 1)   // 已持久化
    }
}

@Suite struct WorkerProtocolTests {
    @Test func eventLineRoundTrip() {
        for e in [WorkerEvent.ready, .connected(writeMethod: "contentRange"), .error("bad thing")] {
            #expect(WorkerEvent(line: e.line) == e)
        }
        #expect(WorkerEvent(line: "ERROR a\nb".replacingOccurrences(of: "\n", with: " ")) == .error("a b"))
        #expect(WorkerEvent(line: "garbage") == nil)
    }

    @Test func mountOptionsEscapeCommas() {
        var a = Account()
        a.serverURL = "https://nas.local:5006"
        var p = MountProfile(accountID: a.id)
        p.name = "a,b=c"
        p.readOnly = true
        let opts = WorkerMain.mountOptions(p, account: a)
        #expect(opts.contains("volname=a b-c"))
        #expect(opts.contains("fsname=nasbridge@nas.local"))
        #expect(opts.contains("rdonly"))
    }
}

@Suite struct PathTests {
    @Test func parentAndAppend() {
        #expect("/a/b/c".parentPath == "/a/b")
        #expect("/a".parentPath == "/")
        #expect("/".appendingPathSegment("x") == "/x")
        #expect("/a".appendingPathSegment("x") == "/a/x")
    }

    @Test func cacheInvalidatesParentListingAndTree() {
        let c = MetadataCache()
        let a = FileAttributes(isDirectory: false, size: 1, modified: .now, created: .now)
        c.setAttributes(a, for: "/d/f")
        c.setAttributes(a, for: "/d/sub/g")
        c.setListing(["f"], for: "/d")
        c.invalidate("/d/f")
        #expect(c.attributes("/d/f") == nil)
        #expect(c.listing("/d") == nil)
        c.invalidateTree("/d")
        #expect(c.attributes("/d/sub/g") == nil)
    }

    @Test func negativeCache() {
        let c = MetadataCache()
        c.setAttributes(nil, for: "/missing")
        #expect(c.attributes("/missing") == .some(nil))
    }
}

@Suite struct XattrStoreTests {
    @Test func setGetListRemoveWithFlags() throws {
        let s = VolatileXattrStore()
        try s.set("/f", "com.apple.provenance", Data([1, 2]), flags: 0, position: 0)
        #expect(try s.get("/f", "com.apple.provenance") == Data([1, 2]))
        #expect(throws: DAVError.self) { try s.set("/f", "com.apple.provenance", Data(), flags: XATTR_CREATE, position: 0) }
        #expect(throws: DAVError.self) { try s.set("/f", "x", Data(), flags: XATTR_REPLACE, position: 0) }
        try s.set("/f", "a", Data([9]), flags: 0, position: 0)
        #expect(s.names("/f") == ["a", "com.apple.provenance"])
        try s.remove("/f", "a")
        #expect(throws: DAVError.self) { try s.get("/f", "a") }
    }

    @Test func positionWritesExtendValue() throws {
        let s = VolatileXattrStore()
        try s.set("/f", "com.apple.ResourceFork", Data([1, 2]), flags: 0, position: 0)
        try s.set("/f", "com.apple.ResourceFork", Data([7]), flags: 0, position: 4)
        #expect(try s.get("/f", "com.apple.ResourceFork") == Data([1, 2, 0, 0, 7]))
        #expect(throws: DAVError.self) {
            try s.set("/f", "big", Data(count: 1), flags: 0, position: UInt32(VolatileXattrStore.maxValueSize))
        }
    }

    @Test func renameMovesSubtreeAndDropClears() throws {
        let s = VolatileXattrStore()
        try s.set("/d/f", "a", Data([1]), flags: 0, position: 0)
        try s.set("/dx", "b", Data([2]), flags: 0, position: 0)
        s.rename("/d", to: "/e")
        #expect(try s.get("/e/f", "a") == Data([1]))
        #expect(s.names("/d/f").isEmpty)
        #expect(s.names("/dx") == ["b"])          // 前綴相同但不是子樹，不受影響
        s.drop("/e")
        #expect(s.names("/e/f").isEmpty)
    }
}
