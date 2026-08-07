import SwiftUI

struct SettingsView: View {
    @State private var apiKey = ""
    @State private var savedFeedback: String?
    @State private var saveFailed = false
    @State private var syncURL = ""
    @State private var syncUser = ""
    @State private var syncPassword = ""
    @StateObject private var sync = SyncManager.shared
    @AppStorage("autoRecordMeetings") private var autoRecord = false
    @AppStorage("pastWindowDays") private var pastWindowDays = 30
    @AppStorage("internalDomains") private var internalDomains = ""
    @AppStorage("micEchoCancellation") private var micEchoCancellation = false
    @AppStorage("autoTagMeetings") private var autoTagMeetings = true
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
                TextField("Internal domains", text: $internalDomains, prompt: Text("yourcompany.com, contractor.com"))
                    .onSubmit { EventWatcher.shared.refresh() }
                Text("Your organization's email domain(s), comma-separated, so they're not mistaken for a client — teammates, contractors, bots. webex.com (including subdomains) is always ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Auto-tag meetings", isOn: $autoTagMeetings)
                    .onChange(of: autoTagMeetings) { _, on in
                        if on { EventWatcher.shared.refresh() }
                    }
                Text("New meetings get a tag automatically when history makes it obvious — the same recurring meeting, or meetings with the same client's attendees, were always tagged that way. Removing an auto-added tag sticks; the meeting won't be re-tagged.")
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

            Section {
                TextField("Sync URL", text: $syncURL, prompt: Text("https://example.com/api/debrief/sync"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .onChange(of: syncURL) { _, newValue in
                        UserDefaults.standard.set(
                            newValue.trimmingCharacters(in: .whitespaces),
                            forKey: SyncManager.urlDefaultsKey)
                    }
                if KeychainHelper.hasSyncToken {
                    HStack(spacing: 10) {
                        Label("Signed in", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Sync now") {
                            Task { await sync.syncNow(manual: true) }
                        }
                        .disabled(sync.syncing)
                        if sync.syncing { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Log out") {
                            sync.logOut()
                            syncUser = ""; syncPassword = ""
                        }
                    }
                } else {
                    TextField("Username", text: $syncUser)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $syncPassword)
                        .onSubmit { logIn() }
                    HStack(spacing: 10) {
                        Button("Log in") { logIn() }
                            .disabled(syncURL.trimmingCharacters(in: .whitespaces).isEmpty
                                      || syncUser.trimmingCharacters(in: .whitespaces).isEmpty
                                      || syncPassword.isEmpty || sync.syncing)
                        if sync.syncing { ProgressView().controlSize(.small) }
                    }
                }
                Label(sync.lastStatus,
                      systemImage: KeychainHelper.hasSyncToken ? "arrow.triangle.2.circlepath" : "iphone.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("iPhone sync")
            } footer: {
                Text("Log in with the account you created in the iPhone app to sync meeting notes, summaries, tags, attendance, and transcript text (no audio) to your self-hosted endpoint. Uploads automatically a few seconds after any change and every 5 minutes. The token is stored securely in your Keychain.")
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
                Toggle("Echo-cancel microphone while recording (not recommended)", isOn: $micEchoCancellation)
                Text("Keeps participants' voices out of your “Me” stream on speaker calls, but degrades how you sound to others on live calls (they hear you dimmed) and lowers system volume while recording. Leave it off — Me/Them labels are cleaned up at transcription time instead (duplicated sentences are dropped from “Me”).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            apiKey = KeychainHelper.loadAPIKey() ?? ""
            let stored = UserDefaults.standard.string(forKey: SyncManager.urlDefaultsKey) ?? ""
            syncURL = stored.isEmpty ? "https://booking.packetfence.net/api/debrief/sync" : stored
        }
    }

    private func logIn() {
        let url = syncURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = syncUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !user.isEmpty, !syncPassword.isEmpty else { return }
        UserDefaults.standard.set(url, forKey: SyncManager.urlDefaultsKey)
        Task {
            let ok = await sync.logIn(username: user, password: syncPassword)
            if ok { syncPassword = "" }
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
