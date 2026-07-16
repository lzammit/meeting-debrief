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

        MenuBarExtra("MeetingDebrief", systemImage: "calendar.badge.checkmark") {
            MenuContent()
                .environmentObject(watcher)
                .environmentObject(recorder)
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
        }
    }

    // Keep running in the menu bar when the window is closed, so
    // end-of-meeting popups still fire.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
                Button("Stop recording") {
                    recorder.stopRecording(manual: true)
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
