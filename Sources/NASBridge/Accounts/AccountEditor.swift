import NASBridgeCore
import SwiftUI

/// 帳號編輯表單（sheet）：網址、帳號、密碼（鑰匙圈）、憑證釘選、測試連線。
struct AccountEditor: View {
    let manager: MountManager
    let isNew: Bool
    let onSaved: (Account) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var account: Account
    /// 空字串＝沿用鑰匙圈中的密碼
    @State private var password = ""
    @State private var testing = false
    @State private var report: ConnectionReport?
    @State private var error: String?

    init(manager: MountManager, initial: Account, isNew: Bool, onSaved: @escaping (Account) -> Void = { _ in }) {
        self.manager = manager
        self.isNew = isNew
        self.onSaved = onSaved
        _account = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(isNew ? "New Account" : "Account") {
                    TextField("Server URL", text: $account.serverURL, prompt: Text(verbatim: "https://nas.local:5006"))
                    TextField("Username", text: $account.username)
                    SecureField("Password", text: $password,
                                prompt: Text(isNew ? "Stored in the keychain" : "Saved in Keychain — leave blank to keep"))
                    TextField("Name", text: $account.name, prompt: Text(account.url?.host() ?? String(localized: "Optional")))
                }
                Section {
                    TextField("Pinned certificate SHA-256", text: $account.pinnedCertSHA256,
                              prompt: Text("Empty — use system trust"))
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Security")
                } footer: {
                    Text("HTTPS only. Pin the certificate fingerprint when the NAS uses a self-signed certificate.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let report { Section("Connection Test") { reportView(report) } }
                if let error {
                    Section { Label(error, systemImage: "xmark.octagon").foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Test Connection", action: test).disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 470)
    }

    @ViewBuilder private func reportView(_ r: ConnectionReport) -> some View {
        Label(r.message, systemImage: r.ok ? "checkmark.seal" : "xmark.octagon")
            .foregroundStyle(r.ok ? .green : .red)
            .textSelection(.enabled)
        if let fp = r.untrustedFingerprint {
            Text(fp).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button("Trust This Certificate") {
                account.pinnedCertSHA256 = fp
                report = nil
            }
        }
    }

    /// 測試用密碼：有輸入就用輸入的，否則用鑰匙圈（含使用者先前在別處存的同伺服器密碼）。
    private var effectivePassword: String {
        password.isEmpty ? (KeychainStore.password(for: account) ?? "") : password
    }

    private func test() {
        testing = true
        report = nil
        let (a, pw) = (account, effectivePassword)
        Task {
            report = await ConnectionTester.test(a, password: pw)
            testing = false
        }
    }

    private func save() {
        error = nil
        account.pinnedCertSHA256 = Account.normalizeFingerprint(account.pinnedCertSHA256)
        if password.isEmpty, isNew, KeychainStore.password(for: account) == nil {
            return error = String(localized: "Password is required.")
        }
        do {
            try manager.saveAccount(account, password: password.isEmpty ? nil : password)
            onSaved(account)
            dismiss()
        } catch let e as DAVError {
            error = e.message
        } catch {
            self.error = error.localizedDescription
        }
    }
}
