import AppKit
import SwiftUI

/// One in-progress meeting the user can pick to record.
struct MeetingChoice: Identifiable {
    let key: String
    let title: String
    let start: Date
    let end: Date
    var id: String { key }
}

/// Floating chooser shown when a remote "record" arrives while more than one
/// meeting is in progress: the user picks which meeting gets the recorder
/// instead of the app guessing.
@MainActor
final class RecordChoicePanelController: NSObject, NSWindowDelegate {
    static let shared = RecordChoicePanelController()

    private var panel: NSPanel?
    /// Runs when the chooser goes away without a pick (Cancel, Esc, or the
    /// window's close button) — cleared before a pick so it never runs then.
    private var onDismiss: (() -> Void)?

    func show(
        meetings: [MeetingChoice],
        onPick: @escaping (MeetingChoice) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        // Replacing an existing chooser is not a user cancel.
        self.onDismiss = nil
        close()

        let view = RecordChoiceView(
            meetings: meetings,
            onPick: { [weak self] choice in
                self?.onDismiss = nil
                self?.close()
                onPick(choice)
            },
            onCancel: { [weak self] in
                self?.close()
            }
        )
        self.onDismiss = onDismiss

        let panel = KeyablePanel(contentViewController: NSHostingController(rootView: view))
        panel.title = "Record meeting"
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        // Above everything, same as the debrief popup: the press that asked
        // for this came from a Stream Deck key, not a frontmost window.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        if let screen = NSScreen.main {
            var frame = panel.frame
            frame.origin.y = screen.visibleFrame.maxY - frame.height - 80
            panel.setFrame(frame, display: false)
        }

        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.close()
        panel = nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            panel = nil
            let handler = onDismiss
            onDismiss = nil
            handler?()
        }
    }
}

struct RecordChoiceView: View {
    let meetings: [MeetingChoice]
    let onPick: (MeetingChoice) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Record which meeting?")
                    .font(.headline)
                Text("More than one meeting is in progress.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                ForEach(meetings) { meeting in
                    Button {
                        onPick(meeting)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "record.circle")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(meeting.title)
                                    .fontWeight(.medium)
                                Text("\(meeting.start.formatted(date: .omitted, time: .shortened)) – \(meeting.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
