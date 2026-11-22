import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IONBF, 0)
        NSApp.setActivationPolicy(.accessory)

        // Register the "用 Worrd 查词" service (System Settings > Keyboard > Shortcuts > Services).
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Custom URL scheme: worrd://theme or worrd://lookup?q=theme
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        let dictionary = DictionaryService.shared
        print("[Worrd] launched · dictionary=\(dictionary.dictionaryName) · \(dictionary.dictionaryPath)")
        if let icon = NSImage(named: "MenuBarIcon") {
            print("[Worrd] menubar icon loaded · \(icon.size)")
        } else {
            print("[Worrd] menubar icon MISSING")
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "worrd" {
            if Self.isSettingsShotURL(url) {
                SettingsWindowController.shared.show()
                SettingsWindowController.shared.snapshot(to: "/tmp/worrd-settings.png")
                continue
            }
            if Self.isSchemeURL(url) {
                handleSchemeURL(url)
                continue
            }
            if Self.isSettingsShotURL(url) {
            SettingsWindowController.shared.show()
            SettingsWindowController.shared.snapshot(to: "/tmp/worrd-settings.png")
            return
        }
        if Self.isSchemeURL(url) {
            handleSchemeURL(url)
            return
        }
        if Self.isWBSnapshotURL(url) {
                WordbookWindowController.shared.show()
                WordbookWindowController.shared.snapshot(to: "/tmp/worrd-wordbook.png")
                continue
            }
            if Self.isWordbookURL(url) {
                WordbookWindowController.shared.show()
                continue
            }
            if Self.isSnapshotURL(url) {
                snapshotPanel(url)
                continue
            }
            let word = Self.word(from: url)
            print("[Worrd] open urls: \(url.absoluteString) -> \(word)")
            guard !word.isEmpty else { continue }
            lookup(word, entryPoint: "url")
        }
    }

    @objc
    private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else {
            print("[Worrd] bad url event")
            return
        }
        if Self.isSettingsShotURL(url) {
            SettingsWindowController.shared.show()
            SettingsWindowController.shared.snapshot(to: "/tmp/worrd-settings.png")
            return
        }
        if Self.isSchemeURL(url) {
            handleSchemeURL(url)
            return
        }
        if Self.isWBSnapshotURL(url) {
            WordbookWindowController.shared.show()
            WordbookWindowController.shared.snapshot(to: "/tmp/worrd-wordbook.png")
            return
        }
        if Self.isWordbookURL(url) {
            WordbookWindowController.shared.show()
            return
        }
        if Self.isSnapshotURL(url) {
            snapshotPanel(url)
            return
        }
        let word = Self.word(from: url)
        print("[Worrd] url event: \(string) -> \(word)")
        NSLog("[Worrd] url event: %@ -> %@", string, word)
        guard !word.isEmpty else { return }
        lookup(word, entryPoint: "url")
    }

    static func isSchemeURL(_ url: URL) -> Bool {
        url.host?.lowercased() == "view" && url.path.lowercased().contains("scheme")
    }

    static func isSettingsShotURL(_ url: URL) -> Bool {
        url.host?.lowercased() == "view" && url.path.lowercased().contains("settingsshot")
    }

    private func handleSchemeURL(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        if let name = items?.first(where: { $0.name == "add" })?.value {
            do {
                try SchemeAliasManager.shared.install(name)
                print("[Worrd] alias added: \(name)")
            } catch {
                print("[Worrd] alias add failed: \(error.localizedDescription)")
            }
        } else if let name = items?.first(where: { $0.name == "remove" })?.value {
            do {
                try SchemeAliasManager.shared.remove(name)
                print("[Worrd] alias removed: \(name)")
            } catch {
                print("[Worrd] alias remove failed: \(error.localizedDescription)")
            }
        }
    }

    static func isWBSnapshotURL(_ url: URL) -> Bool {
        url.host?.lowercased() == "view" && url.path.lowercased().contains("wbshot")
    }

    /// `worrd://view/snapshot?q=theme` renders the panel to /tmp/worrd-panel.png (debug helper).
    static func isSnapshotURL(_ url: URL) -> Bool {
        url.host?.lowercased() == "view" && url.path.lowercased().contains("snapshot")
    }

    private func snapshotPanel(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let word = items?.first(where: { $0.name == "q" })?.value ?? "theme"
        let customDelay = items?.first(where: { $0.name == "delay" })?.value.flatMap(Double.init)
        let found = DictionaryService.shared.lookup(word) != nil
        LookupCoordinator.lookup(word, entryPoint: "debug")
        PanelController.shared.snapshot(to: "/tmp/worrd-panel.png", delay: customDelay ?? (found ? 0.8 : 7.0))
    }

    /// `worrd://view/wordbook` opens the wordbook window instead of looking up a word.
    static func isWordbookURL(_ url: URL) -> Bool {
        url.host?.lowercased() == "view" && url.path.lowercased().contains("wordbook")
    }

    /// Accepts `worrd://theme`, `worrd://lookup?q=theme` and `worrd:///theme`.
    static func word(from url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        if let query = components.queryItems?.first(where: { $0.name == "q" || $0.name == "word" })?.value,
           !query.isEmpty {
            return query
        }
        if let host = components.host, !host.isEmpty, host.lowercased() != "lookup" {
            return host.removingPercentEncoding ?? host
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.removingPercentEncoding ?? path
    }

    private func lookup(_ raw: String, entryPoint: String) {
        LookupCoordinator.lookup(raw, entryPoint: entryPoint)
    }

    // MARK: - Services

    @objc
    func lookUpWord(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string) else {
            print("[Worrd] service: no text on pasteboard")
            return
        }
        print("[Worrd] service: \(text)")
        NSLog("[Worrd] service: %@", text)
        lookup(text, entryPoint: "service")
    }
}
