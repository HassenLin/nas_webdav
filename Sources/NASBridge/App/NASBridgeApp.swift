import AppKit
import NASBridgeCore
import SwiftUI

/// 選單列 app：只有 tray 圖示，視窗按需開啟（Info.plist 的 LSUIElement，見 tools/make-app.sh）。
struct NASBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(manager: delegate.manager)
        } label: {
            TrayIcon(manager: delegate.manager)
        }

        Window("NAS Bridge", id: WindowID.main) {
            MainWindow(manager: delegate.manager)
        }
        .defaultSize(width: 820, height: 540)

        Window("Install macFUSE", id: WindowID.setup) {
            MacFUSEDialog(manager: delegate.manager)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

enum WindowID {
    static let main = "main"
    static let setup = "setup"
}

/// tray 圖示：反映整體狀態（有失敗 > 有掛載 > 全部未掛載）。
struct TrayIcon: View {
    let manager: MountManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let states = manager.mounts.map { manager.instance(for: $0.id).state }
        let failed = states.contains { if case .failed = $0 { true } else { false } }
        let mounted = states.contains(.mounted)
        Image(systemName: failed ? "externaldrive.badge.exclamationmark"
              : mounted ? "externaldrive.fill.badge.checkmark" : "externaldrive")
            // tray 圖示在啟動時就會繪製（選單內容要等使用者點開才會），在此登記 openWindow
            .onAppear { WindowOpener.shared.register(openWindow) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = MountManager()
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 單一 app 實例：兩個 app 同時管理同一批掛載點會互相干擾。
        // （「多實例」指多個掛載：每個掛載各一個 worker 子行程，與此不衝突。）
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0 != me }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        // 以 `swift run` 執行（沒有 Info.plist 的 LSUIElement）時也不出現在 Dock
        NSApp.setActivationPolicy(.accessory)
        if manager.fuse == nil {
            WindowOpener.shared.open(WindowID.setup)          // 沒有 macFUSE：先跳安裝對話框
        } else if manager.accounts.isEmpty {
            MainWindowState.shared.show(.accounts)            // 首次使用：先建帳號
        }
        Task { await manager.autoMount() }
    }

    /// 結束前先卸載全部（強制）並等 worker 結束，避免留下失效的掛載點。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateNow }
        quitting = true
        Task {
            await manager.unmountAll(force: true)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.terminateAllWorkers()
    }
}

/// 從 AppDelegate 等非 View 處開視窗：SwiftUI 的 openWindow 只能從 View 環境取得，
/// 由 TrayIcon 出現時登記進來（之前要求的視窗會補開）。
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    private var action: OpenWindowAction?
    private var pending: [String] = []

    func register(_ action: OpenWindowAction) {
        self.action = action
        pending.forEach { open($0) }
        pending.removeAll()
    }

    func open(_ id: String) {
        guard let action else { return pending.append(id) }
        action(id: id)
        NSApp.activate()
    }
}

extension MountManager {
    /// 掛載；未安裝 macFUSE 時改為開啟安裝對話框。
    func mountOrPromptInstall(_ id: UUID) async {
        if await !mount(id) { WindowOpener.shared.open(WindowID.setup) }
    }
}
