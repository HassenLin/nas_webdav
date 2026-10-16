import AppKit
import NASBridgeCore
import SwiftUI

/// macFUSE 安裝對話框：啟動時未偵測到 macFUSE、或要掛載卻沒有 macFUSE 時自動開啟。
/// 一鍵「下載並安裝」（官方 dmg、校驗碼與簽章驗證後交給「安裝程式」）或以 Homebrew 安裝；
/// 開著時每 2 秒重新偵測，裝好即切換為「後續步驟」。
struct MacFUSEDialog: View {
    let manager: MountManager
    @State private var installer = MacFUSEInstaller()
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(manager.fuse == nil ? "macFUSE Is Required" : "macFUSE Is Installed")
                        .font(.title2.bold())
                    Text("NAS Bridge uses macFUSE to present your NAS as a local volume in Finder.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let fuse = manager.fuse {
                installedView(fuse)
            } else {
                installView
            }
        }
        .padding(24)
        .frame(width: 520)
        .task {
            // 安裝程式在另一個行程跑，只能輪詢函式庫是否出現
            while !Task.isCancelled {
                manager.refreshFUSE()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - 未安裝

    @ViewBuilder private var installView: some View {
        phaseView
        HStack {
            Button {
                Task { await installer.downloadAndInstall() }
            } label: {
                Label("Download and Install", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(installer.phase.isBusy)
            if installer.homebrewPath != nil {
                Button("Install with Homebrew") { Task { await installer.installWithHomebrew() } }
                    .disabled(installer.phase.isBusy)
            }
            Spacer()
            Button("Later") { dismissWindow(id: WindowID.setup) }
                .keyboardShortcut(.cancelAction)
        }
        Divider()
        nextSteps
        HStack(spacing: 4) {
            Text("More information:")
            Link(destination: URL(string: "https://macfuse.github.io")!) { Text(verbatim: "macfuse.github.io") }
        }
        .font(.callout)
    }

    @ViewBuilder private var phaseView: some View {
        switch installer.phase {
        case .idle:
            Text("Download the official installer from GitHub; its checksum and signature are verified before the macOS Installer opens. You will be asked for an administrator password.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case .fetchingRelease:
            ProgressView("Looking up the latest release…").progressViewStyle(.linear)
        case .downloading(let f):
            ProgressView(value: f) { Text("Downloading \(installer.version ?? "macFUSE")…") }
        case .verifying:
            ProgressView("Verifying checksum and signature…").progressViewStyle(.linear)
        case .openingInstaller:
            ProgressView("Opening Installer…").progressViewStyle(.linear)
        case .waitingForInstall:
            Label("Finish the installation in the Installer or Terminal window. This dialog updates automatically.",
                  systemImage: "hourglass")
                .fixedSize(horizontal: false, vertical: true)
            if let signer = installer.signer {
                Label("Signed by \(signer)", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.green)
            }
        case .failed(let msg):
            Label(msg, systemImage: "xmark.octagon").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 已安裝

    @ViewBuilder private func installedView(_ fuse: FuseLibrary.Installation) -> some View {
        Label("\(fuse.kind.rawValue) detected: \(fuse.path)", systemImage: "checkmark.seal.fill")
            .foregroundStyle(.green)
        nextSteps
        HStack {
            Spacer()
            Button("Done") { dismissWindow(id: WindowID.setup) }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var nextSteps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("After installing").font(.headline)
            step(1, "Open System Settings → Privacy & Security and allow the system software from “Benjamin Fleischer”, then restart.")
            step(2, "On Apple silicon, kernel extensions must first be enabled in Startup Security Utility (Reduced Security) in macOS Recovery.")
            Button("Open Privacy & Security") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!)
            }
            .padding(.leading, 26)
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: "\(n).").monospacedDigit().frame(width: 18, alignment: .trailing)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
