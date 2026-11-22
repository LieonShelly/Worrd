import AppKit
import SwiftUI

@MainActor
final class WordbookModel: ObservableObject {
    @Published var rows: [WordRow] = []
    @Published var selectedID: Int64?
    @Published var noteDraft: String = ""

    var selectedRow: WordRow? {
        rows.first { $0.id == selectedID }
    }

    func reload() {
        rows = WordbookStore.shared.allWords()
        if selectedID == nil || !rows.contains(where: { $0.id == selectedID }) {
            selectedID = rows.first?.id
        }
        noteDraft = selectedRow?.note ?? ""
        print("[Worrd] wordbook reload: \(rows.count) words")
    }

    func select(_ row: WordRow) {
        selectedID = row.id
        noteDraft = row.note
    }

    func updateNote(_ text: String) {
        guard let id = selectedID else { return }
        WordbookStore.shared.updateNote(id, note: text)
    }

    func deleteSelected() {
        guard let row = selectedRow else { return }
        WordbookStore.shared.delete(row.id)
        selectedID = nil
        reload()
    }

    func delete(_ row: WordRow) {
        WordbookStore.shared.delete(row.id)
        if selectedID == row.id { selectedID = nil }
        reload()
    }
}

@MainActor
final class WordbookWindowController {
    static let shared = WordbookWindowController()

    let model = WordbookModel()
    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        model.reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("[Worrd] wordbook window visible=\(window.isVisible) rows=\(model.rows.count)")
    }

    /// Debug helper: render the wordbook window to a PNG.
    func snapshot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard let view = self.window?.contentView, view.bounds.width > 0 else { return }
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
            print("[Worrd] wordbook snapshot: \(path) \(Int(bounds.width))x\(Int(bounds.height))")
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "单词本"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: WordbookView(model: model))
        return window
    }
}

struct WordbookView: View {
    @ObservedObject var model: WordbookModel
    @State private var query = ""

    private var filtered: [WordRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.rows }
        return model.rows.filter {
            $0.headword.lowercased().contains(q)
                || $0.body.lowercased().contains(q)
                || $0.phonetic.lowercased().contains(q)
                || $0.note.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                listPane
                    .frame(minWidth: 330, idealWidth: 370, maxWidth: 460)
                Divider().opacity(0.5)
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.surface)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("单词本")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                Text("\(model.rows.count) 个词")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("搜索单词、释义或笔记", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }
            .padding(.horizontal, 9)
            .frame(width: 250, height: 27)
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surface2))

            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surface2))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 13)
    }

    // MARK: List

    private var listPane: some View {
        Group {
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text(model.rows.isEmpty ? "还没有单词" : "没有匹配的词")
                        .font(.system(size: 13.5, weight: .medium))
                    Text(model.rows.isEmpty
                         ? "⌘Space 输入 worrd://单词，回车即查"
                         : "换个关键词试试")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { row in
                            rowView(row)
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
        .background(Palette.surface)
    }

    private func rowView(_ row: WordRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.headword)
                        .font(.system(size: 14.5, weight: .semibold, design: .serif))
                    if row.source == "ai" {
                        Text("AI")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Palette.amber)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Palette.amberSoft))
                    }
                    if !row.phonetic.isEmpty {
                        Text(Phonetics(row.phonetic).uk ?? row.phonetic)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(row.gloss)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                if row.count > 1 {
                    Text("×\(row.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(row.lastLooked, format: .relative(presentation: .named))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(model.selectedID == row.id ? Palette.accentSoft : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.select(row) }
        .contextMenu {
            Button("复制释义") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.headword + "\n" + row.body, forType: .string)
            }
            Divider()
            Button("删除", role: .destructive) { model.delete(row) }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detailPane: some View {
        if let row = model.selectedRow {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.headword)
                            .font(.system(size: 27, weight: .semibold, design: .serif))
                            .tracking(-0.3)
                        if row.source == "ai" {
                            Text("AI 生成")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.amber)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Palette.amberSoft))
                        }
                        Spacer(minLength: 8)
                        Button {
                            model.deleteSelected()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                    }

                    HStack(spacing: 8) {
                        if !row.phonetic.isEmpty {
                            let p = Phonetics(row.phonetic)
                            Text([p.uk, p.us].compactMap { $0 }.joined(separator: "  ·  "))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("查过 \(row.count) 次")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                        Text(row.lastLooked, format: .relative(presentation: .named))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }

                    Divider().opacity(0.5)

                    DefinitionView(text: row.body)
                        .textSelection(.enabled)

                    Divider().opacity(0.5).padding(.top, 6)

                    Text("我的笔记")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .kerning(0.6)

                    ZStack(alignment: .topLeading) {
                        if model.noteDraft.isEmpty {
                            Text("写点什么，比如这个词出现的场景…")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: Binding(
                            get: { model.noteDraft },
                            set: { value in
                                model.noteDraft = value
                                model.updateNote(value)
                            }
                        ))
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                    }
                    .frame(minHeight: 84, maxHeight: 140)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline, lineWidth: 0.5))
                }
                .padding(22)
            }
        } else {
            VStack(spacing: 6) {
                Text("选一个词看详情")
                    .font(.system(size: 13, weight: .medium))
                Text("释义、查询次数和笔记都在这里")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
