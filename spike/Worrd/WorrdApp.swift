import SwiftUI

@main
struct WorrdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Button("单词本…") { WordbookWindowController.shared.show() }
            Button("设置…") { SettingsWindowController.shared.show() }
            Divider()
            Button("关闭浮窗") { PanelController.shared.close() }
            Divider()
            Button("退出 Worrd") { NSApp.terminate(nil) }
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.menu)
    }
}
