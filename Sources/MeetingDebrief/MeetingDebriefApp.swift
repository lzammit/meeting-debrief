import SwiftUI
import AppKit
import EventKit

@main
struct MeetingDebriefApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var watcher = EventWatcher.shared
    @StateObject private var store = DebriefStore.shared
    @StateObject private var recorder = RecordingManager.shared

    var body: some Scene {
        Window("MeetingDebrief", id: "main") {
            MainWindowView()
                .environmentObject(watcher)
                .environmentObject(store)
                .environmentObject(recorder)
        }
        .defaultSize(width: 940, height: 640)

        MenuBarExtra {
            MenuContent()
                .environmentObject(watcher)
                .environmentObject(recorder)
        } label: {
            // Turn the icon into a warning when meetings would record without
            // the other participants (capture approval missing/expired).
            Image(systemName: recorder.captureApprovalMissing
                  ? "calendar.badge.exclamationmark"
                  : "calendar.badge.checkmark")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            EventWatcher.shared.start()
            SyncManager.shared.start()
            promptForCaptureApprovalIfNeeded()
        }
    }

    /// macOS drops the Screen & System Audio Recording approval periodically;
    /// recordings then silently lose the other participants. Launch is an
    /// interactive moment — re-ask here instead of failing mid-meeting.
    /// Only nags people who actually record meetings.
    @MainActor
    private func promptForCaptureApprovalIfNeeded() {
        RecordingManager.shared.refreshCaptureApproval()
        guard RecordingManager.shared.captureApprovalMissing,
              RecordingManager.hasEverRecorded else { return }

        let alert = NSAlert()
        alert.messageText = "Approve system audio capture"
        alert.informativeText = "macOS requires re-approving Screen & System Audio Recording from time to time. Until then, recorded meetings only capture your microphone — other participants are missing from transcripts."
        alert.addButton(withTitle: "Approve…")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if !CGRequestScreenCaptureAccess() {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                NSWorkspace.shared.open(url)
            }
            RecordingManager.shared.refreshCaptureApproval()
        }
    }

    // Keep running in the menu bar when the window is closed, so
    // end-of-meeting popups still fire.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Clears the menu-bar warning as soon as capture is re-approved in
    // System Settings and the user comes back to the app.
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            RecordingManager.shared.refreshCaptureApproval()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            RecordingManager.shared.emergencyStop()
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var watcher: EventWatcher
    @EnvironmentObject var recorder: RecordingManager
    @Environment(\.openWindow) private var openWindow

    private var autoRecordBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "autoRecordMeetings") },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: "autoRecordMeetings")
                watcher.refresh()
            }
        )
    }

    var body: some View {
        Group {
            Button("Open MeetingDebrief") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            switch watcher.authorization {
            case .denied:
                Text("Calendar access denied")
                Button("Open Privacy Settings…") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
                    NSWorkspace.shared.open(url)
                }
            case .pending:
                Text("Requesting calendar access…")
            case .granted:
                let remaining = watcher.todaysRemaining
                if remaining.isEmpty {
                    Text("No more events today")
                } else {
                    Text("Today's remaining events")
                    ForEach(remaining, id: \.self) { event in
                        Text("\(event.title ?? "Untitled") — ends \(Self.timeFormatter.string(from: event.endDate))")
                    }
                }
            }

            Divider()

            Toggle("Auto-record meetings", isOn: autoRecordBinding)
            if case .recording(_, let title, _) = recorder.state {
                Text("● Recording: \(title)")
                if recorder.systemAudioError != nil {
                    Text("⚠️ Only your mic — other participants aren't captured")
                }
                Button("Stop recording") {
                    recorder.stopRecording(manual: true)
                }
            }
            if recorder.captureApprovalMissing {
                Text("⚠️ System audio capture needs approval")
                Button("Approve system audio capture…") {
                    // Shows the system prompt when possible; falls back to the
                    // Screen & System Audio Recording privacy pane.
                    if !CGRequestScreenCaptureAccess() {
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                        NSWorkspace.shared.open(url)
                    }
                    recorder.refreshCaptureApproval()
                }
            }

            Divider()

            Button("Test popup") {
                watcher.showTestPopup()
            }
            Button("Open notes folder") {
                NotesStore.revealFolder()
            }
            SettingsLink {
                Text("Settings…")
            }

            Divider()

            Button("Quit MeetingDebrief") {
                NSApp.terminate(nil)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}
