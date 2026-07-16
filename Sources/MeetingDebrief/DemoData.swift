import Foundation
@preconcurrency import EventKit

/// Fictional data for documentation screenshots. Enabled with the environment
/// variable `MEETINGDEBRIEF_DEMO=1`. In demo mode the app never touches the
/// real calendar or the real notes folder — events are synthetic and all
/// persistence goes to `~/Documents/MeetingDebrief-Demo/`.
enum DemoData {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MEETINGDEBRIEF_DEMO"] == "1"
    }

    private struct Meeting {
        let title: String
        let client: String?          // shown as Client row + used as a tag
        let startFromNow: TimeInterval
        let duration: TimeInterval
        let location: String?
        let inviteNotes: String?
        let attendance: ClientAttendance?
        let summary: String?
        let nextStep: String?
        let transcript: [(speaker: String, text: String, start: TimeInterval)]?
    }

    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 86400

    private static let meetings: [Meeting] = [
        Meeting(
            title: "Globex — Q3 Platform Review",
            client: "Globex",
            startFromNow: -15 * 60,
            duration: 30 * 60,
            location: "Zoom",
            inviteNotes: "Quarterly review of the platform rollout. Agenda: adoption metrics, open blockers, Q4 plan.",
            attendance: .showed,
            summary: """
            Reviewed Q3 rollout with the Globex team. Adoption is ahead of plan \
            (72% of sites live). Two blockers remain: the SSO handoff on legacy \
            sites and reporting latency in the EU region.

            Key points
            • 72% of sites migrated, ahead of the 60% target.
            • EU reporting latency traced to a single under-provisioned replica.
            • Legacy SSO handoff needs a config change on their side.
            """,
            nextStep: """
            • Send the replica-sizing recommendation to their infra team by Friday.
            • Schedule the legacy SSO working session for next week.
            """,
            transcript: [
                ("Them", "Thanks for jumping on. How are we tracking against the Q3 plan?", 0),
                ("Me", "Ahead, actually — we're at 72% of sites live against a 60% target.", 6),
                ("Them", "That's great. The one thing we keep hearing is reporting is slow in the EU.", 14),
                ("Me", "Right — we traced that to one replica that's under-provisioned. Easy fix.", 22),
                ("Them", "And the legacy sites still can't do the single sign-on handoff.", 31),
                ("Me", "That needs a config change on your side. Let's set up a working session next week.", 38),
            ]
        ),
        Meeting(
            title: "Initech — Security Audit Prep",
            client: "Initech",
            startFromNow: 45 * 60,
            duration: 60 * 60,
            location: "Meet",
            inviteNotes: "Prep call ahead of the annual security audit.",
            attendance: nil, summary: nil, nextStep: nil, transcript: nil
        ),
        Meeting(
            title: "Acme Corp — Kickoff",
            client: "Acme Corp",
            startFromNow: -3 * hour,
            duration: 30 * 60,
            location: "Webex",
            inviteNotes: "Project kickoff with the Acme delivery team.",
            attendance: .showed,
            summary: "Kicked off the engagement. Agreed on scope, weekly cadence, and a shared tracker.",
            nextStep: "Share the project plan and access request form.",
            transcript: nil
        ),
        Meeting(
            title: "Weekly Team Standup",
            client: nil,
            startFromNow: -1 * hour,
            duration: 25 * 60,
            location: nil,
            inviteNotes: nil,
            attendance: nil, summary: nil, nextStep: nil, transcript: nil
        ),
        Meeting(
            title: "Umbrella Co — Intro",
            client: "Umbrella Co",
            startFromNow: -26 * hour,
            duration: 30 * 60,
            location: "Zoom",
            inviteNotes: "Intro call.",
            attendance: .noShow,
            summary: nil,
            nextStep: "Reschedule — no-show. Send a new set of times.",
            transcript: nil
        ),
        Meeting(
            title: "Globex — Discovery",
            client: "Globex",
            startFromNow: -3 * day,
            duration: 45 * 60,
            location: "Zoom",
            inviteNotes: "Discovery session.",
            attendance: .showed,
            summary: "Walked through their environment. 40 sites, mixed vendors, tight EU data-residency needs.",
            nextStep: "Draft the migration approach for the first 5 pilot sites.",
            transcript: nil
        ),
        Meeting(
            title: "Globex — Onboarding",
            client: "Globex",
            startFromNow: -8 * day,
            duration: 60 * 60,
            location: "Webex",
            inviteNotes: "Onboarding and access setup.",
            attendance: .showed,
            summary: nil,
            nextStep: "Confirm admin accounts are provisioned before the pilot.",
            transcript: nil
        ),
    ]

    private static var clientByTitle: [String: String] = [:]

    /// Build the synthetic events and seed their notes/tags/attendance/
    /// transcripts. Returns the events for the watcher to publish.
    static func buildAndSeed(store: EKEventStore) -> [EKEvent] {
        let now = Date()
        var events: [EKEvent] = []
        var entries: [DebriefEntry] = []
        var attendance: [String: String] = [:]
        var tags: [String: [String]] = [:]

        for m in meetings {
            let event = EKEvent(eventStore: store)
            event.title = m.title
            event.startDate = now.addingTimeInterval(m.startFromNow)
            event.endDate = event.startDate.addingTimeInterval(m.duration)
            event.location = m.location
            event.notes = m.inviteNotes
            events.append(event)

            let key = occurrenceKey(for: event)
            if let client = m.client {
                clientByTitle[m.title] = client
                tags[key] = [client]
            }
            if let a = m.attendance {
                attendance[key] = a.rawValue
            }
            var created = event.startDate.addingTimeInterval(m.duration)
            if let summary = m.summary {
                entries.append(demoEntry(key, m.title, event.endDate, .summary, summary, created))
                created = created.addingTimeInterval(60)
            }
            if let nextStep = m.nextStep {
                entries.append(demoEntry(key, m.title, event.endDate, .nextStep, nextStep, created))
            }
            if let transcript = m.transcript {
                seedTranscript(key: key, segments: transcript)
            }
        }

        writeJSON(entries, to: "entries.json")
        writeJSON(attendance, to: "attendance.json")
        writeJSON(tags, to: "tags.json")
        return events
    }

    static func client(for event: EKEvent) -> String? {
        clientByTitle[event.title ?? ""]
    }

    // MARK: - Seeding helpers

    private static func demoEntry(
        _ key: String, _ title: String, _ end: Date, _ kind: NoteKind, _ text: String, _ created: Date
    ) -> DebriefEntry {
        DebriefEntry(
            id: UUID(), occurrenceKey: key, eventTitle: title, eventEnd: end,
            kindRaw: kind.rawValue, text: text, createdAt: created
        )
    }

    private static func seedTranscript(key: String, segments: [(speaker: String, text: String, start: TimeInterval)]) {
        let folder = RecordingManager.recordingFolder(for: key)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A stub audio file so the UI treats the recording as present.
        FileManager.default.createFile(atPath: folder.appendingPathComponent("mic.m4a").path, contents: Data())
        let transcript = Transcript(
            segments: segments.map {
                TranscriptSegment(speaker: $0.speaker, start: $0.start, text: $0.text)
            },
            locale: "en-US",
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(transcript) {
            try? data.write(to: Transcriber.transcriptURL(in: folder))
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T, to name: String) {
        try? FileManager.default.createDirectory(at: NotesStore.folderURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) {
            try? data.write(to: NotesStore.folderURL.appendingPathComponent(name))
        }
    }
}
