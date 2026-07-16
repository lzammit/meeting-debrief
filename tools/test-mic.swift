#!/usr/bin/swift
// Tests whether the echo-cancelled mic capture produces audio buffers.
// Usage: swift tools/test-mic.swift [plain|vp|vpmixer]
import Foundation
import AVFoundation

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "vp"
let engine = AVAudioEngine()
let input = engine.inputNode
var bufferCount = 0
var totalPower: Float = 0

do {
    if mode != "plain" {
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min
            )
    }
    if mode == "vpmixer" {
        // Muted render path so the duplex voice-processing unit runs.
        engine.connect(engine.inputNode, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0
    }
    let format = input.outputFormat(forBus: 0)
    print("mode=\(mode) format=\(format.sampleRate)Hz ch=\(format.channelCount)")

    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        bufferCount += 1
        if let data = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += abs(data[i]) }
            totalPower += sum / Float(max(buffer.frameLength, 1))
        }
    }
    engine.prepare()
    try engine.start()
    Thread.sleep(forTimeInterval: 3)
    engine.stop()
    print("buffers=\(bufferCount) avgLevel=\(bufferCount > 0 ? totalPower / Float(bufferCount) : 0)")
} catch {
    print("ERROR: \(error)")
}
