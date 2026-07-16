import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.meetingdebrief.app"
    private static let account = "anthropic-api-key"

    /// ANTHROPIC_API_KEY from the environment wins (useful when launched from
    /// a terminal); otherwise the key saved in the Keychain.
    static func loadAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
            return env
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    /// Returns false when the Keychain rejects the write (e.g. a stale item
    /// saved by a differently-signed build is blocking the slot).
    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard !key.isEmpty else {
            SecItemDelete(base as CFDictionary)
            return true
        }
        let payload = [kSecValueData as String: Data(key.utf8)] as CFDictionary

        // Update in place when an item exists and is ours.
        let updateStatus = SecItemUpdate(base as CFDictionary, payload)
        if updateStatus == errSecSuccess { return true }

        // Otherwise clear whatever occupies the slot and write fresh.
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static var hasAPIKey: Bool { loadAPIKey() != nil }
}

enum SummarizerError: LocalizedError {
    case missingAPIKey
    case apiError(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Claude API key set — use “Set Claude API key…” in the menu bar."
        case .apiError(let message):
            return message
        case .emptyResponse:
            return "Claude returned no summary text."
        }
    }
}

/// Summarizes a meeting transcript via the Claude API (claude-opus-4-8).
enum ClaudeSummarizer {
    static func summarize(transcript: Transcript, eventTitle: String, eventEnd: Date) async throws -> String {
        guard let apiKey = KeychainHelper.loadAPIKey() else {
            throw SummarizerError.missingAPIKey
        }

        let lines = transcript.segments
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")

        let prompt = """
        Summarize this work meeting transcript. "Me" is the app's owner speaking; \
        "Them" is the other participant(s), captured from system audio.

        Meeting: \(eventTitle)
        Date: \(eventEnd.formatted(date: .abbreviated, time: .shortened))

        Transcript:
        \(lines)

        Write a concise summary paragraph, then "Key points" as short bullets. \
        Then output a line containing exactly ===NEXT STEPS=== followed by \
        suggested next steps as short, actionable bullets (commitments made, \
        follow-ups, unresolved items to chase). If there are none, write None \
        after the marker. The transcription is imperfect — infer intent where \
        wording is garbled, and don't invent details that aren't supported by \
        the transcript. Respond in the same language as the transcript.
        """

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 300

        let body: [String: Any] = [
            "model": "claude-opus-4-8",
            "max_tokens": 16000,
            "thinking": ["type": "adaptive"],
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? "Claude API returned HTTP \(status)."
            throw SummarizerError.apiError(message)
        }

        guard let content = json?["content"] as? [[String: Any]] else {
            throw SummarizerError.emptyResponse
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SummarizerError.emptyResponse }
        return text
    }
}
