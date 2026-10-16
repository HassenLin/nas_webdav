import Foundation
import Observation

/// 帳號、掛載設定與掛載執行體的協調者（app 唯一持有的模型）。
///
/// 職責：
///   - 帳號（`Account`＋鑰匙圈密碼）與掛載（`MountProfile`）的增刪改與持久化（`ConfigStore`）
///   - 把掛載／卸載指令轉給對應的 `MountInstance`
/// 多實例：每個掛載各有一個 instance、各自一個 worker 子行程，互不影響；多個掛載可共用一個帳號。
@MainActor @Observable
public final class MountManager {
    public private(set) var accounts: [Account]
    public private(set) var mounts: [MountProfile]
    public private(set) var fuse: FuseLibrary.Installation?
    @ObservationIgnored private var instances: [UUID: MountInstance] = [:]
    @ObservationIgnored private let workerURL: URL
    @ObservationIgnored private let configURL: URL

    /// - Parameter workerURL: worker 執行檔（預設為本程式自己，以 `--fuse-worker` 啟動）。
    /// - Parameter configURL: 設定檔位置（測試可注入暫存路徑）。
    public init(workerURL: URL? = nil, configURL: URL = ConfigStore.fileURL) {
        self.workerURL = workerURL ?? Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        self.configURL = configURL
        let config = ConfigStore.load(from: configURL)
        self.accounts = config.accounts
        self.mounts = config.mounts
        self.fuse = FuseLibrary.detect()
    }

    // MARK: - 查詢

    public func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }
    public func mountProfile(_ id: UUID) -> MountProfile? { mounts.first { $0.id == id } }
    public func mounts(using accountID: UUID) -> [MountProfile] { mounts.filter { $0.accountID == accountID } }

    public func instance(for id: UUID) -> MountInstance {
        if let i = instances[id] { return i }
        let i = MountInstance(id: id, workerURL: workerURL)
        instances[id] = i
        return i
    }

    public var mountedCount: Int { mounts.count { instance(for: $0.id).state == .mounted } }

    @discardableResult
    public func refreshFUSE() -> Bool {
        fuse = FuseLibrary.detect()
        return fuse != nil
    }

    private func persist(accounts: [Account]? = nil, mounts: [MountProfile]? = nil) throws {
        let config = AppConfig(accounts: accounts ?? self.accounts, mounts: mounts ?? self.mounts)
        try ConfigStore.save(config, to: configURL)
        self.accounts = config.accounts
        self.mounts = config.mounts
    }

    // MARK: - 帳號

    /// 新增或更新帳號；password 為 nil 表示不變更鑰匙圈中的密碼。
    /// 伺服器或使用者名稱變更時，鑰匙圈項目的鍵也跟著變，舊密碼會搬到新鍵。
    public func saveAccount(_ account: Account, password: String?) throws {
        if let msg = account.validationError() { throw DAVError.posix(EINVAL, msg) }
        let old = self.account(account.id)
        let keyChanged = old.map { $0.url != account.url || $0.username != account.username } ?? false
        let pw = password ?? (keyChanged ? old.flatMap(KeychainStore.password(for:)) : nil)
        if let pw, !KeychainStore.setPassword(pw, for: account) {
            throw DAVError.posix(EIO, "Cannot save the password to the keychain.")
        }
        if keyChanged, let old, !accounts.contains(where: { $0.id != old.id && $0.url == old.url && $0.username == old.username }) {
            KeychainStore.delete(for: old)
        }
        var next = accounts
        if let i = next.firstIndex(where: { $0.id == account.id }) { next[i] = account } else { next.append(account) }
        try persist(accounts: next)
    }

    /// 刪除帳號（含鑰匙圈密碼）。仍有掛載使用時拒絕，避免留下無帳號的掛載。
    public func deleteAccount(_ id: UUID) throws {
        guard let account = account(id) else { return }
        let users = mounts(using: id)
        if !users.isEmpty {
            throw DAVError.posix(EBUSY, "Used by: \(users.map(\.name).joined(separator: ", ")). Delete those mounts first.")
        }
        try persist(accounts: accounts.filter { $0.id != id })
        if !accounts.contains(where: { $0.url == account.url && $0.username == account.username }) {
            KeychainStore.delete(for: account)
        }
    }

    // MARK: - 掛載設定

    /// 新增或更新掛載設定；變更在下次掛載時生效。
    public func saveMount(_ mount: MountProfile) throws {
        if let msg = mount.validationError() { throw DAVError.posix(EINVAL, msg) }
        guard account(mount.accountID) != nil else { throw DAVError.posix(EINVAL, "Choose an account.") }
        let mp = mount.resolvedMountPoint
        if mounts.contains(where: { $0.id != mount.id && $0.resolvedMountPoint == mp }) {
            throw DAVError.posix(EEXIST, "Another mount already uses \(mp).")
        }
        var next = mounts
        if let i = next.firstIndex(where: { $0.id == mount.id }) { next[i] = mount } else { next.append(mount) }
        try persist(mounts: next)
    }

    public func deleteMount(_ id: UUID) async {
        await unmount(id, force: true)
        await instance(for: id).waitUntilStopped(timeout: .seconds(5))
        try? persist(mounts: mounts.filter { $0.id != id })
        instances[id] = nil
    }

    // MARK: - 掛載操作

    /// 掛載。回傳 false 表示未安裝 FUSE（呼叫端應顯示安裝對話框），此時不改變狀態。
    @discardableResult
    public func mount(_ id: UUID) async -> Bool {
        guard refreshFUSE() else { return false }
        guard let m = mountProfile(id), let account = account(m.accountID) else { return true }
        let password = KeychainStore.password(for: account) ?? ""
        await instance(for: id).mount(WorkerConfig(account: account, mount: m, password: password))
        return true
    }

    public func unmount(_ id: UUID, force: Bool = false) async {
        await instance(for: id).unmount(force: force)
    }

    @discardableResult
    public func mountAll() async -> Bool {
        for m in mounts { guard await mount(m.id) else { return false } }
        return true
    }

    /// 啟動時自動掛載勾選的項目。未安裝 FUSE 時回傳 false。
    @discardableResult
    public func autoMount() async -> Bool {
        for m in mounts where m.autoMount { guard await mount(m.id) else { return false } }
        return true
    }

    /// 全部卸載並等待 worker 結束（結束 app 前呼叫）。
    public func unmountAll(force: Bool) async {
        for m in mounts { await unmount(m.id, force: force) }
        for m in mounts { await instance(for: m.id).waitUntilStopped(timeout: .seconds(5)) }
    }

    /// app 即將結束的同步保險：仍在執行的 worker 一律 SIGTERM（libfuse 收到後會卸載並結束）。
    public func terminateAllWorkers() {
        instances.values.forEach { $0.terminateWorker() }
    }
}
