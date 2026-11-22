import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Debug helper: render the settings window to a PNG.
    func snapshot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard let view = self.window?.contentView, view.bounds.width > 0 else { return }
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            view.cacheDisplay(in: bounds, to: rep)
            let image = NSImage(size: bounds.size)
            image.lockFocus()
            Palette.surfaceNSColor.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: bounds.size)).fill()
            rep.draw(in: NSRect(origin: .zero, size: bounds.size))
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: path))
            print("[Worrd] settings snapshot: \(path) \(Int(bounds.width))x\(Int(bounds.height))")
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Worrd 设置"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView())
        return window
    }
}

struct SettingsView: View {
    @State private var enabled = ConfigStore.shared.config.ai.enabled
    @State private var baseURL = ConfigStore.shared.config.ai.baseURL
    @State private var model = ConfigStore.shared.config.ai.model
    @State private var apiKey = ConfigStore.shared.config.ai.apiKey
    @State private var status = ""
    @State private var aliases: [String] = []
    @State private var newScheme = ""
    @State private var schemeStatus = ""
    @State private var schemeError = false

    private var dictionary: DictionaryService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设置")
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 14)

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    schemeSection
                    aiSection
                    dictionarySection
                    dataSection
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }

            Divider().opacity(0.5)

            HStack {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("保存") {
                    var ai = ConfigStore.shared.config.ai
                    ai.enabled = enabled
                    ai.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
                    ai.model = model.trimmingCharacters(in: .whitespaces)
                    ai.apiKey = apiKey.trimmingCharacters(in: .whitespaces)
                    ConfigStore.shared.updateAI(ai)
                    status = ai.isUsable ? "已保存，下次查词生效" : "已保存（配置不完整，AI 暂不启用）"
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(width: 580, height: 660)
        .background(Palette.surface)
        .onAppear {
            aliases = SchemeAliasManager.shared.installed()
        }
    }

    // MARK: URL schemes

    private var schemeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("URL 前缀")

            HStack(spacing: 8) {
                Text("主前缀")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                Text("worrd://")
                    .font(.system(size: 12, design: .monospaced))
                Spacer()
                Text("固定")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                Text("添加")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                TextField("newworrd", text: $newScheme)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 170)
                    .onSubmit { addAlias() }
                Button("添加") { addAlias() }
                Spacer()
            }

            if !aliases.isEmpty {
                HStack(alignment: .center, spacing: 6) {
                    Text("已添加")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .leading)
                    ForEach(aliases, id: \.self) { scheme in
                        HStack(spacing: 4) {
                            Text("\(scheme)://")
                                .font(.system(size: 10.5, design: .monospaced))
                            Button {
                                removeAlias(scheme)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.surface2))
                        .overlay(Capsule().stroke(Palette.hairline, lineWidth: 0.5))
                    }
                    Spacer()
                }
            }

            Text("macOS 只认 Info.plist 里声明过的前缀，所以每个自定义前缀会生成一个极小的转发 App（存放在 ~/Applications/WorrdAliases），把 \(newScheme.isEmpty ? "newworrd" : newScheme.lowercased())://theme 转给 worrd://theme。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !schemeStatus.isEmpty {
                Text(schemeStatus)
                    .font(.system(size: 10.5))
                    .foregroundStyle(schemeError ? Color.red : Palette.secondary)
            }
        }
    }

    private func addAlias() {
        let candidate = newScheme
        guard !candidate.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try SchemeAliasManager.shared.install(candidate)
            aliases = SchemeAliasManager.shared.installed()
            schemeStatus = "已添加 \(candidate.lowercased())://，现在就可以用"
            schemeError = false
            newScheme = ""
        } catch {
            schemeStatus = error.localizedDescription
            schemeError = true
        }
    }

    private func removeAlias(_ scheme: String) {
        do {
            try SchemeAliasManager.shared.remove(scheme)
            aliases = SchemeAliasManager.shared.installed()
            schemeStatus = "已移除 \(scheme)://"
            schemeError = false
        } catch {
            schemeStatus = error.localizedDescription
            schemeError = true
        }
    }

    // MARK: AI

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("AI 补注")

            Toggle("在词典释义下方追加辨析、搭配与例句", isOn: $enabled)
                .toggleStyle(.switch)
                .font(.system(size: 12.5))

            field("接口地址", text: $baseURL, placeholder: "https://api.deepseek.com/v1")
            field("模型", text: $model, placeholder: "deepseek-chat")

            VStack(alignment: .leading, spacing: 5) {
                Text("API Key")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            Text("Key 保存在 \(ConfigStore.shared.fileURL.path)（权限 600），不会上传到别处。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    // MARK: Dictionary

    private var dictionarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("词典")
            HStack(spacing: 6) {
                Circle()
                    .fill(dictionary.dictionaryName.isEmpty ? Color.orange : Color(red: 0.18, green: 0.42, blue: 0.31))
                    .frame(width: 6, height: 6)
                Text(dictionary.dictionaryName.isEmpty ? "未找到词典" : dictionary.dictionaryName)
                    .font(.system(size: 12.5))
                Text("· 双向查询")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(dictionary.dictionaryPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    // MARK: Data

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("数据")
            HStack {
                Text("单词本数据库")
                    .font(.system(size: 12.5))
                Spacer()
                Button("打开单词本") {
                    WordbookWindowController.shared.show()
                }
                .font(.system(size: 11.5))
            }
            Text("~/Library/Application Support/Worrd/wordbook.sqlite")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.6)
    }
}
