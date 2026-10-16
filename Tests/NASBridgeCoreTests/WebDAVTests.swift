import Foundation
import Testing
@testable import NASBridgeCore

@Suite struct WebDAVClientTests {
    let client = WebDAVClient(baseURL: URL(string: "https://nas:5006/home")!, username: "u", password: "p")

    @Test func urlEncodesSegments() {
        #expect(client.url(for: "/").absoluteString == "https://nas:5006/home/")
        #expect(client.url(for: "/a b/c#?;.txt").absoluteString == "https://nas:5006/home/a%20b/c%23%3F%3B.txt")
        // NFD（macOS 檔名）→ NFC
        let nfd = "/caf\u{0065}\u{0301}"
        #expect(client.url(for: nfd).absoluteString == "https://nas:5006/home/caf%C3%A9")
    }

    @Test func hrefToRelativePath() {
        #expect(client.relativePath(fromHref: "/home/") == "/")
        #expect(client.relativePath(fromHref: "/home/a%20b/") == "/a b")
        #expect(client.relativePath(fromHref: "https://nas:5006/home/x.txt") == "/x.txt")
        #expect(client.relativePath(fromHref: "/other/x") == nil)
    }
}

@Suite struct MultistatusTests {
    // 取自 Synology WebDAV Server（Apache mod_dav）回應的格式
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:" xmlns:ns0="DAV:">
    <D:response><D:href>/public/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>
    <D:getlastmodified>Fri, 16 Oct 2026 16:11:48 GMT</D:getlastmodified>
    <D:quota-available-bytes>1000</D:quota-available-bytes><D:quota-used-bytes>24</D:quota-used-bytes>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
    <D:propstat><D:prop><D:getcontentlength/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>
    </D:response>
    <D:response><D:href>/public/%E4%B8%AD%E6%96%87.txt</D:href>
    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>42</D:getcontentlength>
    <D:creationdate>2026-10-01T08:00:00Z</D:creationdate></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
    </D:multistatus>
    """

    @Test func parsesEntries() throws {
        let r = MultistatusParser.parse(Data(xml.utf8))
        #expect(r.count == 2)
        #expect(r[0].isCollection)
        #expect(r[0].quotaAvailable == 1000 && r[0].quotaUsed == 24)
        #expect(r[0].lastModified == Date(timeIntervalSince1970: 1_792_167_108))
        #expect(!r[1].isCollection)
        #expect(r[1].contentLength == 42)
        #expect(r[1].creationDate != nil)
        let c = WebDAVClient(baseURL: URL(string: "https://h:9001/public")!, username: "", password: "")
        #expect(c.relativePath(fromHref: r[1].href) == "/中文.txt")
    }
}
