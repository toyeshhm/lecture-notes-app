import Foundation
import LectureKit

/// Where the app's settings live between launches.
///
/// First run imports `~/.config/lecture-notes/config.toml` if the Python CLI was
/// used before, so an existing setup carries over rather than being re-entered.
enum SettingsStore {
    private static let key = "settings.v1"

    static func load() -> LectureKit.Settings {
        if let data = UserDefaults.standard.data(forKey: key),
           let stored = try? JSONDecoder().decode(Settings.self, from: data) {
            return stored
        }
        return ConfigImport.settings() ?? LectureKit.Settings(vault: defaultVault())
    }

    static func save(_ settings: LectureKit.Settings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Obsidian's own vault registry, most recently opened first — the same
    /// trick the Python CLI uses so a first run usually needs no setup.
    private static func defaultVault() -> URL {
        let registry = URL.homeDirectory
            .appending(path: "Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: registry),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = root["vaults"] as? [String: [String: Any]]
        else { return URL.documentsDirectory }

        let best = vaults.values
            .sorted { ($0["ts"] as? Double ?? 0) > ($1["ts"] as? Double ?? 0) }
            .compactMap { $0["path"] as? String }
            .first
        return best.map { URL(fileURLWithPath: $0) } ?? URL.documentsDirectory
    }
}
