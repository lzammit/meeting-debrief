import Foundation
import Speech
import AVFoundation
import CoreMedia

struct TranscriptSegment: Codable, Identifiable, Hashable {
    var id = UUID()
    let speaker: String       // "Me" (mic) or "Them" (system audio)
    let start: TimeInterval   // seconds from recording start
    let text: String

    private enum CodingKeys: String, CodingKey {
        case speaker, start, text
    }
}

struct Transcript: Codable {
    let segments: [TranscriptSegment]
    let locale: String
    let createdAt: Date
}

/// On-device transcription of a recording folder (mic.m4a + system.m4a).
/// Nothing is sent off the Mac.
enum Transcriber {
    /// Utterance break: a silence gap longer than this starts a new segment.
    private static let utteranceGap: TimeInterval = 1.25

    static func transcriptURL(in folder: URL) -> URL {
        folder.appendingPathComponent("transcript.json")
    }

    static func loadTranscript(for occurrenceKey: String) -> Transcript? {
        let url = transcriptURL(in: RecordingManager.recordingFolder(for: occurrenceKey))
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Transcript.self, from: data)
    }

    @discardableResult
    static func transcribeFolder(_ folder: URL) async -> (transcript: Transcript?, errorMessage: String?) {
        // A meeting may have several recording parts (mic.m4a, mic-2.m4a, …)
        // when recording was resumed. Transcribe them all, offsetting each
        // part's timestamps so the merged timeline stays in order.
        let fm = FileManager.default
        var files: [(url: URL, speaker: String, offset: TimeInterval)] = []
        var partIndex = 0
        var offset: TimeInterval = 0
        while true {
            let mic = RecordingManager.partURL(in: folder, base: "mic", part: partIndex)
            let system = RecordingManager.partURL(in: folder, base: "system", part: partIndex)
            let micExists = fm.fileExists(atPath: mic.path)
            let systemExists = fm.fileExists(atPath: system.path)
            if !micExists && !systemExists { break }
            if micExists { files.append((mic, "Me", offset)) }
            if systemExists { files.append((system, "Them", offset)) }
            offset += max(micExists ? duration(of: mic) : 0, systemExists ? duration(of: system) : 0) + 1
            partIndex += 1
        }

        guard !files.isEmpty else {
            return (nil, "No audio files found for this meeting.")
        }

        var segments: [TranscriptSegment] = []
        var failures: [String] = []
        var localeIdentifier = Locale.current.identifier

        if #available(macOS 26.0, *) {
            // Modern long-form API (SpeechAnalyzer) — handles recordings of
            // any length; no speech-recognition permission needed.
            let locale = await modernLocale()
            localeIdentifier = locale.identifier
            for file in files {
                do {
                    let result = try await transcribeFileModern(file.url, speaker: file.speaker, locale: locale)
                    segments += result.map {
                        TranscriptSegment(speaker: $0.speaker, start: $0.start + file.offset, text: $0.text)
                    }
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
        } else {
            guard await requestAuthorization() else {
                return (nil, "Speech recognition permission denied — enable it for MeetingDebrief in System Settings → Privacy & Security → Speech Recognition, then try again.")
            }
            let recognizer = SFSpeechRecognizer(locale: Locale.current)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            guard let recognizer, recognizer.isAvailable else {
                return (nil, "The speech recognizer is unavailable for your language right now.")
            }
            localeIdentifier = recognizer.locale.identifier
            for file in files {
                let result = await transcribeFile(file.url, recognizer: recognizer, speaker: file.speaker)
                segments += result.map {
                    TranscriptSegment(speaker: $0.speaker, start: $0.start + file.offset, text: $0.text)
                }
            }
        }

        guard !segments.isEmpty else {
            return (nil, failures.first ?? "No speech was detected in the recording — the audio may be silent or too short.")
        }
        segments.sort { $0.start < $1.start }
        segments = removeMicBleed(segments)

        let transcript = Transcript(
            segments: segments,
            locale: localeIdentifier,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(transcript) {
            try? data.write(to: transcriptURL(in: folder))
        }
        return (transcript, nil)
    }

    /// On speaker calls (no echo cancellation), participants' voices reach
    /// the mic too, so their sentences get transcribed twice — once as "Them"
    /// (system audio) and once as "Me" (mic pickup). Drop "Me" segments that
    /// duplicate a nearby "Them" segment.
    private static func removeMicBleed(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let themSegments = segments.filter { $0.speaker == "Them" }
        guard !themSegments.isEmpty else { return segments }

        return segments.filter { segment in
            guard segment.speaker == "Me" else { return true }
            let tokens = bleedTokens(segment.text)
            guard tokens.count >= 3 else { return true }   // too short to judge safely
            for other in themSegments where abs(other.start - segment.start) < 5 {
                let otherTokens = bleedTokens(other.text)
                guard !otherTokens.isEmpty else { continue }
                let overlap = tokens.intersection(otherTokens).count
                if Double(overlap) / Double(min(tokens.count, otherTokens.count)) >= 0.7 {
                    return false
                }
            }
            return true
        }
    }

    private static func bleedTokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 }
        )
    }

    private static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - Modern path (macOS 26+, long-form audio)

    @available(macOS 26.0, *)
    private static func modernLocale() async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        if supported.contains(where: { $0.identifier(.bcp47) == current.identifier(.bcp47) }) {
            return current
        }
        return Locale(identifier: "en-US")
    }

    @available(macOS 26.0, *)
    private static func transcribeFileModern(
        _ url: URL, speaker: String, locale: Locale
    ) async throws -> [TranscriptSegment] {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)

        async let collected: [TranscriptSegment] = {
            var out: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds
                out.append(TranscriptSegment(
                    speaker: speaker,
                    start: start.isFinite && start >= 0 ? start : 0,
                    text: text
                ))
            }
            return out
        }()

        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    // MARK: - Legacy path (macOS < 26)

    private static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private static func transcribeFile(
        _ url: URL, recognizer: SFSpeechRecognizer, speaker: String
    ) async -> [TranscriptSegment] {
        await withCheckedContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            request.addsPunctuation = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: group(result.bestTranscription, speaker: speaker))
                } else if error != nil {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Collapse word-level segments into utterances split on silence gaps.
    private static func group(_ transcription: SFTranscription, speaker: String) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current = ""
        var start: TimeInterval = 0
        var lastEnd: TimeInterval = 0

        for word in transcription.segments {
            if current.isEmpty {
                start = word.timestamp
            } else if word.timestamp - lastEnd > utteranceGap {
                out.append(TranscriptSegment(speaker: speaker, start: start, text: current))
                current = ""
                start = word.timestamp
            }
            current += (current.isEmpty ? "" : " ") + word.substring
            lastEnd = word.timestamp + word.duration
        }
        if !current.isEmpty {
            out.append(TranscriptSegment(speaker: speaker, start: start, text: current))
        }
        return out
    }
}
