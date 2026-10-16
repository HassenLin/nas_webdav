import AppKit
import NASBridgeCore
import ServiceManagement
import SwiftUI

/// tray 選單：每個掛載一個子選單（狀態、掛載／卸載、在 Finder 開啟、編輯），加上全域動作。
struct MenuBarMenu: View {
    let manager: MountManager

    var body: some View {
        if manager.fuse == nil {
            Button("Install macFUSE…") { WindowOpener.shared.open(WindowID.setup) }
            Divider()
        }
        if manager.mounts.isEmpty {
            Text("No Mounts")
        }
        ForEach(manager.mounts) { mount in
            MountMenu(mount: mount, instance: manager.instance(for: mount.id), manager: manager)
        }
        Divider()
        Button("Mount All") {
            Task { if await !manager.mountAll() { WindowOpener.shared.open(WindowID.setup) } }
        }
        .disabled(manager.mounts.isEmpty)
        Button("Unmount All") { Task { await manager.unmountAll(force: false) } }
            .disabled(manager.mountedCount == 0)
        Divider()
        Button("Mounts…") { MainWindowState.shared.show(.mounts) }
            .keyboardShortcut(",")
        Button("Accounts…") { MainWindowState.shared.show(.accounts) }
        LaunchAtLoginToggle()
        Divider()
        Button("Quit NAS Bridge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

private struct MountMenu: View {
    let mount: MountProfile
    let instance: MountInstance
    let manager: MountManager

    var body: some View {
        Menu {
            Text(StatusText.describe(instance.state))
            if let notice = instance.notice { Text(notice) }
            Divider()
            switch instance.state {
            case .unmounted, .failed:
                Button("Mount") { Task { await manager.mountOrPromptInstall(mount.id) } }
            case .mounted:
                Button("Open in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: instance.mountPoint))
                }
                Button("Unmount") { Task { await manager.unmount(mount.id) } }
                Button("Force Unmount") { Task { await manager.unmount(mount.id, force: true) } }
            case .mounting, .unmounting:
                Button("Cancel") { Task { await manager.unmount(mount.id, force: true) } }
            }
            Divider()
            Button("Edit…") { MainWindowState.shared.show(.mounts, select: mount.id) }
        } label: {
            Label(mount.name, systemImage: StatusText.symbol(instance.state))
        }
    }
}

/// 登入時啟動（SMAppService，只在 .app bundle 內有效）。
private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Launch at Login", isOn: Binding(
            get: { enabled },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSSound.beep()
                }
                enabled = SMAppService.mainApp.status == .enabled
            }))
    }
}

/// 狀態的顯示文字與圖示（選單與主視窗共用）。
enum StatusText {
    static func describe(_ s: MountState) -> String {
        switch s {
        case .unmounted: String(localized: "Not mounted")
        case .mounting: String(localized: "Mounting…")
        case .mounted: String(localized: "Mounted")
        case .unmounting: String(localized: "Unmounting…")
        case .failed(let msg): String(localized: "Error: \(msg)")
        }
    }

    static func symbol(_ s: MountState) -> String {
        switch s {
        case .unmounted: "circle"
        case .mounting, .unmounting: "arrow.triangle.2.circlepath"
        case .mounted: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    static func color(_ s: MountState?) -> Color {
        switch s {
        case .mounted: .green
        case .failed: .orange
        case .mounting, .unmounting: .blue
        default: .secondary
        }
    }
}
