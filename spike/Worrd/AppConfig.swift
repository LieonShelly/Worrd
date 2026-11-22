import Foundation

struct AIConfig: Codable {
    var enabled: Bool = false
    var baseURL: String = "https://api.deepseek.com/v1"
    var model: String = "deepseek-chat"
    var apiKey: String = ""

    var isUsable: Bool {
        enabled
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: baseURL) != nil
    }
}

struct AppConfig: Codable {
    var ai: AIConfig = AIConfig()
}

@MainActor
final class ConfigStore {
    static let shared = ConfigStore()

    private(set) var config = AppConfig()
    let fileURL: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Worrd", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("config.json")
        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            print("[Worrd] config decode failed")
            return
        }
        config = decoded
    }

    func updateAI(_ ai: AIConfig) {
        config.ai = ai
        save()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            print("[Worrd] config saved")
        } catch {
            print("[Worrd] config save failed: \(error.localizedDescription)")
        }
    }
}
