import Foundation

public enum TranslationTaskMode: String {
    case translate = "这里是我的翻译"
    case explain = "AI 深度解析"
    case summarize = "要点总结"
}

public final class LLMTranslationService {
    public static let shared = LLMTranslationService()

    private init() {}

    /// Detects if text contains predominantly Chinese characters
    public static func isPredominantlyChinese(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var hanCount = 0
        var alphaCount = 0
        for scalar in trimmed.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) {
                hanCount += 1
            } else if CharacterSet.letters.contains(scalar) {
                alphaCount += 1
            }
        }
        return hanCount > 0 && (hanCount * 2 >= alphaCount)
    }

    public static func detectSourceLangLabel(_ text: String) -> String {
        if isPredominantlyChinese(text) {
            return "自动检测 (中文)"
        }
        return "自动检测"
    }

    public static func defaultTargetLanguage(for text: String) -> String {
        return isPredominantlyChinese(text) ? "English" : "简体中文"
    }

    public static func languageCode(for label: String) -> String {
        switch label {
        case "English": return "en"
        case "简体中文": return "zh-CN"
        case "繁體中文": return "zh-TW"
        case "日本語": return "ja"
        case "한국어": return "ko"
        case "Français": return "fr"
        case "Deutsch": return "de"
        default: return "zh-CN"
        }
    }

    public static func isWordOrShortTerm(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 42 else { return false }
        if trimmed.contains("\n") { return false }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        return words.count <= 3
    }

    // MARK: - Main Translation / Explain / Summarize Stream

    public func streamTranslate(
        text: String,
        mode: TranslationTaskMode = .translate,
        sourceApp: String,
        baseURL: String,
        apiKey: String,
        model: String,
        targetLangLabel: String,
        domainHint: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws {
        let cleanBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let isLocal = cleanBase.contains("127.0.0.1") || cleanBase.contains("localhost")
        let hasKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Zero-config instant neural translation fallback when no API key is configured
        if !hasKey && !isLocal {
            let targetCode = Self.languageCode(for: targetLangLabel)
            let fastResult = try await translateViaZeroConfigGTX(text: text, targetCode: targetCode, mode: mode)
            onDelta(fastResult)
            return
        }

        let endpointString = cleanBase.hasSuffix("/chat/completions") ? cleanBase : "\(cleanBase)/chat/completions"
        guard let url = URL(string: endpointString) else {
            throw NSError(domain: "SnapLex", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 API 地址: \(endpointString)"])
        }

        let systemPrompt: String
        let userPrompt: String

        switch mode {
        case .translate:
            systemPrompt = """
            你是一个极度精准、自然的专业翻译引擎（熟悉领域：\(domainHint)）。
            请直接将用户提供的文本翻译为【\(targetLangLabel)】。
            严格要求：只输出纯粹的译文正文，不要包含任何解释、前缀、引号或寒暄（保持原文的箭头、符号和排版结构）。
            """
            userPrompt = text
        case .explain:
            systemPrompt = """
            你是一个计算机科学、AI 工程与通识领域的资深导师。请用简洁清晰的中文，解释用户划选的内容（术语含义、背景原理或潜台词），控制在 150 字以内。
            """
            userPrompt = "请解析以下内容（来自 \(sourceApp)）：\n\(text)"
        case .summarize:
            systemPrompt = """
            请用最简练的 1~3 条核心要点（Bullet points），总结用户划选的这段内容，直击结论，不要废话。
            """
            userPrompt = text
        }

        try await performSSEStream(
            url: url,
            apiKey: apiKey,
            model: model,
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            onDelta: onDelta
        )
    }

    // MARK: - Follow-up Question ("继续提问")

    public func streamFollowUp(
        originalText: String,
        currentTranslation: String,
        question: String,
        baseURL: String,
        apiKey: String,
        model: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws {
        let cleanBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let isLocal = cleanBase.contains("127.0.0.1") || cleanBase.contains("localhost")
        let hasKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !hasKey && !isLocal {
            // If user asks a follow-up without an LLM key, translate the follow-up or guide them
            let targetCode = Self.isPredominantlyChinese(question) ? "en" : "zh-CN"
            let reply = try await translateViaZeroConfigGTX(text: question, targetCode: targetCode, mode: .translate)
            onDelta("\(reply)\n\n（💡 提示：在设置中填入 DeepSeek / OpenAI API Key 后，「继续提问」可支持无限轮深度多轮问答与改写）")
            return
        }

        let endpointString = cleanBase.hasSuffix("/chat/completions") ? cleanBase : "\(cleanBase)/chat/completions"
        guard let url = URL(string: endpointString) else { return }

        let messages: [[String: String]] = [
            ["role": "system", "content": "你是一个专业、简洁的翻译与阅读助手。请基于原文与当前译文，直接回答用户的追问。"],
            ["role": "user", "content": "原文：\n\(originalText)\n\n当前译文：\n\(currentTranslation)\n\n我的追问：\(question)"]
        ]

        try await performSSEStream(
            url: url,
            apiKey: apiKey,
            model: model,
            messages: messages,
            onDelta: onDelta
        )
    }

    // MARK: - Zero-Config Fast Neural Translation (Google GTX)

    private func translateViaZeroConfigGTX(text: String, targetCode: String, mode: TranslationTaskMode) async throws -> String {
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        comps.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: targetCode),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "dt", value: "bd"),
            URLQueryItem(name: "q", value: text)
        ]

        guard let url = comps.url else { return "" }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return ""
        }

        var translatedSentences = ""
        if let sentences = root.first as? [[Any]] {
            for item in sentences {
                if let seg = item.first as? String {
                    translatedSentences += seg
                }
            }
        }

        // In explain mode or single-word mode, also append POS dictionary entries if returned in root[1]
        if (mode == .explain || Self.isWordOrShortTerm(text)),
           root.count > 1,
           let dictBlocks = root[1] as? [[Any]] {
            var dictLines: [String] = []
            for block in dictBlocks {
                if block.count >= 2,
                   let pos = block[0] as? String,
                   let terms = block[1] as? [String] {
                    dictLines.append("• [\(pos)] \(terms.prefix(5).joined(separator: "；"))")
                }
            }
            if !dictLines.isEmpty {
                translatedSentences += "\n\n" + dictLines.joined(separator: "\n")
            }
        }

        return translatedSentences.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - OpenAI SSE Stream Helper

    private func performSSEStream(
        url: URL,
        apiKey: String,
        model: String,
        messages: [[String: String]],
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws {
        let payload: [String: Any] = [
            "model": model,
            "stream": true,
            "temperature": 0.2,
            "messages": messages
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 35
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let httpResp = response as? HTTPURLResponse, !(200...299).contains(httpResp.statusCode) {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 300 { break }
            }
            throw NSError(
                domain: "SnapLex",
                code: httpResp.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResp.statusCode): \(errorBody)"]
            )
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let dataStr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if dataStr == "[DONE]" { break }

            guard let data = dataStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first else {
                continue
            }

            if let delta = first["delta"] as? [String: Any],
               let content = delta["content"] as? String,
               !content.isEmpty {
                onDelta(content)
            } else if let message = first["message"] as? [String: Any],
                      let content = message["content"] as? String,
                      !content.isEmpty {
                onDelta(content)
            }
        }
    }
}
