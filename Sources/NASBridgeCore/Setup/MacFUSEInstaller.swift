import CryptoKit
import Foundation
import Observation

/// 協助使用者安裝 macFUSE 的兩種途徑（都交給系統的安裝介面，由它要求管理者權限；本 app 從不取得 root）：
///
/// 1. 下載安裝：GitHub 最新發行版的 `.dmg` → 以官方 `.sha256` 驗證 → 掛載 dmg 取出 `.pkg`
///    → `pkgutil --check-signature` 確認是 Apple 核發的 Developer ID 簽章 → 交給「安裝程式」
/// 2. Homebrew：產生一個 `.command` 腳本並以「終端機」開啟執行 `brew install --cask macfuse`
///    （用 .command 而非 AppleScript 控制終端機：不需要「自動化」權限）
///
/// 狀態：idle → fetchingRelease → downloading → verifying → openingInstaller → waitingForInstall
///       任一步失敗 → failed（可重試）。是否已安裝由呼叫端以 `FuseLibrary.detect()` 輪詢判斷。
@MainActor @Observable
public final class MacFUSEInstaller {
    public enum Phase: Equatable, Sendable {
        case idle
        case fetchingRelease
        case downloading(Double)
        case verifying
        case openingInstaller
        /// 安裝程式／終端機已開啟，等使用者完成
        case waitingForInstall
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .fetchingRelease, .downloading, .verifying, .openingInstaller: true
            default: false
            }
        }
    }

    public private(set) var phase: Phase = .idle
    /// 已驗證 pkg 的簽章者（顯示給使用者）
    public private(set) var signer: String?
    public private(set) var version: String?

    nonisolated static let releaseAPI = URL(string: "https://api.github.com/repos/macfuse/macfuse/releases/latest")!

    public init() {}

    public var homebrewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - 途徑 1：下載安裝

    public func downloadAndInstall() async {
        guard !phase.isBusy else { return }
        do {
            phase = .fetchingRelease
            let release = try await Self.latestRelease()
            version = release.tag
            phase = .downloading(0)
            let dmg = try await download(release.dmgURL)
            phase = .verifying
            let expected = try await Self.expectedChecksum(release.checksumURL, fileName: release.dmgURL.lastPathComponent)
            let pkg = try await Task.detached { () throws -> (URL, String) in
                guard try Self.sha256(of: dmg) == expected else {
                    throw DAVError.posix(EINVAL, "Checksum mismatch — the download may be corrupted.")
                }
                let pkg = try Self.extractPackage(from: dmg)
                return (pkg, try Self.checkSignature(pkg))
            }.value
            signer = pkg.1
            phase = .openingInstaller
            try await Self.run("/usr/bin/open", [pkg.0.path])
            phase = .waitingForInstall
        } catch let e as DAVError {
            phase = .failed(e.message)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    struct Release: Sendable {
        let tag: String
        let dmgURL: URL
        let checksumURL: URL
    }

    nonisolated static func latestRelease() async throws -> Release {
        var req = URLRequest(url: releaseAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw DAVError.posix(EIO, "Cannot query the latest macFUSE release.") }
        return try parseRelease(data)
    }

    /// 解析 GitHub release JSON：找 `macfuse-x.y.z.dmg` 與同版的 `.sha256`。
    nonisolated static func parseRelease(_ data: Data) throws -> Release {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Body: Decodable { let tag_name: String; let assets: [Asset] }
        let body = try JSONDecoder().decode(Body.self, from: data)
        guard let dmg = body.assets.first(where: { $0.name.hasSuffix(".dmg") }),
              let sum = body.assets.first(where: { $0.name.hasSuffix(".sha256") }) else {
            throw DAVError.posix(ENOENT, "The macFUSE release has no installer image.")
        }
        return Release(tag: body.tag_name, dmgURL: dmg.browser_download_url, checksumURL: sum.browser_download_url)
    }

    /// `.sha256` 檔格式：每行 `<hex>  <檔名>`。
    nonisolated static func expectedChecksum(_ url: URL, fileName: String) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try parseChecksum(String(decoding: data, as: UTF8.self), fileName: fileName)
    }

    nonisolated static func parseChecksum(_ text: String, fileName: String) throws -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count == 2, parts[1] == fileName { return parts[0].lowercased() }
        }
        throw DAVError.posix(ENOENT, "No checksum published for \(fileName).")
    }

    /// 下載到暫存檔並更新進度（每 0.2 秒讀一次 task.progress）。
    private func download(_ url: URL) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        let box = TaskBox()
        let result: URL = try await withCheckedThrowingContinuation { cont in
            let task = URLSession.shared.downloadTask(with: url) { tmp, resp, err in
                if let err { return cont.resume(throwing: err) }
                guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    return cont.resume(throwing: DAVError.posix(EIO, "Download failed."))
                }
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    cont.resume(returning: dest)
                } catch { cont.resume(throwing: error) }
            }
            box.task = task
            task.resume()
            Task { @MainActor [weak self] in
                while let t = box.task, t.state == .running {
                    self?.phase = .downloading(t.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        return result
    }

    private final class TaskBox: @unchecked Sendable { var task: URLSessionDownloadTask? }

    nonisolated static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 掛載 dmg（不出現在 Finder）→ 拷出安裝 pkg 到暫存資料夾 → 卸載 dmg。
    nonisolated static func extractPackage(from dmg: URL) throws -> URL {
        let mountDir = FileManager.default.temporaryDirectory.appendingPathComponent("macfuse-dmg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)
        try runSync("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountDir.path, dmg.path])
        defer { _ = try? runSync("/usr/bin/hdiutil", ["detach", "-force", mountDir.path]) }

        let pkgs = (FileManager.default.enumerator(at: mountDir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "pkg" }
        // 優先選頂層的「Install macFUSE.pkg」
        guard let pkg = pkgs.first(where: { $0.lastPathComponent.hasPrefix("Install") }) ?? pkgs.first else {
            throw DAVError.posix(ENOENT, "No installer package found in the disk image.")
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(pkg.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: pkg, to: dest)
        return dest
    }

    /// macFUSE 作者 Benjamin Fleischer 的 Apple Developer Team ID（2026-10 以 macFUSE 5.4.0 實測確認）。
    nonisolated static let macFUSETeamID = "3T5GSNBU6W"

    /// 要求 Apple 核發的 Developer ID Installer 簽章，且簽章者必須是 macFUSE 作者的 Team ID
    /// （防止 GitHub release 被換成他人簽章的套件）；回傳簽章者名稱。
    nonisolated static func checkSignature(_ pkg: URL) throws -> String {
        let out = try runSync("/usr/sbin/pkgutil", ["--check-signature", pkg.path])
        guard out.contains("signed by a developer certificate issued by Apple"),
              out.contains("Developer ID Installer:"), out.contains("(\(macFUSETeamID))") else {
            throw DAVError.posix(EPERM, "The installer package is not signed by the macFUSE developer.")
        }
        let signer = out.split(separator: "\n").first { $0.contains("Developer ID Installer:") }
        return signer.map { String($0.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces) } ?? "?"
    }

    // MARK: - 途徑 2：Homebrew

    public func installWithHomebrew() async {
        guard let brew = homebrewPath else { return phase = .failed("Homebrew is not installed.") }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("install-macfuse.command")
        let body = """
            #!/bin/bash
            # 由 NAS Bridge 產生：以 Homebrew 安裝 macFUSE（安裝程式會要求管理者密碼）
            echo "==> \(brew) install --cask macfuse"
            "\(brew)" install --cask macfuse
            echo
            echo "完成後請到「系統設定 → 隱私權與安全性」允許 Benjamin Fleischer 的系統軟體，然後重新開機。"
            echo "Done. Allow the system software from Benjamin Fleischer in System Settings → Privacy & Security, then restart."
            read -n 1 -s -r -p "Press any key to close…"
            """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try await Self.run("/usr/bin/open", ["-a", "Terminal", script.path])
            phase = .waitingForInstall
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - 子行程

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await Task.detached { _ = try runSync(tool, args) }.value
    }

    /// 執行工具並回傳 stdout+stderr；非 0 結束碼丟錯。
    @discardableResult
    nonisolated static func runSync(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // 不用 waitUntilExit()：它輪詢目前執行緒的 run loop，在背景執行緒可能永遠等不到
        // （SmartphoneFileManager 實測過）。改以 terminationHandler + semaphore。
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        done.wait()
        guard p.terminationStatus == 0 else {
            throw DAVError.posix(EIO, "\((tool as NSString).lastPathComponent) failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return out
    }
}
