import Foundation

enum AIError: Error, LocalizedError {
    case badURL
    case badStatus(Int)
    case badPayload

    var errorDescription: String? {
        switch self {
        case .badURL: return "接口地址不合法"
        case .badStatus(let code): return "接口返回 \(code)"
        case .badPayload: return "返回内容无法解析"
        }
    }
}

@MainActor
final class AIProvider {
    static let shared = AIProvider()

    private var enrichTask: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?

    func cancel() {
        enrichTask?.cancel()
        enrichTask = nil
    }

    func cancelLookup() {
        lookupTask?.cancel()
        lookupTask = nil
    }

    // MARK: - Enrichment (dictionary hit)

    func enrich(
        _ result: LookupResult,
        onSuccess: @escaping (String) -> Void,
        onFailure: @escaping () -> Void
    ) {
        let config = ConfigStore.shared.config.ai
        guard config.isUsable else {
            onFailure()
            return
        }

        cancel()
        let prompt = Self.enrichPrompt(for: result)
        enrichTask = Task { [weak self] in
            do {
                let text = try await Self.chat(
                    system: "你是一位严谨的中文词典编辑，回答简洁、准确，不编造。",
                    prompt: prompt,
                    config: config,
                    temperature: 0.3
                )
                guard !Task.isCancelled else { return }
                self?.enrichTask = nil
                if text.isEmpty { onFailure() } else { onSuccess(text) }
            } catch {
                guard !Task.isCancelled else { return }
                self?.enrichTask = nil
                print("[Worrd] ai enrich error: \(error.localizedDescription)")
                onFailure()
            }
        }
    }

    // MARK: - Fallback lookup (dictionary miss)

    func lookupDefinition(
        _ word: String,
        onSuccess: @escaping (LookupResult) -> Void,
        onFailure: @escaping () -> Void
    ) {
        let config = ConfigStore.shared.config.ai
        guard config.isUsable else {
            onFailure()
            return
        }

        cancelLookup()
        let prompt = Self.definitionPrompt(word)
        lookupTask = Task { [weak self] in
            do {
                let text = try await Self.chat(
                    system: "你是一位严谨的词典编辑，只按用户要求的行格式输出，不添加解释或 Markdown。",
                    prompt: prompt,
                    config: config,
                    temperature: 0.2
                )
                guard !Task.isCancelled else { return }
                self?.lookupTask = nil
                if let result = Self.parseDefinition(text, word: word) {
                    onSuccess(result)
                } else {
                    onFailure()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.lookupTask = nil
                print("[Worrd] ai lookup error: \(error.localizedDescription)")
                onFailure()
            }
        }
    }

    // MARK: - Prompts

    private static func enrichPrompt(for result: LookupResult) -> String {
        let definition = String(result.body.replacingOccurrences(of: "\n", with: " ").prefix(240))
        if result.isChinese {
            return """
            中文词条：\(result.headword)
            词典释义：\(definition)

            请按下面三行输出，不要寒暄，不要 Markdown：
            【对应】最常用的英文说法
            【辨析】使用场景或语域上的一句话提醒
            【例句】一条英文例句 + 中文翻译
            总长不超过 120 字。
            """
        }
        return """
        英文单词：\(result.headword)
        词典释义：\(definition)

        请按下面三行输出，不要寒暄，不要 Markdown：
        【辨析】与近义词的区别，一句话
        【搭配】3 个高频搭配，用 · 分隔
        【例句】一条英文例句 + 中文翻译
        总长不超过 120 字。
        """
    }

    private static func definitionPrompt(_ word: String) -> String {
        let isChinese = word.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        if isChinese {
            return """
            请为中文词「\(word)」编写词条，严格按下面格式逐行输出，不要输出解释、不要 Markdown：

            HEADWORD: \(word)
            PHONETIC: 拼音
            POS: 名
            SENSE: 英文对应词；简短中文说明
            EXAMPLE: 英文例句 —— 中文翻译

            规则：可以有多个 POS 段（名/动/形/副…），每段 1-3 条 SENSE，每条 SENSE 后跟 0-2 条 EXAMPLE。
            如果这个词有多个常用英文对应，写在同一条 SENSE 里用分号隔开。
            """
        }
        return """
        请为英文单词「\(word)」编写词条，严格按下面格式逐行输出，不要输出解释、不要 Markdown：

        HEADWORD: 词的原形
        PHONETIC: 英式音标
        POS: n.
        SENSE: 中文释义（可附英文原词）
        EXAMPLE: 英文例句 —— 中文翻译

        规则：可以有多个 POS 段（n./v./adj./adv. 等），每段 1-3 条 SENSE，每条 SENSE 后跟 0-2 条 EXAMPLE。
        """
    }

    // MARK: - Parsing AI definitions

    static func parseDefinition(_ raw: String, word: String) -> LookupResult? {
        var headword = word
        var phonetic = ""

        struct Group {
            var pos: String
            var senses: [(text: String, examples: [String])]
        }
        var groups: [Group] = []
        var currentGroup: Int?
        var currentSense: (text: String, examples: [String])?

        func flushSense() {
            if let sense = currentSense, let index = currentGroup {
                groups[index].senses.append(sense)
            }
            currentSense = nil
        }

        for rawLine in raw.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            line = line.replacingOccurrences(of: "**", with: "")
            while let first = line.first, "-*•`>#".contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }

            let upper = line.uppercased()
            if upper.hasPrefix("HEADWORD:") {
                flushSense()
                headword = value(line, after: "HEADWORD:")
                continue
            }
            if upper.hasPrefix("PHONETIC:") {
                phonetic = value(line, after: "PHONETIC:")
                continue
            }
            if upper.hasPrefix("POS:") {
                flushSense()
                groups.append(Group(pos: value(line, after: "POS:"), senses: []))
                currentGroup = groups.count - 1
                continue
            }
            if upper.hasPrefix("SENSE:") {
                flushSense()
                if currentGroup == nil {
                    groups.append(Group(pos: "", senses: []))
                    currentGroup = groups.count - 1
                }
                currentSense = (value(line, after: "SENSE:"), [])
                continue
            }
            if upper.hasPrefix("EXAMPLE:") {
                let example = value(line, after: "EXAMPLE:")
                if currentSense != nil, !example.isEmpty {
                    currentSense?.examples.append(example)
                }
                continue
            }

            // Unlabelled continuation line: append to the current sense.
            if var sense = currentSense {
                sense.text += (sense.text.isEmpty ? "" : " ") + line
                currentSense = sense
            }
        }
        flushSense()

        guard groups.contains(where: { !$0.senses.isEmpty }) else { return nil }

        var body = ""
        var senseIndex = 0
        let markers = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩"]
        for group in groups {
            if !group.pos.isEmpty { body += group.pos + "\n" }
            for sense in group.senses {
                let marker = senseIndex < markers.count ? markers[senseIndex] : "·"
                senseIndex += 1
                body += marker + " " + sense.text + "\n"
                for example in sense.examples {
                    body += "▸ " + example + "\n"
                }
            }
        }

        let isChinese = word.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        return LookupResult(
            query: word,
            headword: headword.isEmpty ? word : headword,
            phonetic: phonetic,
            body: body.trimmingCharacters(in: .newlines),
            isChinese: isChinese,
            source: "ai"
        )
    }

    private static func value(_ line: String, after prefix: String) -> String {
        guard let range = line.range(of: prefix, options: .caseInsensitive) else { return "" }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Request

    private static func chat(
        system: String,
        prompt: String,
        config: AIConfig,
        temperature: Double
    ) async throws -> String {
        var base = config.baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else {
            throw AIError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "model": config.model,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": prompt],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.badPayload }
        guard (200..<300).contains(http.statusCode) else { throw AIError.badStatus(http.statusCode) }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw AIError.badPayload
        }

        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```", with: "")
        }
        return text
    }
}
