import Foundation

/// 帳號與掛載設定的持久化：`~/Library/Application Support/NASBridge/config.json`。
/// 只負責讀寫，不含任何掛載邏輯；密碼不在此檔（鑰匙圈）。
public struct AppConfig: Codable, Equatable, Sendable {
    public var accounts: [Account] = []
    public var mounts: [MountProfile] = []

    public init(accounts: [Account] = [], mounts: [MountProfile] = []) {
        self.accounts = accounts
        self.mounts = mounts
    }
}

public enum ConfigStore {
    public static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NASBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var fileURL: URL { directory.appendingPathComponent("config.json") }

    public static func load(from url: URL = fileURL) -> AppConfig {
        guard let data = try? Data(contentsOf: url) else { return AppConfig() }
        return (try? JSONDecoder().decode(AppConfig.self, from: data)) ?? AppConfig()
    }

    public static func save(_ config: AppConfig, to url: URL = fileURL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: url, options: .atomic)
    }
}
