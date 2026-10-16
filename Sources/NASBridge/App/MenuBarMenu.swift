import AppKit
import NASBridgeCore
import ServiceManagement
import SwiftUI

/// tray 選單：每個連線一個子選單（狀態、掛載／卸載、在 Finder 開啟、編輯），加上全域動作。
struct MenuBarMenu: View {
    let manager: MountManager

    var body: some View {
        Group {
            if manager.fuse == nil {
                Button("macFUSE Is Not Installed…") { WindowOpener.shared.open(WindowID.setup) }
                Divider()
            }
            if manager.profiles.isEmpty {
                Text("No Connections")
            }
            ForEach(manager.profiles) { profile in
                ProfileMenu(profile: profile, instance: manager.instance(for: profile.id), manager: manager)
            }
            Divider()
            Button("Mount All") { Task { await manager.mountAll() } }
                .disabled(manager.profiles.isEmpty)
            Button("Unmount All") { Task { await manager.unmountAll(force: false) } }
                .disabled(manager.mountedCount == 0)
            Divider()
            Button("Connections…") { WindowOpener.shared.open(WindowID.connections) }
                .keyboardShortcut(",")
            LaunchAtLoginToggle()
            Divider()
            Button("Quit NAS Bridge") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

private struct ProfileMenu: View {
    let profile: MountProfile
    let instance: MountInstance
    let manager: MountManager

    var body: some View {
        Menu {
            Text(StatusText.describe(instance.state))
            if let notice = instance.notice { Text(notice) }
            Divider()
            switch instance.state {
            case .unmounted, .failed:
                Button("Mount") { Task { await manager.mount(profile.id) } }
            case .mounted:
                Button("Open in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: instance.mountPoint))
                }
                Button("Unmount") { Task { await manager.unmount(profile.id) } }
                Button("Force Unmount") { Task { await manager.unmount(profile.id, force: true) } }
            case .mounting, .unmounting:
                Button("Cancel") { Task { await manager.unmount(profile.id, force: true) } }
            }
            Divider()
            Button("Edit…") {
                ConnectionsSelection.shared.selected = profile.id
                WindowOpener.shared.open(WindowID.connections)
            }
        } label: {
            Label(profile.name, systemImage: StatusText.symbol(instance.state))
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

/// 狀態的顯示文字與圖示（選單與連線視窗共用）。
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
}
