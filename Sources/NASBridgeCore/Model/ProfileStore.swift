import Foundation

/// 連線設定的持久化：`~/Library/Application Support/NASBridge/profiles.json`。
/// 只負責讀寫，不含任何掛載邏輯。
public enum ProfileStore {
    public static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NASBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }

    public static func load() -> [MountProfile] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([MountProfile].self, from: data)) ?? []
    }

    public static func save(_ profiles: [MountProfile]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(profiles).write(to: fileURL, options: .atomic)
    }
}
