import AppKit
import AVFoundation
import SwiftUI

// MARK: - Model

@MainActor
final class LookupModel: ObservableObject {
    @Published var result: LookupResult?
    @Published var record: RecordInfo?
    @Published var failure: String?
    @Published var failureWord: String?
    @Published var aiText: String?
    @Published var aiLoading = false
    @Published var aiLookupLoading = false
    @Published var panelHeight: CGFloat = 460
}

// MARK: - Panel

final class LookupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

// MARK: - Coordinator

@MainActor
enum LookupCoordinator {
    static func lookup(_ raw: String, entryPoint: String) {
        let word = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !word.isEmpty else { return }

        if let result = DictionaryService.shared.lookup(word) {
            PanelController.shared.show(result, entryPoint: entryPoint)
        } else if ConfigStore.shared.config.ai.isUsable {
            PanelController.shared.showAIFallback(word, entryPoint: entryPoint)
        } else {
            PanelController.shared.showFailure(word)
        }
    }
}

// MARK: - Controller

@MainActor
final class PanelController {
    static let shared = PanelController()

    let model = LookupModel()
    private var panel: LookupPanel?

    func show(_ result: LookupResult, entryPoint: String) {
        AIProvider.shared.cancelLookup()
        model.result = result
        model.failure = nil
        model.failureWord = nil
        model.record = WordbookStore.shared.record(result, entryPoint: entryPoint)
        model.aiText = nil
        model.aiLookupLoading = false
        model.aiLoading = ConfigStore.shared.config.ai.isUsable && result.source != "ai"
        model.panelHeight = estimatedHeight(for: result, reserveAI: model.aiLoading, aiText: nil)

        present()

        if model.aiLoading {
            AIProvider.shared.enrich(result) { [weak self] text in
                guard let self else { return }
                self.model.aiLoading = false
                self.model.aiText = text
                self.model.panelHeight = self.estimatedHeight(for: result, reserveAI: false, aiText: text)
                self.resizePanel()
            } onFailure: { [weak self] in
                guard let self else { return }
                self.model.aiLoading = false
                self.model.panelHeight = self.estimatedHeight(for: result, reserveAI: false, aiText: nil)
                self.resizePanel()
            }
        } else {
            AIProvider.shared.cancel()
        }
    }

    func showAIFallback(_ word: String, entryPoint: String) {
        AIProvider.shared.cancel()
        model.result = nil
        model.record = nil
        model.failure = nil
        model.failureWord = word
        model.aiText = nil
        model.aiLoading = false
        model.aiLookupLoading = true
        model.panelHeight = 330
        present()

        AIProvider.shared.lookupDefinition(word) { [weak self] result in
            guard let self else { return }
            self.model.aiLookupLoading = false
            self.model.result = result
            self.model.failureWord = nil
            self.model.record = WordbookStore.shared.record(result, entryPoint: entryPoint)
            self.model.panelHeight = self.estimatedHeight(for: result, reserveAI: false, aiText: nil)
            self.resizePanel()
        } onFailure: { [weak self] in
            guard let self else { return }
            self.model.aiLookupLoading = false
            self.model.failure = "牛津词典和 AI 都没有查出来"
            self.model.failureWord = word
            self.model.panelHeight = 360
            self.resizePanel()
        }
    }

    func showFailure(_ word: String) {
        AIProvider.shared.cancel()
        AIProvider.shared.cancelLookup()
        model.result = nil
        model.record = nil
        model.aiText = nil
        model.aiLoading = false
        model.aiLookupLoading = false
        model.failure = "牛津词典未收录"
        model.failureWord = word
        model.panelHeight = 360
        present()
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Debug helper: render the panel content to a PNG so the UI can be inspected headlessly.
    func snapshot(to path: String, delay: Double = 0.8) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let view = self.panel?.contentView, view.bounds.width > 0 else { return }
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            view.cacheDisplay(in: bounds, to: rep)

            let image = NSImage(size: bounds.size)
            image.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: bounds.size)).fill()
            rep.draw(in: NSRect(origin: .zero, size: bounds.size))
            image.unlockFocus()

            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: path))
            print("[Worrd] snapshot: \(path) \(Int(bounds.width))x\(Int(bounds.height))")
        }
    }

    private func present() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setContentSize(NSSize(width: 540, height: model.panelHeight))
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resizePanel() {
        guard let panel, panel.isVisible else { return }
        panel.setContentSize(NSSize(width: 540, height: model.panelHeight))
        position(panel)
    }

    private func makePanel() -> LookupPanel {
        let panel = LookupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: LookupView(model: model))
        panel.contentView = host
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + 40
        )
        panel.setFrameOrigin(origin)
    }

    /// Rough height estimate so the popover hugs short entries instead of leaving dead space.
    private func estimatedHeight(for result: LookupResult, reserveAI: Bool, aiText: String?) -> CGFloat {
        var height: CGFloat = 140
        for raw in result.body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let units = line.unicodeScalars.reduce(0.0) { total, scalar in
                total + ((0x4E00...0x9FFF).contains(scalar.value) ? 2.1 : 1.0)
            }
            let rows = max(1, Int(ceil(units / 58.0)))
            if line.hasPrefix("▸") {
                height += 8 + CGFloat(rows) * 16
            } else if DefBlock.tags.contains(line) {
                height += 28
            } else if let first = line.first, "①②③④⑤⑥⑦⑧⑨⑩".contains(first) {
                height += 12 + CGFloat(rows) * 20
            } else {
                height += 10 + CGFloat(rows) * 18
            }
        }
        if let aiText {
            let lines = max(1, aiText.components(separatedBy: .newlines).count)
            height += 52 + CGFloat(lines) * 17
        } else if reserveAI {
            height += 78
        }
        return min(max(height, 330), 660)
    }
}

// MARK: - Speech

final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, chinese: Bool) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: chinese ? "zh-CN" : "en-US")
        utterance.rate = 0.45
        synthesizer.speak(utterance)
    }
}

// MARK: - View

struct LookupView: View {
    @ObservedObject var model: LookupModel
    @State private var speaker = Speaker()

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            content
            hairline
            footer
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.hairline, lineWidth: 0.5)
        )
        .frame(width: 540, height: model.panelHeight)
    }

    private var hairline: some View {
        Rectangle().fill(Palette.hairline).frame(height: 0.5)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.result?.headword ?? model.failureWord ?? "—")
                    .font(.system(size: 31, weight: .semibold, design: .serif))
                    .tracking(-0.4)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let result = model.result {
                    phoneticRow(result)
                } else if model.aiLookupLoading {
                    Text("正在用 AI 查询…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if let result = model.result {
                    badge(text: result.source == "ai" ? "AI 释义" : "已收录",
                          color: result.source == "ai" ? Palette.amber : Palette.accent,
                          background: result.source == "ai" ? Palette.amberSoft : Palette.accentSoft)
                }
                Button {
                    PanelController.shared.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Palette.surface2))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private func badge(text: String, color: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(background))
            .overlay(Capsule().stroke(color.opacity(0.18), lineWidth: 0.5))
    }

    @ViewBuilder
    private func phoneticRow(_ result: LookupResult) -> some View {
        let parsed = Phonetics(result.phonetic)
        HStack(spacing: 6) {
            if result.isChinese {
                if !result.phonetic.isEmpty {
                    Text(result.phonetic)
                        .font(.system(size: 13, design: .serif))
                        .foregroundStyle(Palette.secondary)
                }
            } else {
                if let uk = parsed.uk {
                    tag("英")
                    Text(uk).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.secondary)
                }
                if let us = parsed.us {
                    tag("美")
                    Text(us).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.secondary)
                }
                if parsed.uk == nil, !result.phonetic.isEmpty {
                    Text(result.phonetic)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                }
            }

            Button {
                speaker.speak(result.headword.isEmpty ? result.query : result.headword,
                              chinese: result.isChinese)
            } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Palette.hairline, lineWidth: 0.5)
            )
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let result = model.result {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DefinitionView(text: result.body)
                        .textSelection(.enabled)
                    sourceLine(result)
                    aiSection
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if model.aiLookupLoading {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("牛津词典未收录")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.text)
                Text("正在请 AI 生成释义…")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(Palette.muted)
                Text(model.failure ?? "牛津词典未收录")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.text)
                Text(ConfigStore.shared.config.ai.isUsable
                     ? "换个拼写试试，或者稍后再查"
                     : "在设置里填入 AI Key，可以让 AI 兜底查询")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sourceLine(_ result: LookupResult) -> some View {
        HStack {
            Spacer()
            Text(result.source == "ai" ? "AI 生成 · 仅供参考" : "牛津英汉汉英词典")
                .font(.system(size: 10))
                .foregroundStyle(result.source == "ai" ? Palette.amber : Palette.muted)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var aiSection: some View {
        if model.aiLoading || model.aiText != nil {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("AI 补注")
                        .font(.system(size: 9.5, weight: .semibold))
                        .kerning(0.7)
                    Spacer()
                    Text(ConfigStore.shared.config.ai.model)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                }
                .foregroundStyle(Palette.accent)

                if let text = model.aiText {
                    Text(text)
                        .font(.system(size: 12))
                        .lineSpacing(3.5)
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在补充…")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.accentSoft))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Palette.accent.opacity(0.13), lineWidth: 0.5)
            )
            .padding(.top, 16)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let record = model.record {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.accent)
                Text(record.summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            } else {
                Text("未加入单词本")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            Text("esc 关闭")
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Palette.surface2.opacity(0.55))
    }
}

// MARK: - Phonetics

struct Phonetics {
    let uk: String?
    let us: String?

    init(_ raw: String) {
        guard !raw.isEmpty else {
            uk = nil
            us = nil
            return
        }
        let pattern = #"BrE\s+(.+?),\s*AmE\s+(.+)$"#
        if let range = raw.range(of: pattern, options: .regularExpression) {
            let matched = String(raw[range])
            let parts = matched.components(separatedBy: ", AmE ")
            if parts.count == 2 {
                uk = parts[0].replacingOccurrences(of: "BrE ", with: "")
                us = parts[1]
                return
            }
        }
        if let range = raw.range(of: #"BrE\s+(.+)$"#, options: .regularExpression) {
            uk = String(raw[range]).replacingOccurrences(of: "BrE ", with: "")
            us = nil
            return
        }
        uk = nil
        us = nil
    }
}

// MARK: - Definition rendering

struct DefBlock: Identifiable {
    enum Kind { case pos, sense, example, plain }

    let id: Int
    let kind: Kind
    let marker: String
    let label: String?
    let text: String

    static let tags: Set<String> = [
        "n.", "v.", "adj.", "adv.", "prep.", "pron.", "conj.", "interj.", "det.",
        "名", "动", "形", "副", "介", "代", "连", "叹", "量", "数",
    ]

    static func parse(_ body: String) -> [DefBlock] {
        var blocks: [DefBlock] = []
        for (index, raw) in body.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if let first = line.first, "①②③④⑤⑥⑦⑧⑨⑩".contains(first) {
                var rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                var label: String?
                if rest.hasPrefix("("), let end = rest.firstIndex(of: ")") {
                    label = String(rest[rest.index(after: rest.startIndex)..<end])
                    rest = String(rest[rest.index(after: end)...]).trimmingCharacters(in: .whitespaces)
                }
                blocks.append(DefBlock(id: index, kind: .sense, marker: String(first), label: label, text: rest))
                continue
            }

            if line.hasPrefix("▸") {
                let rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                blocks.append(DefBlock(id: index, kind: .example, marker: "", label: nil, text: rest))
                continue
            }

            if tags.contains(line) {
                blocks.append(DefBlock(id: index, kind: .pos, marker: "", label: nil, text: line))
                continue
            }

            blocks.append(DefBlock(id: index, kind: .plain, marker: "", label: nil, text: line))
        }
        return blocks
    }
}

struct DefGroup: Identifiable {
    let id: Int
    let pos: String?
    let blocks: [DefBlock]

    static func parse(_ body: String) -> [DefGroup] {
        let blocks = DefBlock.parse(body)
        var groups: [DefGroup] = []
        var currentBlocks: [DefBlock] = []
        var currentPos: String?
        var nextID = 0

        func flush() {
            guard !currentBlocks.isEmpty else { return }
            groups.append(DefGroup(id: nextID, pos: currentPos, blocks: currentBlocks))
            nextID += 1
            currentBlocks = []
        }

        for block in blocks {
            if block.kind == .pos {
                flush()
                currentPos = block.text
            } else {
                currentBlocks.append(block)
            }
        }
        flush()
        return groups
    }
}

struct DefinitionView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(DefGroup.parse(text)) { group in
                HStack(alignment: .top, spacing: 8) {
                    Text(group.pos ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 26, alignment: .leading)
                        .padding(.top, 3)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.blocks) { block in
                            row(block)
                        }
                    }
                }
                .padding(.bottom, 13)
            }
        }
    }

    @ViewBuilder
    private func row(_ block: DefBlock) -> some View {
        switch block.kind {
        case .pos:
            EmptyView()

        case .sense:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(block.marker)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 12, alignment: .leading)
                senseText(block)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.text)
                    .lineSpacing(2)
            }
            .padding(.bottom, 7)

        case .example:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("▸")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.muted)
                Text(block.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.secondary)
                    .lineSpacing(2)
            }
            .padding(.leading, 18)
            .padding(.bottom, 3)

        case .plain:
            Text(block.text)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.text)
                .lineSpacing(2)
                .padding(.bottom, 6)
        }
    }

    private func senseText(_ block: DefBlock) -> Text {
        if let label = block.label {
            return Text("(\(label)) ").foregroundColor(Palette.muted) + Text(block.text)
        }
        return Text(block.text)
    }
}
