import AppKit
import Foundation

enum SchemeAliasError: LocalizedError {
    case invalid
    case reserved
    case tool(String)

    var errorDescription: String? {
        switch self {
        case .invalid:
            return "前缀只能用 2–32 个小写字母、数字、- 或 .，且必须以字母开头"
        case .reserved:
            return "这个前缀被系统或其他应用占用，换一个试试"
        case .tool(let message):
            return message
        }
    }
}

/// macOS only lets an app claim URL schemes that are declared in its Info.plist.
/// Instead of rewriting (and re-signing) the main app, each custom prefix gets a tiny
/// AppleScript forwarder app that claims the scheme and rewrites it to `worrd://`.
@MainActor
final class SchemeAliasManager {
    static let shared = SchemeAliasManager()

    private let fm = FileManager.default
    private let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

    private var aliasesRoot: URL {
        fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("WorrdAliases", isDirectory: true)
    }

    func appURL(for scheme: String) -> URL {
        aliasesRoot.appendingPathComponent("\(scheme).app", isDirectory: true)
    }

    func installed() -> [String] {
        guard let items = try? fm.contentsOfDirectory(at: aliasesRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        return items
            .filter { $0.pathExtension == "app" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    // MARK: - Install / remove

    func install(_ raw: String) throws {
        let scheme = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try validate(scheme)

        try fm.createDirectory(at: aliasesRoot, withIntermediateDirectories: true)
        let app = appURL(for: scheme)
        if fm.fileExists(atPath: app.path) {
            unregister(app)
            try? fm.removeItem(at: app)
        }

        let scriptURL = fm.temporaryDirectory.appendingPathComponent("worrd-alias-\(scheme).applescript")
        try appleScript(for: scheme).write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: scriptURL) }

        try run("/usr/bin/osacompile", ["-o", app.path, scriptURL.path])
        try patchInfoPlist(app: app, scheme: scheme)
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        try run(lsregister, ["-f", app.path])

        print("[Worrd] alias installed: \(scheme):// -> \(app.path)")
    }

    func remove(_ scheme: String) throws {
        let app = appURL(for: scheme)
        unregister(app)
        if fm.fileExists(atPath: app.path) {
            try fm.removeItem(at: app)
        }
        print("[Worrd] alias removed: \(scheme)")
    }

    // MARK: - Validation

    private func validate(_ scheme: String) throws {
        let pattern = #"^[a-z][a-z0-9+.-]{1,31}$"#
        guard scheme.range(of: pattern, options: .regularExpression) != nil else {
            throw SchemeAliasError.invalid
        }
        let reserved: Set<String> = [
            "http", "https", "file", "ftp", "ftps", "mailto", "tel", "sms", "ssh", "sftp",
            "ws", "wss", "data", "javascript", "about", "blob", "chrome", "safari",
            "x-apple", "com-apple", "worrd", "dict", "feed", "itms", "itms-apps", "facetime",
        ]
        guard !reserved.contains(scheme) else { throw SchemeAliasError.reserved }
    }

    // MARK: - Forwarder app

    private func appleScript(for scheme: String) -> String {
        """
        on open location theURL
            set oldScheme to "\(scheme)://"
            if theURL starts with oldScheme then
                set newURL to "worrd://" & (text ((length of oldScheme) + 1) thru -1 of theURL)
            else
                set newURL to theURL
            end if
            do shell script "/usr/bin/open " & quoted form of newURL
            quit
        end open location

        on run
            quit
        end run
        """
    }

    private func patchInfoPlist(app: URL, scheme: String) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard var info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw SchemeAliasError.tool("无法读取转发器 Info.plist")
        }

        let safeScheme = scheme.replacingOccurrences(of: "+", with: "-")
        info["CFBundleIdentifier"] = "com.renjun.worrd.alias.\(safeScheme)"
        info["CFBundleName"] = "Worrd \(scheme)"
        info["LSUIElement"] = true
        info["OSAAppletShowStartupScreen"] = false
        info["CFBundleURLTypes"] = [[
            "CFBundleURLName": "com.renjun.worrd.alias.\(safeScheme)",
            "CFBundleTypeRole": "Viewer",
            "CFBundleURLSchemes": [scheme],
        ]]

        let output = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try output.write(to: plistURL, options: .atomic)
    }

    private func unregister(_ app: URL) {
        guard fm.fileExists(atPath: app.path) else { return }
        try? run(lsregister, ["-u", app.path])
    }

    // MARK: - Process

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = outputPipe

        try process.run()
        process.waitUntilExit()

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8) ?? ""
        let outputText = String(data: outputData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = errorText.isEmpty ? outputText : errorText
            throw SchemeAliasError.tool(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return outputText
    }
}
