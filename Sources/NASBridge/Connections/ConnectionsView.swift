import NASBridgeCore
import SwiftUI

/// 連線視窗目前選取的項目；tray 選單的「編輯…」也會設定它。
@MainActor @Observable
final class ConnectionsSelection {
    static let shared = ConnectionsSelection()
    var selected: UUID?
}

/// 連線管理視窗：左側清單（含狀態），右側編輯器。
struct ConnectionsView: View {
    let manager: MountManager
    @State private var selection = ConnectionsSelection.shared
    /// 尚未儲存的新連線（儲存後就出現在 manager.profiles）
    @State private var draft: MountProfile?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.selected) {
                ForEach(manager.profiles) { p in
                    row(p.name, p.serverURL, state: manager.instance(for: p.id).state).tag(p.id)
                }
                if let draft {
                    row(String(localized: "New Connection"), "", state: nil).tag(draft.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                ToolbarItem {
                    Button { addConnection() } label: { Label("Add Connection", systemImage: "plus") }
                        .help("Add Connection")
                }
            }
        } detail: {
            if let id = selection.selected, let profile = manager.profile(id) ?? (draft?.id == id ? draft : nil) {
                ProfileEditor(manager: manager, initial: profile, isNew: manager.profile(id) == nil,
                              onSaved: { draft = nil },
                              onDeleted: { draft = nil; selection.selected = manager.profiles.first?.id })
                    .id(id)
            } else {
                ContentUnavailableView {
                    Label("No Connection Selected", systemImage: "externaldrive")
                } description: {
                    Text("Add a Synology WebDAV connection to mount it as a local volume.")
                } actions: {
                    Button("Add Connection") { addConnection() }
                }
            }
        }
        .onAppear {
            if selection.selected == nil { selection.selected = manager.profiles.first?.id }
        }
    }

    private func addConnection() {
        let p = MountProfile()
        draft = p
        selection.selected = p.id
    }

    private func row(_ title: String, _ subtitle: String, state: MountState?) -> some View {
        HStack {
            Image(systemName: state.map(StatusText.symbol) ?? "plus.circle")
                .foregroundStyle(color(state))
            VStack(alignment: .leading) {
                Text(title)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func color(_ s: MountState?) -> Color {
        switch s {
        case .mounted: .green
        case .failed: .orange
        case .mounting, .unmounting: .blue
        default: .secondary
        }
    }
}
