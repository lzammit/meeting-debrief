#!/usr/bin/swift
// Checks whether Apple's on-device Foundation Models are usable on this Mac.
// Usage: swift tools/check-apple-ai.swift
import Foundation
import FoundationModels

if #available(macOS 26.0, *) {
    let model = SystemLanguageModel.default
    switch model.availability {
    case .available:
        print("Availability: AVAILABLE — trying a real generation…")
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: "Reply with exactly: OK")
                print("Generation test: SUCCESS — model replied: \(response.content.prefix(80))")
            } catch {
                print("Generation test: FAILED — \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
    case .unavailable(let reason):
        print("Availability: UNAVAILABLE — reason: \(reason)")
    }
} else {
    print("macOS 26 APIs not present")
}
