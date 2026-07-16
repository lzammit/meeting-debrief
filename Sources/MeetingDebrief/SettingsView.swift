import SwiftUI

struct SettingsView: View {
    @State private var apiKey = ""
    @State private var savedFeedback: String?
    @State private var saveFailed = false
    @AppStorage("autoRecordMeetings") private var autoRecord = false
    @AppStorage("pastWindowDays") private var pastWindowDays = 30
    @AppStorage("internalDomains") private var internalDomains = ""
    @AppStorage("micEchoCancellation") private var micEchoCancellation = true
    @AppStorage("autoRecordWeekdaysOnly") private var autoRecordWeekdaysOnly = false
    @AppStorage("systemAudioUseTap") private var systemAudioUseTap = false

    private static let pastWindowChoices: [(label: String, days: Int)] = [
        ("1 week", 7),
        ("1 month", 30),
        ("3 months", 90),
        ("6 months", 180),
        ("1 year", 365),
        ("2 years", 730),
    ]

    var body: some View {
        Form {
            Section("Meeting list") {
                Picker("Show past meetings", selection: $pastWindowDays) {
                    ForEach(Self.pastWindowChoices, id: \.days) { choice in
                        Text(choice.label).tag(choice.days)
                    }
                }
                .onChange(of: pastWindowDays) { _, _ in
                    EventWatcher.shared.refresh()
                }
                Text("How far back the meeting list reaches. Upcoming meetings always cover the next 7 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Client detection") {
                TextField("Internal domains", text: $internalDomains, prompt: Text("inverse.ca, consultant.com"))
                    .onSubmit { EventWatcher.shared.refresh() }
                Text("Comma-separated email domains to ignore when identifying a meeting's client — teammates, contractors, bots. akamai.com and webex.com (including subdomains) are always ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("Claude API key", text: $apiKey, prompt: Text("sk-ant-…"))
                    .onSubmit { saveKey() }
                HStack(spacing: 10) {
                    Button("Save key") { saveKey() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Clear key") {
                        apiKey = ""
                        KeychainHelper.saveAPIKey("")
                        savedFeedback = "Key removed"
                        saveFailed = false
                    }
                    if let savedFeedback {
                        Label(savedFeedback, systemImage: saveFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(saveFailed ? .orange : .green)
                            .font(.callout)
                    }
                }
                Label(
                    KeychainHelper.hasAPIKey ? "A key is stored and readable" : "No key currently readable",
                    systemImage: KeychainHelper.hasAPIKey ? "key.fill" : "key.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Claude API")
            } footer: {
                Text("Used only by the “With Claude” summarize button — on-device summaries and transcription never use it. Stored securely in your Keychain. An ANTHROPIC_API_KEY environment variable takes precedence when the app is launched from a terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording") {
                Toggle("Auto-record meetings", isOn: $autoRecord)
                    .onChange(of: autoRecord) { _, _ in
                        EventWatcher.shared.refresh()
                    }
                Text("Records your mic and system audio during calendar meetings, then transcribes on-device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Weekdays only (Mon–Fri)", isOn: $autoRecordWeekdaysOnly)
                    .disabled(!autoRecord)
                    .onChange(of: autoRecordWeekdaysOnly) { _, _ in
                        EventWatcher.shared.refresh()
                    }
                Text("Auto-record stays off on Saturdays and Sundays. Manual recording still works anytime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use audio tap for system audio (not recommended)", isOn: $systemAudioUseTap)
                Text("The tap avoids the screen-recording permission but interferes with Webex/Teams echo cancellation — clients hear you “from afar” while recording. Leave it off: the default ScreenCaptureKit capture doesn't touch call audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Echo-cancel microphone while recording", isOn: $micEchoCancellation)
                Text("Keeps participants' voices out of your “Me” stream on speaker calls, at the cost of slightly lowered system volume while recording. If anyone ever says your voice sounds degraded while recording, turn this off — Me/Them labels are then cleaned up at transcription time instead (duplicated sentences are dropped from “Me”).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            apiKey = KeychainHelper.loadAPIKey() ?? ""
        }
    }

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainHelper.saveAPIKey(trimmed) {
            savedFeedback = "Key saved"
            saveFailed = false
        } else {
            savedFeedback = "Keychain rejected the save — try again"
            saveFailed = true
        }
    }
}
