import Foundation
import AppKit
import Combine

/// Lets other tools (the Stream Deck plugin in `streamdeck/`) drive recording
/// without UI scripting:
///
/// - `meetingdebrief://record/toggle` stops the running recording, or starts
///   one for the meeting in progress right now. `record/start` and
///   `record/stop` do only their half.
/// - Every recording change is mirrored to `recording-state.json` in
///   Application Support, so the caller can show live state without polling
///   the app.
///
/// Open the URLs with `open -g` so the app stays in the background.
@MainActor
final class RemoteControl {
    static let shared = RemoteControl()

    struct StateFile: Codable {
        var recording: Bool
        var title: String?
        /// Seconds since 1970.
        var startedAt: Double?
        /// False when the other participants aren't being captured.
        var systemAudioOK: Bool
        /// Why the last remote command did nothing, e.g. "no-meeting".
        var lastError: String?
        var lastErrorAt: Double?
        var pid: Int32
        /// Which copy is running (dist/ build or /Applications), so the caller
        /// sends URLs to this one and not whichever LaunchServices prefers.
        var appPath: String
        var updatedAt: Double
    }

    nonisolated static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingDebrief", isDirectory: true)
            .appendingPathComponent("recording-state.json")
    }

    private var cancellables: Set<AnyCancellable> = []
    private var lastError: (code: String, at: Date)?

    /// Starts mirroring recording state to disk. Call once at launch.
    func start() {
        let recorder = RecordingManager.shared
        recorder.$state
            .combineLatest(recorder.$systemAudioError)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.writeState() }
            .store(in: &cancellables)
    }

    func handle(_ url: URL) {
        guard url.scheme == "meetingdebrief", url.host == "record" else { return }
        let recorder = RecordingManager.shared
        switch url.path {
        case "/toggle":
            if recorder.isRecording { recorder.stopRecording(manual: true) } else { startCurrentMeeting() }
        case "/start":
            if !recorder.isRecording { startCurrentMeeting() }
        case "/stop":
            recorder.stopRecording(manual: true)
        default:
            return
        }
    }

    /// Marks the app as not running, so the key doesn't stay red after quit.
    func appWillTerminate() {
        writeState(recordingOverride: false)
    }

    /// The meeting happening now. When meetings overlap, the one that started
    /// last is the one the user just joined.
    private func currentMeeting() -> (key: String, title: String)? {
        let now = Date()
        let event = EventWatcher.shared.events
            .filter { $0.startDate <= now && $0.endDate > now }
            .max { $0.startDate < $1.startDate }
        guard let event else { return nil }
        return (occurrenceKey(for: event), event.title ?? "Untitled event")
    }

    private func startCurrentMeeting() {
        guard let meeting = currentMeeting() else {
            lastError = ("no-meeting", Date())
            writeState()
            return
        }
        lastError = nil
        Task {
            await RecordingManager.shared.startRecording(
                occurrenceKey: meeting.key,
                title: meeting.title,
                force: true,
                interactive: true
            )
        }
    }

    private func writeState(recordingOverride: Bool? = nil) {
        let recorder = RecordingManager.shared
        var file = StateFile(
            recording: false,
            systemAudioOK: recorder.systemAudioError == nil,
            lastError: lastError?.code,
            lastErrorAt: lastError?.at.timeIntervalSince1970,
            pid: ProcessInfo.processInfo.processIdentifier,
            appPath: Bundle.main.bundlePath,
            updatedAt: Date().timeIntervalSince1970
        )
        if case .recording(_, let title, let startedAt) = recorder.state, recordingOverride != false {
            file.recording = true
            file.title = title
            file.startedAt = startedAt.timeIntervalSince1970
        }
        let url = Self.stateURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(file).write(to: url, options: .atomic)
        } catch {
            NSLog("MeetingDebrief: could not write recording state: \(error.localizedDescription)")
        }
    }
}
