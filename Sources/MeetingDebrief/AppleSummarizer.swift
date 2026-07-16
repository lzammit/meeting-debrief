import Foundation
import FoundationModels

enum AppleSummarizerError: LocalizedError {
    case unavailable(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .emptyResponse:
            return "The on-device model returned no summary text."
        }
    }
}

/// Summarizes transcripts fully on-device using Apple's Foundation Models
/// (Apple Intelligence). The on-device model has a small context window, so
/// long transcripts are condensed chunk-by-chunk and then merged.
@available(macOS 26.0, *)
enum AppleSummarizer {
    /// Conservative per-request budget: ~6000 chars ≈ 1.7K tokens, leaving
    /// room for instructions and the response inside the ~4K-token window.
    private static let maxChunkChars = 6000

    private static let instructions = """
    You summarize work meeting transcripts. "Me" is the app's owner speaking; \
    "Them" is the other participant(s). The transcription is imperfect — infer \
    intent where wording is garbled and don't invent details that aren't in \
    the text. Respond in the same language as the transcript.
    """

    static func summarize(transcript: Transcript, eventTitle: String, eventEnd: Date) async throws -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw AppleSummarizerError.unavailable(describe(reason))
        }

        let lines = transcript.segments.map { "\($0.speaker): \($0.text)" }
        let full = lines.joined(separator: "\n")

        if full.count <= maxChunkChars {
            return try await finalSummary(of: full, sourceLabel: "Transcript", eventTitle: eventTitle, eventEnd: eventEnd)
        }

        // Long transcript: condense chunks into notes, and keep reducing the
        // notes recursively until they fit in one final-summary request.
        var pieces = chunk(lines)
        var round = 0
        while true {
            round += 1
            var notes: [String] = []
            for (index, piece) in pieces.enumerated() {
                notes.append(try await condense(piece, part: index + 1, of: pieces.count))
            }
            var joined = notes.joined(separator: "\n\n")
            if joined.count <= maxChunkChars || round >= 4 {
                if joined.count > maxChunkChars {
                    joined = String(joined.prefix(maxChunkChars))
                }
                return try await finalSummary(
                    of: joined,
                    sourceLabel: "Condensed notes from a long meeting",
                    eventTitle: eventTitle, eventEnd: eventEnd
                )
            }
            pieces = chunk(joined.components(separatedBy: "\n"))
        }
    }

    /// Group lines into chunks that fit the per-request budget.
    private static func chunk(_ lines: [String]) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in lines {
            if !current.isEmpty, current.count + line.count + 1 > maxChunkChars {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func condense(_ text: String, part: Int, of total: Int) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
        This is part \(part) of \(total) of a meeting transcript or meeting \
        notes. Condense it into brief factual notes: topics discussed, \
        decisions, numbers, and action items. No introduction, just the notes.

        \(text)
        """
        return try await session.respond(to: prompt).content
    }

    private static func finalSummary(
        of text: String, sourceLabel: String, eventTitle: String, eventEnd: Date
    ) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
        Meeting: \(eventTitle)
        Date: \(eventEnd.formatted(date: .abbreviated, time: .shortened))

        \(sourceLabel):
        \(text)

        Write a concise summary paragraph, then "Key points" as short bullets. \
        Then write a line containing exactly ===NEXT STEPS=== and after it, \
        suggested next steps as short actionable bullets (commitments, \
        follow-ups, unresolved items). If there are none, write None after \
        the marker.
        """
        let response = try await session.respond(to: prompt)
        let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw AppleSummarizerError.emptyResponse }
        return result
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence — use the Claude button instead."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off — enable it in System Settings → Apple Intelligence & Siri, then try again."
        case .modelNotReady:
            return "The on-device model is still downloading — try again in a few minutes."
        @unknown default:
            return "The on-device model is unavailable."
        }
    }
}
