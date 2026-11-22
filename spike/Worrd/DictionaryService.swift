import Foundation
import CoreServices

// MARK: - Private DictionaryServices API

@_silgen_name("DCSDictionaryCreate")
private func DCSDictionaryCreate(_ url: CFURL) -> DCSDictionary?

@_silgen_name("DCSDictionaryGetName")
private func DCSDictionaryGetName(_ dictionary: DCSDictionary) -> CFString?

@_silgen_name("DCSDictionaryGetShortName")
private func DCSDictionaryGetShortName(_ dictionary: DCSDictionary) -> CFString?

// MARK: - Model

struct LookupResult {
    var query: String
    var headword: String
    var phonetic: String
    var body: String
    var isChinese: Bool
    var source: String = "oxford"
}

// MARK: - Service

@MainActor
final class DictionaryService {
    static let shared = DictionaryService()

    private(set) var dictionaryName: String = ""
    private(set) var dictionaryPath: String = ""
    private var dictionary: DCSDictionary?

    private init() {
        locateDictionary()
    }

    // MARK: Lookup

    func lookup(_ raw: String) -> LookupResult? {
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }

        let nsTerm = term as NSString
        let range = CFRangeMake(0, nsTerm.length)

        var definition: String?
        if let dictionary {
            definition = DCSCopyTextDefinition(dictionary, term as CFString, range)?
                .takeRetainedValue() as String?
        }
        if definition == nil {
            definition = DCSCopyTextDefinition(nil, term as CFString, range)?
                .takeRetainedValue() as String?
        }
        guard let text = definition, !text.isEmpty else { return nil }

        return parse(term: term, raw: text)
    }

    // MARK: Parsing

    private func parse(term: String, raw: String) -> LookupResult {
        let parts = raw.components(separatedBy: " | ")
        var headword = term
        var phonetic = ""
        var body = raw

        if parts.count >= 3 {
            headword = parts[0]
            phonetic = parts[1]
            body = parts[2...].joined(separator: " | ")
        } else if parts.count == 2 {
            headword = parts[0]
            body = parts[1]
        }

        let isChinese = term.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)
        }

        if isChinese {
            let stripped = Self.stripChinesePrefix(body, term: term)
            phonetic = stripped.pinyin
            body = stripped.text
        }

        body = Self.prettify(body)

        return LookupResult(
            query: term,
            headword: headword,
            phonetic: phonetic,
            body: body,
            isChinese: isChinese
        )
    }

    private static let circled: [String] = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩", "⑪", "⑫"]

    private static let enPOS: [String: String] = [
        "noun": "n.",
        "plural noun": "n.",
        "proper noun": "n.",
        "verb": "v.",
        "transitive verb": "v.",
        "intransitive verb": "v.",
        "phrasal verb": "v.",
        "auxiliary verb": "v.",
        "modal verb": "v.",
        "adjective": "adj.",
        "adverb": "adv.",
        "preposition": "prep.",
        "pronoun": "pron.",
        "conjunction": "conj.",
        "interjection": "interj.",
        "determiner": "det.",
        "exclamation": "interj.",
    ]

    private static let zhPOS: [String: String] = [
        "noun": "名",
        "verb": "动",
        "adjective": "形",
        "adverb": "副",
        "preposition": "介",
        "pronoun": "代",
        "conjunction": "连",
        "interjection": "叹",
        "classifier": "量",
        "numeral": "数",
    ]

    /// For Chinese entries the raw string starts with the headword, its pinyin and an English
    /// part-of-speech name. Drop the headword/pinyin (they are shown in the header) and turn the
    /// POS into a marker line.
    private static func stripChinesePrefix(_ raw: String, term: String) -> (pinyin: String, text: String) {
        var text = raw
        if text.hasPrefix(term) {
            text.removeFirst(term.count)
        }
        text = text.trimmingCharacters(in: .whitespaces)

        var pinyinTokens: [String] = []
        while pinyinTokens.count < 4,
              let token = text.split(separator: " ", maxSplits: 1).first.map(String.init),
              !token.isEmpty {
            if zhPOS[token.lowercased()] != nil { break }
            if token.range(of: "\\p{Han}", options: .regularExpression) != nil { break }
            pinyinTokens.append(token)
            text = String(text.dropFirst(token.count)).trimmingCharacters(in: .whitespaces)
        }

        let pinyin = pinyinTokens.joined(separator: " ")

        if let token = text.split(separator: " ", maxSplits: 1).first.map(String.init),
           let tag = zhPOS[token.lowercased()] {
            text = String(text.dropFirst(token.count)).trimmingCharacters(in: .whitespaces)
            return (pinyin, tag + "\n" + text)
        }
        return (pinyin, text)
    }

    private static func prettify(_ input: String) -> String {
        var text = input
        // Break before an inline part-of-speech group label such as "B. transitive verb".
        text = text.replacingOccurrences(
            of: #"\s+([A-Z])\.\s+(?=(?:noun|verb|adjective|adverb|preposition|pronoun|conjunction|interjection|exclamation|determiner|transitive verb|intransitive verb|plural noun|phrasal verb|auxiliary verb|modal verb)\b)"#,
            with: "\n$1. ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "▸", with: "\n▸ ")
        for mark in circled {
            text = text.replacingOccurrences(of: mark, with: "\n\(mark)")
        }
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        text = mapPOSLines(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turn lines like `A. noun` or `B. transitive verb 赋予…` into `n.` / `v.\n赋予…`.
    private static func mapPOSLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var output: [String] = []
        let phrases = enPOS.keys.sorted { $0.count > $1.count }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            // Bare POS, or POS followed by content on the same line.
            if let tag = enPOS[lower] {
                output.append(tag)
                continue
            }
            var bareMatched = false
            for phrase in phrases {
                guard let tag = enPOS[phrase], lower.hasPrefix(phrase + " ") else { continue }
                let rest = String(trimmed.dropFirst(phrase.count)).trimmingCharacters(in: .whitespaces)
                output.append(tag)
                if !rest.isEmpty { output.append(rest) }
                bareMatched = true
                break
            }
            if bareMatched { continue }

            // "A. noun" / "B. transitive verb 赋予…"
            guard trimmed.range(of: #"^[A-Z]\.\s"#, options: .regularExpression) != nil else {
                output.append(line)
                continue
            }

            let content = trimmed.replacingOccurrences(
                of: #"^[A-Z]\.\s*"#,
                with: "",
                options: .regularExpression
            )
            let key = content.lowercased()
            var replaced = false

            for phrase in phrases {
                guard let tag = enPOS[phrase] else { continue }
                if key == phrase {
                    output.append(tag)
                    replaced = true
                    break
                }
                if key.hasPrefix(phrase + " ") {
                    let rest = String(content.dropFirst(phrase.count)).trimmingCharacters(in: .whitespaces)
                    output.append(tag)
                    if !rest.isEmpty { output.append(rest) }
                    replaced = true
                    break
                }
            }

            if !replaced {
                output.append(line)
            }
        }

        return output.joined(separator: "\n")
    }

    // MARK: Dictionary discovery

    private func locateDictionary() {
        let urls = Self.candidateDictionaryURLs()
        var fallback: (DCSDictionary, URL)?

        for url in urls {
            guard let dict = DCSDictionaryCreate(url as CFURL) else { continue }
            let name = (DCSDictionaryGetName(dict) as String?) ?? ""
            let short = (DCSDictionaryGetShortName(dict) as String?) ?? ""

            if fallback == nil { fallback = (dict, url) }

            let matches = name.contains("牛津英汉汉英")
                || short.contains("Simplified Chinese - English")
            if matches {
                dictionary = dict
                dictionaryName = name
                dictionaryPath = url.path
                print("[Worrd] dictionary: \(name) @ \(url.path)")
                return
            }
        }

        if let (dict, url) = fallback {
            dictionary = dict
            dictionaryName = (DCSDictionaryGetName(dict) as String?) ?? "未命名词典"
            dictionaryPath = url.path
            print("[Worrd] fallback dictionary: \(dictionaryName) @ \(url.path)")
        } else {
            print("[Worrd] no dictionary found")
        }
    }

    private static func candidateDictionaryURLs() -> [URL] {
        let fm = FileManager.default
        var searchDirs: [URL] = []

        let assetRoot = URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_DictionaryServices_dictionary3macOS")
        if let entries = try? fm.contentsOfDirectory(at: assetRoot, includingPropertiesForKeys: nil) {
            for entry in entries {
                searchDirs.append(entry.appendingPathComponent("AssetData"))
            }
        }

        searchDirs.append(URL(fileURLWithPath: "/System/Library/Dictionaries"))
        searchDirs.append(URL(fileURLWithPath: "/Library/Dictionaries"))
        searchDirs.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Dictionaries"))

        var result: [URL] = []
        for dir in searchDirs {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            result.append(contentsOf: entries.filter { $0.pathExtension == "dictionary" })
        }
        return result
    }
}
