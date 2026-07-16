#!/usr/bin/swift
// Tests long-form transcription of an audio file with the macOS 26
// SpeechAnalyzer API. Usage: swift tools/test-transcribe.swift <file>
import Foundation
import Speech
import AVFoundation

guard CommandLine.arguments.count > 1 else {
    print("usage: test-transcribe.swift <audio-file>")
    exit(1)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])

let semaphore = DispatchSemaphore(value: 0)
Task {
    defer { semaphore.signal() }
    guard #available(macOS 26.0, *) else {
        print("macOS 26 required")
        return
    }
    do {
        let locale = Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            print("Downloading speech model…")
            try await installation.downloadAndInstall()
            print("Model installed.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)
        print("Duration: \(Double(audioFile.length) / audioFile.fileFormat.sampleRate) s")

        async let collected: [String] = {
            var out: [String] = []
            for try await result in transcriber.results {
                out.append(String(result.text.characters))
            }
            return out
        }()

        if let last = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let results = try await collected
        print("Result count: \(results.count)")
        for text in results.prefix(6) {
            print("•", text.prefix(120))
        }
    } catch {
        print("ERROR: \(error)")
    }
}
semaphore.wait()
