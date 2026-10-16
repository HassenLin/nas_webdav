import Foundation
import Observation

/// 所有連線設定與其掛載執行體的協調者（app 唯一持有的模型）。
///
/// 職責：profile 的增刪改與持久化（JSON＋鑰匙圈）、把掛載／卸載指令轉給對應的 `MountInstance`。
/// 多實例：每個 profile 各有一個 instance、各自一個 worker 子行程，互不影響。
@MainActor @Observable
public final class MountManager {
    public private(set) var profiles: [MountProfile]
    public private(set) var fuse: FuseLibrary.Installation?
    @ObservationIgnored private var instances: [UUID: MountInstance] = [:]
    @ObservationIgnored private let workerURL: URL

    /// - Parameter workerURL: worker 執行檔（預設為本程式自己，以 `--fuse-worker` 啟動）。
    public init(workerURL: URL? = nil, profiles: [MountProfile] = ProfileStore.load()) {
        self.workerURL = workerURL ?? Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        self.profiles = profiles
        self.fuse = FuseLibrary.detect()
    }

    public func instance(for id: UUID) -> MountInstance {
        if let i = instances[id] { return i }
        let i = MountInstance(id: id, workerURL: workerURL)
        instances[id] = i
        return i
    }

    public func profile(_ id: UUID) -> MountProfile? { profiles.first { $0.id == id } }

    public var mountedCount: Int { profiles.count { instance(for: $0.id).state == .mounted } }

    public func refreshFUSE() { fuse = FuseLibrary.detect() }

    // MARK: - Profile 編輯

    /// 新增或更新設定；password 為 nil 表示不變更已存的密碼。
    /// 變更在下次掛載時生效。
    public func save(_ profile: MountProfile, password: String?) throws {
        if let msg = profile.validationError() { throw DAVError.posix(EINVAL, msg) }
        let mp = profile.resolvedMountPoint
        if profiles.contains(where: { $0.id != profile.id && $0.resolvedMountPoint == mp }) {
            throw DAVError.posix(EEXIST, "Another connection already uses mount point \(mp).")
        }
        var next = profiles
        if let i = next.firstIndex(where: { $0.id == profile.id }) { next[i] = profile } else { next.append(profile) }
        try ProfileStore.save(next)
        profiles = next
        if let password, !KeychainStore.setPassword(password, for: profile.id) {
            throw DAVError.posix(EIO, "Cannot save the password to the keychain.")
        }
    }

    public func delete(_ id: UUID) async {
        await unmount(id, force: true)
        await instance(for: id).waitUntilStopped(timeout: .seconds(5))
        profiles.removeAll { $0.id == id }
        try? ProfileStore.save(profiles)
        KeychainStore.delete(for: id)
        instances[id] = nil
    }

    // MARK: - 掛載

    public func mount(_ id: UUID) async {
        guard let profile = profile(id) else { return }
        refreshFUSE()
        let inst = instance(for: id)
        guard fuse != nil else {
            return await inst.mount(profile, password: "")   // worker 會回報「未安裝 macFUSE」
        }
        await inst.mount(profile, password: KeychainStore.password(for: id) ?? "")
    }

    public func unmount(_ id: UUID, force: Bool = false) async {
        await instance(for: id).unmount(force: force)
    }

    public func mountAll() async {
        for p in profiles { await mount(p.id) }
    }

    /// 啟動時自動掛載勾選的連線。
    public func autoMount() async {
        for p in profiles where p.autoMount { await mount(p.id) }
    }

    /// 全部卸載並等待 worker 結束（結束 app 前呼叫）。
    public func unmountAll(force: Bool) async {
        for p in profiles { await unmount(p.id, force: force) }
        for p in profiles { await instance(for: p.id).waitUntilStopped(timeout: .seconds(5)) }
    }

    /// app 即將結束的同步保險：仍在執行的 worker 一律 SIGTERM（libfuse 收到後會卸載並結束）。
    public func terminateAllWorkers() {
        instances.values.forEach { $0.terminateWorker() }
    }
}
