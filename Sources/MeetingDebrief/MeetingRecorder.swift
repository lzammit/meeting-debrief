import Foundation
import AVFoundation
import CoreAudio
import CoreMedia
import ScreenCaptureKit
import AppKit

protocol SystemAudioCapturing: AnyObject {
    func stop() async
}

enum RecordingState: Equatable {
    case idle
    case recording(occurrenceKey: String, title: String, startedAt: Date)
}

/// Records a meeting as two streams: the mic (you) and system audio (the
/// other participants, via ScreenCaptureKit). On stop, kicks off on-device
/// transcription of both.
@MainActor
final class RecordingManager: ObservableObject {
    static let shared = RecordingManager()

    @Published var state: RecordingState = .idle
    @Published var transcribingKeys: Set<String> = []
    /// Bumped whenever a transcript lands on disk so views reload it.
    @Published var transcriptRevision = 0
    /// Why the last transcription attempt for a meeting produced no transcript.
    @Published var transcriptionErrors: [String: String] = [:]

    /// Meetings the user manually stopped — don't auto-restart them on the
    /// next calendar refresh.
    private(set) var userStoppedKeys: Set<String> = []

    /// Why system audio (the other participants) isn't being captured, if it
    /// failed on the current/last recording.
    @Published var systemAudioError: String?
    /// Why the microphone isn't being captured, if it failed.
    @Published var micAudioError: String?

    private var micCapture: MicCapture?
    private var systemCapture: SystemAudioCapturing?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    func isRecording(_ occurrenceKey: String) -> Bool {
        if case .recording(let key, _, _) = state { return key == occurrenceKey }
        return false
    }

    nonisolated static func recordingFolder(for occurrenceKey: String) -> URL {
        let safe = String(occurrenceKey.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return NotesStore.folderURL
            .appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
    }

    nonisolated static func hasRecording(for occurrenceKey: String) -> Bool {
        partCount(in: recordingFolder(for: occurrenceKey)) > 0
    }

    /// File URL for one part of a recording. Part 0 keeps the original names
    /// (mic.m4a / system.m4a); later parts get -2, -3, … suffixes.
    nonisolated static func partURL(in folder: URL, base: String, part: Int) -> URL {
        folder.appendingPathComponent(part == 0 ? "\(base).m4a" : "\(base)-\(part + 1).m4a")
    }

    nonisolated static func partCount(in folder: URL) -> Int {
        let fm = FileManager.default
        var count = 0
        while fm.fileExists(atPath: partURL(in: folder, base: "mic", part: count).path)
            || fm.fileExists(atPath: partURL(in: folder, base: "system", part: count).path) {
            count += 1
        }
        return count
    }

    // MARK: - Start / stop

    func startRecording(occurrenceKey: String, title: String, force: Bool = false, interactive: Bool = false) async {
        guard case .idle = state else { return }
        if force { userStoppedKeys.remove(occurrenceKey) }
        guard !userStoppedKeys.contains(occurrenceKey) else { return }

        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else { return }

        let folder = Self.recordingFolder(for: occurrenceKey)

        // A previous recording exists (e.g. the app restarted mid-meeting):
        // ask instead of silently overwriting it.
        var part = Self.partCount(in: folder)
        if part > 0 {
            switch askExistingRecordingChoice(title: title) {
            case .cancel:
                userStoppedKeys.insert(occurrenceKey)
                return
            case .replace:
                try? FileManager.default.removeItem(at: folder)
                part = 0
            case .addPart:
                break
            }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Mic with echo cancellation: audio playing from the speakers (the
        // other participants) is subtracted, so this stream is only "Me" —
        // even on built-in speakers + mic.
        let echoCancellation = UserDefaults.standard.object(forKey: "micEchoCancellation") as? Bool ?? true
        let mic = MicCapture()
        do {
            try mic.start(
                outputURL: Self.partURL(in: folder, base: "mic", part: part),
                voiceProcessing: echoCancellation
            )
            micCapture = mic
            micAudioError = nil
        } catch {
            micCapture = nil
            micAudioError = "Your microphone is NOT being captured. (\(error.localizedDescription))"
        }

        // System audio (the other participants). Default: ScreenCaptureKit —
        // it observes the mixed output without touching any app's audio
        // path, so conference apps' echo cancellation keeps working (the
        // CoreAudio process tap degrades the user's voice on Webex/Teams
        // calls). The tap remains available as an opt-in in Settings.
        let systemURL = Self.partURL(in: folder, base: "system", part: part)
        let useTap = UserDefaults.standard.bool(forKey: "systemAudioUseTap")
        do {
            if useTap, #available(macOS 14.2, *) {
                let tap = SystemAudioTapCapture(outputURL: systemURL)
                try tap.start()
                systemCapture = tap
            } else {
                // Auto-started recordings must never pop the macOS capture
                // re-approval dialog at login — record mic-only instead and
                // let the user re-approve on their next manual recording.
                if !interactive, !CGPreflightScreenCaptureAccess() {
                    throw NSError(domain: "MeetingDebrief", code: 10, userInfo: [
                        NSLocalizedDescriptionKey: "macOS wants you to re-approve capture — click “Record again…” on this meeting and choose Allow when asked."
                    ])
                }
                let sck = SystemAudioCapture(outputURL: systemURL)
                try await sck.start()
                systemCapture = sck
            }
            systemAudioError = nil
        } catch {
            systemCapture = nil
            systemAudioError = "System audio is NOT being captured — other participants won't be recorded. (\(error.localizedDescription))"
        }

        state = .recording(occurrenceKey: occurrenceKey, title: title, startedAt: Date())
    }

    func stopRecording(manual: Bool = false) {
        guard case .recording(let key, _, _) = state else { return }
        if manual { userStoppedKeys.insert(key) }

        let mic = micCapture
        let capture = systemCapture
        micCapture = nil
        systemCapture = nil
        mic?.stop()
        state = .idle

        transcribingKeys.insert(key)
        Task { [weak self] in
            await capture?.stop()
            let result = await Transcriber.transcribeFolder(Self.recordingFolder(for: key))
            self?.transcriptionErrors[key] = result.errorMessage
            self?.transcribingKeys.remove(key)
            self?.transcriptRevision += 1
        }
    }

    func stopIfRecording(matching occurrenceKey: String) {
        guard isRecording(occurrenceKey) else { return }
        stopRecording()
    }

    /// Re-run (or run for the first time) transcription of an existing recording.
    func transcribe(occurrenceKey: String) async {
        guard !transcribingKeys.contains(occurrenceKey) else { return }
        transcribingKeys.insert(occurrenceKey)
        let result = await Transcriber.transcribeFolder(Self.recordingFolder(for: occurrenceKey))
        transcriptionErrors[occurrenceKey] = result.errorMessage
        transcribingKeys.remove(occurrenceKey)
        transcriptRevision += 1
    }

    private enum ExistingRecordingChoice {
        case addPart
        case replace
        case cancel
    }

    private func askExistingRecordingChoice(title: String) -> ExistingRecordingChoice {
        let alert = NSAlert()
        alert.messageText = "A recording already exists for “\(title)”"
        alert.informativeText = "Add a new part to keep the existing audio and continue recording, or replace it and start over. The transcript will cover all parts."
        alert.addButton(withTitle: "Add new part")
        alert.addButton(withTitle: "Replace recording")
        alert.addButton(withTitle: "Don't record")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .addPart
        case .alertSecondButtonReturn: return .replace
        default: return .cancel
        }
    }

    /// Delete a meeting's recording folder (audio files + transcript).
    func deleteRecording(occurrenceKey: String) {
        guard !isRecording(occurrenceKey), !transcribingKeys.contains(occurrenceKey) else { return }
        try? FileManager.default.removeItem(at: Self.recordingFolder(for: occurrenceKey))
        transcriptionErrors.removeValue(forKey: occurrenceKey)
        transcriptRevision += 1
    }

    /// Best-effort cleanup on app termination.
    func emergencyStop() {
        micCapture?.stop()
        micCapture = nil
    }
}

/// Records the microphone. Two modes:
/// - Echo-cancelled (voice processing): keeps speaker audio out of the "Me"
///   stream, but interferes with conference apps that run their own audio
///   pipeline.
/// - Plain (AVAudioRecorder): completely inert — the same lightweight path a
///   voice-memo app uses. Conference apps keep full control of the mic;
///   speaker audio may bleed into "Me" unless a headset is used.
final class MicCapture {
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var recorder: AVAudioRecorder?

    func start(outputURL: URL, voiceProcessing: Bool) throws {
        try? FileManager.default.removeItem(at: outputURL)

        guard voiceProcessing else {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
            guard recorder.record() else {
                throw NSError(domain: "MicCapture", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "The microphone recorder failed to start."
                ])
            }
            self.recorder = recorder
            return
        }

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        // Voice processing normally ducks (lowers) all other audio, like a
        // phone call would. Keep the echo cancellation but don't touch the
        // system volume.
        input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false,
            duckingLevel: .min
        )
        let format = input.outputFormat(forBus: 0)
        // Voice processing exposes a multi-channel format (processed voice
        // plus internal reference channels). Channel 0 is the cleaned voice —
        // record that as mono; AAC can't encode the raw 9-channel stream.
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "MicCapture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't build a mono format at \(format.sampleRate) Hz."
            ])
        }

        let file = try AVAudioFile(forWriting: outputURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        self.file = file

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.file,
                  let source = buffer.floatChannelData?[0],
                  let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
                  let destination = mono.floatChannelData?[0] else { return }
            mono.frameLength = buffer.frameLength
            destination.update(from: source, count: Int(buffer.frameLength))
            try? file.write(from: mono)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            if engine.inputNode.isVoiceProcessingEnabled {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
            }
        }
        engine = nil
        file = nil
    }
}

/// Captures system-output audio (the other meeting participants) via a
/// CoreAudio process tap — the same mechanism Hyprnote uses. Requires only
/// the "System Audio Recording Only" permission: no screen recording grant,
/// no periodic re-approval prompts.
@available(macOS 14.2, *)
final class SystemAudioTapCapture: SystemAudioCapturing {
    private let outputURL: URL
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var tapFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "system-audio-tap")

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() throws {
        // 1. System-wide tap of all processes' output (mixed to stereo).
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "MeetingDebrief System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw Self.error("creating the audio tap", status) }
        tapID = newTapID

        // 2. The tap's stream format.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stopSync()
            throw Self.error("reading the tap format", status)
        }
        tapFormat = format

        // 3. Private aggregate device that carries the tap.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MeetingDebrief Tap",
            kAudioAggregateDeviceUIDKey as String: "com.luzammi.meetingdebrief.tap",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr else {
            stopSync()
            throw Self.error("creating the capture device", status)
        }
        aggregateID = newAggregateID

        // 4. Output file (AAC), client format matching the tap.
        try? FileManager.default.removeItem(at: outputURL)
        file = try AVAudioFile(
            forWriting: outputURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        // 5. Pull audio from the aggregate device and write it out.
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
            guard let self, let file = self.file, let tapFormat = self.tapFormat else { return }
            let bufferList = UnsafeMutablePointer(mutating: inInputData)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: bufferList, deallocator: nil) else { return }
            try? file.write(from: buffer)
        }
        guard status == noErr, let ioProcID else {
            stopSync()
            throw Self.error("setting up the audio callback", status)
        }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            stopSync()
            throw Self.error("starting capture", status)
        }
    }

    func stop() async {
        stopSync()
    }

    private func stopSync() {
        if let ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        // Sync with the IO queue so no in-flight write touches the file
        // after we close it.
        queue.sync { self.file = nil }
    }

    private static func error(_ step: String, _ status: OSStatus) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain, code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Failed while \(step) (OSStatus \(status))"]
        )
    }
}

/// Legacy capture via ScreenCaptureKit for macOS < 14.2 (needs the full
/// Screen & System Audio Recording permission).
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, SystemAudioCapturing {
    private let outputURL: URL
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var sessionStarted = false
    private let queue = DispatchQueue(label: "system-audio-capture")

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioCapture", code: 1)
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // Video is required by the stream but unused — keep it as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.showsCursor = false

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "SystemAudioCapture", code: 2)
        }
        self.writer = writer
        self.writerInput = input

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let writer, let writerInput else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }
        if writerInput.isReadyForMoreMediaData {
            writerInput.append(sampleBuffer)
        }
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        let finished = queue.sync { sessionStarted }
        writerInput?.markAsFinished()
        if finished, let writer {
            await writer.finishWriting()
        } else {
            writer?.cancelWriting()
        }
        writer = nil
        writerInput = nil
    }
}
