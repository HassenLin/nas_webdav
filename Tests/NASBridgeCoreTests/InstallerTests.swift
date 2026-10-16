import Foundation
import Testing
@testable import NASBridgeCore

@Suite struct MacFUSEInstallerTests {
    @Test func parsesReleaseAssets() throws {
        let json = """
        {"tag_name":"macfuse-5.4.0","assets":[
          {"name":"macfuse-5.4.0-debug.tbz","browser_download_url":"https://x/debug.tbz"},
          {"name":"macfuse-5.4.0.dmg","browser_download_url":"https://x/macfuse-5.4.0.dmg"},
          {"name":"macfuse-5.4.0.sha256","browser_download_url":"https://x/macfuse-5.4.0.sha256"}]}
        """
        let r = try MacFUSEInstaller.parseRelease(Data(json.utf8))
        #expect(r.tag == "macfuse-5.4.0")
        #expect(r.dmgURL.lastPathComponent == "macfuse-5.4.0.dmg")
        #expect(r.checksumURL.lastPathComponent == "macfuse-5.4.0.sha256")
    }

    @Test func parsesChecksumFile() throws {
        let text = """
        861814F0AC7FA8F6547EA40CDD49A36AC84BCC7D34F38A1FA74E8CF68B0401C5  macfuse-5.4.0.dmg
        315fa8d7d483960478605252eaa722010daf6e0605bede3c5c10dd5affb9e3f9  macfuse-5.4.0-debug.tbz
        """
        #expect(try MacFUSEInstaller.parseChecksum(text, fileName: "macfuse-5.4.0.dmg")
                == "861814f0ac7fa8f6547ea40cdd49a36ac84bcc7d34f38a1fa74e8cf68b0401c5")
        #expect(throws: DAVError.self) { try MacFUSEInstaller.parseChecksum(text, fileName: "other.dmg") }
    }

    @Test func sha256OfFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nb-sha-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        #expect(try MacFUSEInstaller.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// 實際下載官方 dmg、驗證校驗碼、取出 pkg、檢查簽章——但**不**開啟安裝程式。
    ///   NB_LIVE_MACFUSE=1 swift test --filter MacFUSEInstallerTests
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NB_LIVE_MACFUSE"] != nil))
    func liveDownloadVerifyAndExtract() async throws {
        let release = try await MacFUSEInstaller.latestRelease()
        let (tmp, _) = try await URLSession.shared.download(from: release.dmgURL)
        let dmg = FileManager.default.temporaryDirectory.appendingPathComponent(release.dmgURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dmg)
        try FileManager.default.moveItem(at: tmp, to: dmg)
        defer { try? FileManager.default.removeItem(at: dmg) }
        let expected = try await MacFUSEInstaller.expectedChecksum(release.checksumURL, fileName: dmg.lastPathComponent)
        #expect(try MacFUSEInstaller.sha256(of: dmg) == expected)
        let pkg = try MacFUSEInstaller.extractPackage(from: dmg)
        defer { try? FileManager.default.removeItem(at: pkg) }
        let signer = try MacFUSEInstaller.checkSignature(pkg)
        print("pkg:", pkg.lastPathComponent, "signer:", signer)
        #expect(signer.contains("Benjamin Fleischer"))
    }
}
