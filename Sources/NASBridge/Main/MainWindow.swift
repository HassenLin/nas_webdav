import NASBridgeCore
import SwiftUI

/// 主視窗的導覽狀態；tray 選單與 AppDelegate 也透過它切換分頁與選取項目。
@MainActor @Observable
final class MainWindowState {
    enum Tab: Hashable { case mounts, accounts }

    static let shared = MainWindowState()
    var tab: Tab = .mounts
    var selectedMount: UUID?
    var selectedAccount: UUID?

    func show(_ tab: Tab, select id: UUID? = nil) {
        self.tab = tab
        switch tab {
        case .mounts: if let id { selectedMount = id }
        case .accounts: if let id { selectedAccount = id }
        }
        WindowOpener.shared.open(WindowID.main)
    }
}

/// 主視窗：「掛載」與「帳號」兩個分頁。
struct MainWindow: View {
    let manager: MountManager
    @State private var state = MainWindowState.shared

    var body: some View {
        TabView(selection: $state.tab) {
            MountsView(manager: manager)
                .tabItem { Label("Mounts", systemImage: "externaldrive.connected.to.line.below") }
                .tag(MainWindowState.Tab.mounts)
            AccountsView(manager: manager)
                .tabItem { Label("Accounts", systemImage: "person.badge.key") }
                .tag(MainWindowState.Tab.accounts)
        }
        .frame(minWidth: 680, minHeight: 420)
    }
}
