import NASBridgeCore
import SwiftUI

/// 掛載分頁：左側掛載清單（含狀態），右側編輯器。
struct MountsView: View {
    let manager: MountManager
    @State private var state = MainWindowState.shared
    /// 尚未儲存的新掛載（儲存後就出現在 manager.mounts）
    @State private var draft: MountProfile?

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selectedMount) {
                ForEach(manager.mounts) { m in
                    row(m.name, subtitle(m), state: manager.instance(for: m.id).state).tag(m.id)
                }
                if let draft {
                    row(String(localized: "New Mount"), "", state: nil).tag(draft.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                ToolbarItem {
                    Button { addMount() } label: { Label("Add Mount", systemImage: "plus") }
                        .help("Add Mount")
                }
            }
        } detail: {
            if let id = state.selectedMount, let m = manager.mountProfile(id) ?? (draft?.id == id ? draft : nil) {
                MountEditor(manager: manager, initial: m, isNew: manager.mountProfile(id) == nil,
                            onSaved: { draft = nil },
                            onDeleted: { draft = nil; state.selectedMount = manager.mounts.first?.id })
                    .id(id)
            } else {
                ContentUnavailableView {
                    Label("No Mount Selected", systemImage: "externaldrive")
                } description: {
                    Text("A mount presents a folder of a NAS account as a local volume.")
                } actions: {
                    Button("Add Mount") { addMount() }
                }
            }
        }
        .onAppear {
            if state.selectedMount == nil { state.selectedMount = manager.mounts.first?.id }
        }
    }

    private func addMount() {
        var m = MountProfile(accountID: manager.accounts.first?.id ?? UUID())
        if let a = manager.accounts.first { m.name = a.displayName }
        draft = m
        state.selectedMount = m.id
    }

    private func subtitle(_ m: MountProfile) -> String {
        let account = manager.account(m.accountID)?.displayName ?? "?"
        return m.remotePath == "/" ? account : "\(account)\(m.remotePath.hasPrefix("/") ? "" : "/")\(m.remotePath)"
    }

    private func row(_ title: String, _ subtitle: String, state: MountState?) -> some View {
        HStack {
            Image(systemName: state.map(StatusText.symbol) ?? "plus.circle")
                .foregroundStyle(StatusText.color(state))
            VStack(alignment: .leading) {
                Text(title)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
