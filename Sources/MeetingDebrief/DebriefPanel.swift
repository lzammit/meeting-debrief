import AppKit
import SwiftUI

/// Floating panel that jumps on screen when a meeting ends.
@MainActor
final class DebriefPanelController {
    static let shared = DebriefPanelController()

    private var panel: NSPanel?

    func show(
        occurrenceKey: String, eventTitle: String, eventEnd: Date,
        onDismiss: @escaping () -> Void,
        onSnooze: @escaping (TimeInterval) -> Void
    ) {
        close()

        let view = DebriefView(
            eventTitle: eventTitle,
            eventEnd: eventEnd,
            initialAttendance: DebriefStore.shared.attendance(for: occurrenceKey),
            onSave: { kind, text in
                Task { @MainActor in
                    DebriefStore.shared.add(
                        kind: kind, text: text, occurrenceKey: occurrenceKey,
                        eventTitle: eventTitle, eventEnd: eventEnd
                    )
                }
            },
            onClose: { [weak self] in
                self?.close()
                onDismiss()
            },
            onSnooze: { [weak self] interval in
                Task { @MainActor in
                    self?.close()
                    onSnooze(interval)
                }
            },
            onAttendance: { value in
                Task { @MainActor in
                    DebriefStore.shared.setAttendance(value, for: occurrenceKey)
                }
            }
        )

        let hosting = NSHostingController(rootView: view)
        let panel = KeyablePanel(contentViewController: hosting)
        panel.title = "Meeting ended"
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        // Above every other window on the system — normal apps, floating
        // panels, full-screen apps — so the prompt can't be covered.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.center()
        // Nudge toward the top of the screen so it catches the eye.
        if let screen = NSScreen.main {
            var frame = panel.frame
            frame.origin.y = screen.visibleFrame.maxY - frame.height - 80
            panel.setFrame(frame, display: false)
        }

        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Bounce the Dock icon in case the user is looking elsewhere.
        NSApp.requestUserAttention(.criticalRequest)
    }

    private func close() {
        panel?.close()
        panel = nil
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

enum NoteKind: String {
    case summary = "Summary"
    case nextStep = "Next step"

    var other: NoteKind { self == .summary ? .nextStep : .summary }
}

/// Compact "did the client show up?" control. Clicking the selected option
/// again clears it back to unset.
struct AttendanceControl: View {
    let selection: ClientAttendance?
    let onChange: (ClientAttendance?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Client showed up?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            choiceButton(.showed, title: "Yes", icon: "checkmark.circle", color: .green)
            choiceButton(.noShow, title: "No-show", icon: "xmark.circle", color: .red)
        }
    }

    @ViewBuilder
    private func choiceButton(_ value: ClientAttendance, title: String, icon: String, color: Color) -> some View {
        if selection == value {
            Button {
                onChange(nil)
            } label: {
                Label(title, systemImage: icon)
            }
            .buttonStyle(.borderedProminent)
            .tint(color)
        } else {
            Button {
                onChange(value)
            } label: {
                Label(title, systemImage: icon)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct DebriefView: View {
    let eventTitle: String
    let eventEnd: Date
    let initialAttendance: ClientAttendance?
    let onSave: (NoteKind, String) -> Void
    let onClose: () -> Void
    let onSnooze: (TimeInterval) -> Void
    let onAttendance: (ClientAttendance?) -> Void

    private static let snoozeChoices: [(label: String, interval: TimeInterval)] = [
        ("5 minutes", 5 * 60),
        ("10 minutes", 10 * 60),
        ("15 minutes", 15 * 60),
        ("30 minutes", 30 * 60),
    ]

    private enum Stage {
        case choice
        case editing(NoteKind)
        case saved(NoteKind)
    }

    @State private var stage: Stage = .choice
    @State private var text = ""
    @State private var attendanceSelection: ClientAttendance?
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(eventTitle)
                    .font(.headline)
                Text("Ended at \(eventEnd.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            AttendanceControl(selection: attendanceSelection) { newValue in
                attendanceSelection = newValue
                onAttendance(newValue)
            }
            .onAppear { attendanceSelection = initialAttendance }

            switch stage {
            case .choice:
                Text("What would you like to capture?")
                HStack(spacing: 10) {
                    Button("Summary") { beginEditing(.summary) }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("Next step") { beginEditing(.nextStep) }
                        .keyboardShortcut("2", modifiers: .command)
                    Spacer()
                    Menu {
                        ForEach(Self.snoozeChoices, id: \.interval) { choice in
                            Button(choice.label) { onSnooze(choice.interval) }
                        }
                    } label: {
                        Label("Snooze", systemImage: "clock")
                    }
                    .fixedSize()
                    Button("Skip") { onClose() }
                        .keyboardShortcut(.cancelAction)
                }

            case .editing(let kind):
                Text(kind.rawValue)
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                    .focused($editorFocused)
                HStack {
                    Button("Back") { stage = .choice }
                    Spacer()
                    Button("Save") { save(kind) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

            case .saved(let kind):
                Label("\(kind.rawValue) saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                HStack {
                    Button("Add \(kind.other.rawValue.lowercased())") { beginEditing(kind.other) }
                    Spacer()
                    Button("Done") { onClose() }
                        .keyboardShortcut(.return)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func beginEditing(_ kind: NoteKind) {
        text = ""
        stage = .editing(kind)
        DispatchQueue.main.async { editorFocused = true }
    }

    private func save(_ kind: NoteKind) {
        onSave(kind, text)
        stage = .saved(kind)
    }
}
