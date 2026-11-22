import AppIntents
import Foundation

struct LookUpWordIntent: AppIntent {
    static let title: LocalizedStringResource = "用 Worrd 查词"
    static let description = IntentDescription("查询一个英文或中文单词，弹出词典释义并记录到单词本。")

    static var openAppWhenRun: Bool { true }

    @Parameter(title: "单词", description: "要查询的英文或中文词")
    var word: String

    static var parameterSummary: some ParameterSummary {
        Summary("查询单词 \(\.$word)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        LookupCoordinator.lookup(word, entryPoint: "intent")
        return .result(dialog: "正在查询「\(word)」")
    }
}

struct WorrdShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LookUpWordIntent(),
            phrases: ["用 \(.applicationName) 查词"],
            shortTitle: "查词",
            systemImageName: "character.book.closed"
        )
    }
}
