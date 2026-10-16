import Foundation
import Testing
@testable import NASBridgeCore

@Suite struct MountProfileTests {
    func profile(_ server: String, _ remote: String = "/") -> MountProfile {
        var p = MountProfile()
        p.serverURL = server
        p.remotePath = remote
        p.username = "u"
        return p
    }

    @Test func baseURLJoinsRemotePath() {
        #expect(profile("https://nas:5006", "/home").baseURL?.absoluteString == "https://nas:5006/home")
        #expect(profile("https://nas:5006/", "home/").baseURL?.absoluteString == "https://nas:5006/home")
        #expect(profile("https://nas:9001", "/").baseURL?.absoluteString == "https://nas:9001")
        #expect(profile("https://nas/dav", "/a b").baseURL?.path(percentEncoded: false) == "/dav/a b")
    }

    @Test func onlyHTTPSAllowed() {
        #expect(profile("http://nas:5005").validationError() == "Only https:// is allowed.")
        #expect(profile("https://nas:5006").validationError() == nil)
        #expect(profile("https://").validationError() == "Server URL is invalid.")
    }

    @Test func fingerprintNormalization() {
        let fp = "C8:00:5F:75:B6:3B:36:DD:A1:16:49:78:77:89:D1:B2:6D:B5:69:DB:8B:87:02:64:DB:7F:E5:4D:1D:B6:FA:2F"
        #expect(MountProfile.normalizeFingerprint(fp).count == 64)
        var p = profile("https://nas")
        p.pinnedCertSHA256 = "abc"
        #expect(p.validationError() != nil)
    }

    @Test func defaultMountPointUnderHomeVolumes() {
        var p = profile("https://nas")
        p.name = "My/NAS"
        #expect(p.resolvedMountPoint.hasSuffix("/Volumes/My-NAS"))
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
        var p = MountProfile()
        p.name = "a,b=c"
        p.serverURL = "https://nas.local:5006"
        p.readOnly = true
        let opts = WorkerMain.mountOptions(p)
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
