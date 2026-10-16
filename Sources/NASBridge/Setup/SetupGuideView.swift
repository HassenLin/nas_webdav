import AppKit
import NASBridgeCore
import SwiftUI

/// macFUSE 安裝導引：未偵測到 libfuse 時從 tray 選單開啟。
struct SetupGuideView: View {
    let manager: MountManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                if let fuse = manager.fuse {
                    Text("\(fuse.kind.rawValue) detected: \(fuse.path)")
                } else {
                    Text("macFUSE is not installed")
                }
            } icon: {
                Image(systemName: manager.fuse == nil ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .foregroundStyle(manager.fuse == nil ? .orange : .green)
            }
            .font(.headline)

            Text("NAS Bridge uses macFUSE to present the NAS as a local volume.")

            step(1, "Install macFUSE with Homebrew (asks for your administrator password):",
                 command: "brew install --cask macfuse")
            HStack {
                Text("Or download the installer from")
                Link(destination: URL(string: "https://macfuse.github.io")!) { Text(verbatim: "macfuse.github.io") }
            }
            .padding(.leading, 28)
            step(2, "Open System Settings → Privacy & Security and allow the system software from “Benjamin Fleischer”, then restart.")
            step(3, "On Apple silicon, kernel extensions must first be enabled in Startup Security Utility (Reduced Security) in macOS Recovery.")

            Divider()
            Text("Alternative without a kernel extension: FUSE-T (experimental with NAS Bridge).")
                .font(.callout).foregroundStyle(.secondary)
            commandRow("brew install --cask macos-fuse-t/cask/fuse-t")

            HStack {
                Spacer()
                Button("Check Again") { manager.refreshFUSE() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey, command: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(n).").monospacedDigit().frame(width: 20, alignment: .trailing)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            if let command { commandRow(command).padding(.leading, 28) }
        }
    }

    private func commandRow(_ command: String) -> some View {
        HStack {
            Text(verbatim: command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy")
        }
    }
}
