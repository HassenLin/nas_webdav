import NASBridgeCore
import SwiftUI

/// 帳號管理：表格列出 名稱／伺服器網址／帳號／密碼（鑰匙圈）／使用中的掛載數。
/// 雙擊或「編輯…」以表單編輯；被掛載使用中的帳號不能刪除。
struct AccountsView: View {
    let manager: MountManager
    @State private var state = MainWindowState.shared
    @State private var editing: AccountDraft?
    @State private var confirmDelete: Account?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Table(manager.accounts, selection: $state.selectedAccount) {
                TableColumn("Name") { Text($0.displayName) }
                TableColumn("Server URL") { Text($0.serverURL).textSelection(.enabled) }
                TableColumn("Username") { Text($0.username) }
                TableColumn("Password") { PasswordCell(account: $0) }
                    .width(min: 140, ideal: 170)
                TableColumn("Mounts") { a in Text("\(manager.mounts(using: a.id).count)").monospacedDigit() }
                    .width(56)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let a = manager.account(id) {
                    Button("Edit…") { edit(a) }
                    Button("Delete…", role: .destructive) { confirmDelete = a }
                }
            } primaryAction: { ids in
                if let id = ids.first, let a = manager.account(id) { edit(a) }
            }
            .overlay {
                if manager.accounts.isEmpty {
                    ContentUnavailableView {
                        Label("No Accounts", systemImage: "person.badge.key")
                    } description: {
                        Text("Add the URL, username and password of your Synology WebDAV server. The password is stored in the keychain.")
                    } actions: {
                        Button("Add Account") { add() }
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button { add() } label: { Image(systemName: "plus") }.help("Add Account")
                Button { if let a = selected { confirmDelete = a } } label: { Image(systemName: "minus") }
                    .help("Delete Account").disabled(selected == nil)
                Button("Edit…") { if let a = selected { edit(a) } }.disabled(selected == nil)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2)
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .sheet(item: $editing) { draft in
            AccountEditor(manager: manager, initial: draft.account, isNew: draft.isNew) { saved in
                state.selectedAccount = saved.id
            }
        }
        .confirmationDialog("Delete account “\(confirmDelete?.displayName ?? "")”?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let a = confirmDelete { delete(a) } }
        } message: {
            Text("The password is also removed from the keychain.")
        }
    }

    private var selected: Account? { state.selectedAccount.flatMap(manager.account) }

    private func add() { error = nil; editing = AccountDraft(account: Account(), isNew: true) }
    private func edit(_ a: Account) { error = nil; editing = AccountDraft(account: a, isNew: false) }

    private func delete(_ a: Account) {
        do {
            try manager.deleteAccount(a.id)
            error = nil
        } catch let e as DAVError {
            error = e.message
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AccountDraft: Identifiable {
    var account: Account
    var isNew: Bool
    var id: UUID { account.id }
}

/// 密碼欄：預設遮罩，按眼睛圖示才從鑰匙圈讀出顯示（可能觸發鑰匙圈授權提示）。
private struct PasswordCell: View {
    let account: Account
    @State private var revealed: String??    // nil＝未讀取；.some(nil)＝鑰匙圈沒有

    var body: some View {
        HStack(spacing: 4) {
            switch revealed {
            case .none: Text(verbatim: "••••••••").foregroundStyle(.secondary)
            case .some(.none): Text("Not in Keychain").foregroundStyle(.orange)
            case .some(.some(let pw)): Text(verbatim: pw).textSelection(.enabled).font(.system(.body, design: .monospaced))
            }
            Spacer(minLength: 0)
            Button {
                revealed = revealed == nil ? .some(KeychainStore.password(for: account)) : nil
            } label: {
                Image(systemName: revealed == nil ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .help(revealed == nil ? "Show Password" : "Hide Password")
        }
        .onChange(of: account) { revealed = nil }
    }
}
