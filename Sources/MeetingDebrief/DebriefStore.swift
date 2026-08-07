import Foundation
@preconcurrency import EventKit

enum ClientAttendance: String, Codable {
    case showed
    case noShow
}

struct DebriefEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let occurrenceKey: String
    let eventTitle: String
    let eventEnd: Date
    let kindRaw: String
    let text: String
    let createdAt: Date

    var kind: NoteKind { NoteKind(rawValue: kindRaw) ?? .summary }
}

/// Source of truth for captured debrief entries, persisted as JSON in
/// ~/Documents/MeetingDebrief/entries.json. Every save also appends to the
/// daily markdown file (via NotesStore) as a human-readable export.
@MainActor
final class DebriefStore: ObservableObject {
    static let shared = DebriefStore()

    @Published private(set) var entries: [DebriefEntry] = []
    /// Client attendance per meeting occurrence (absent = not marked yet).
    @Published private(set) var attendance: [String: ClientAttendance] = [:]
    /// User tags per meeting occurrence (typically client names).
    @Published private(set) var meetingTags: [String: [String]] = [:]

    private var fileURL: URL {
        NotesStore.folderURL.appendingPathComponent("entries.json")
    }

    private var attendanceURL: URL {
        NotesStore.folderURL.appendingPathComponent("attendance.json")
    }

    private var tagsURL: URL {
        NotesStore.folderURL.appendingPathComponent("tags.json")
    }

    init() {
        load()
    }

    func attendance(for occurrenceKey: String) -> ClientAttendance? {
        attendance[occurrenceKey]
    }

    func setAttendance(_ value: ClientAttendance?, for occurrenceKey: String) {
        if let value {
            attendance[occurrenceKey] = value
        } else {
            attendance.removeValue(forKey: occurrenceKey)
        }
        persistAttendance()
    }

    func entries(for occurrenceKey: String) -> [DebriefEntry] {
        entries
            .filter { $0.occurrenceKey == occurrenceKey }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func add(kind: NoteKind, text: String, occurrenceKey: String, eventTitle: String, eventEnd: Date) {
        let entry = DebriefEntry(
            id: UUID(),
            occurrenceKey: occurrenceKey,
            eventTitle: eventTitle,
            eventEnd: eventEnd,
            kindRaw: kind.rawValue,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date()
        )
        entries.append(entry)
        persist()
        NotesStore.save(kind: kind, text: entry.text, eventTitle: eventTitle, eventEnd: eventEnd)
    }

    func delete(_ entry: DebriefEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    /// Remove every Summary entry captured for one meeting occurrence.
    func deleteSummaries(for occurrenceKey: String) {
        entries.removeAll { $0.occurrenceKey == occurrenceKey && $0.kind == .summary }
        persist()
    }

    // MARK: - Tags

    func tags(for occurrenceKey: String) -> [String] {
        meetingTags[occurrenceKey] ?? []
    }

    /// Every tag used anywhere, for pickers and suggestions.
    var allTags: [String] {
        Array(Set(meetingTags.values.flatMap { $0 }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func addTag(_ raw: String, to occurrenceKey: String) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        var list = meetingTags[occurrenceKey] ?? []
        guard !list.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        list.append(tag)
        meetingTags[occurrenceKey] = list
        persistTags()
    }

    // MARK: - Auto-tagging

    private static let autoTaggedDefaultsKey = "autoTaggedOccurrences"

    /// Tag current/upcoming meetings automatically when history makes the
    /// answer obvious: at least two previously tagged occurrences of the same
    /// recurring series — or two tagged meetings with the same client's
    /// attendees — and every one of them carries the tag (unanimity, not
    /// majority). Each occurrence is auto-tagged at most once, so removing an
    /// auto-added tag sticks. Off switch: Settings → Auto-tag meetings.
    func autoTag(events: [EKEvent]) {
        guard UserDefaults.standard.object(forKey: "autoTagMeetings") as? Bool ?? true else { return }
        let now = Date()
        var done = Set(UserDefaults.standard.stringArray(forKey: Self.autoTaggedDefaultsKey) ?? [])
        var doneChanged = false

        // Tag lists of every already-tagged meeting, grouped by recurring
        // series and by detected client domain.
        var seriesTags: [String: [[String]]] = [:]
        var clientTags: [String: [[String]]] = [:]
        for event in events {
            let tags = meetingTags[occurrenceKey(for: event)] ?? []
            guard !tags.isEmpty else { continue }
            if let seriesID = event.eventIdentifier {
                seriesTags[seriesID, default: []].append(tags)
            }
            if let client = EventWatcher.clientDomain(of: event) {
                clientTags[client, default: []].append(tags)
            }
        }

        for event in events where event.endDate > now {
            let key = occurrenceKey(for: event)
            guard !done.contains(key), (meetingTags[key] ?? []).isEmpty else { continue }
            var confident: [String] = []
            if let seriesID = event.eventIdentifier {
                confident += Self.unanimousTags(in: seriesTags[seriesID] ?? [])
            }
            if let client = EventWatcher.clientDomain(of: event) {
                confident += Self.unanimousTags(in: clientTags[client] ?? [])
            }
            guard !confident.isEmpty else { continue }
            for tag in confident { addTag(tag, to: key) }
            done.insert(key)
            doneChanged = true
        }

        if doneChanged {
            // Occurrence keys embed the end timestamp — drop records of
            // meetings long outside the visible window.
            let cutoff = now.timeIntervalSince1970 - 90 * 24 * 3600
            let pruned = done.filter { key in
                guard let end = key.components(separatedBy: "|").last.flatMap(Double.init) else { return false }
                return end > cutoff
            }
            UserDefaults.standard.set(Array(pruned), forKey: Self.autoTaggedDefaultsKey)
        }
    }

    /// Tags present (case-insensitively) in every one of the given tag lists,
    /// requiring at least two lists so a single tagged meeting never counts
    /// as "very confident". Casing comes from the first list.
    private static func unanimousTags(in taggedLists: [[String]]) -> [String] {
        guard taggedLists.count >= 2, var candidates = taggedLists.first else { return [] }
        for tags in taggedLists.dropFirst() {
            candidates = candidates.filter { candidate in
                tags.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
            }
        }
        return candidates
    }

    func removeTag(_ tag: String, from occurrenceKey: String) {
        var list = meetingTags[occurrenceKey] ?? []
        list.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        if list.isEmpty {
            meetingTags.removeValue(forKey: occurrenceKey)
        } else {
            meetingTags[occurrenceKey] = list
        }
        persistTags()
    }

    private func persistTags() {
        try? FileManager.default.createDirectory(at: NotesStore.folderURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(meetingTags) {
            try? data.write(to: tagsURL)
        }
        queueSync()
    }

    /// Push debrief changes to the iPhone companion (unless in demo mode).
    private func queueSync() {
        guard !DemoData.isEnabled else { return }
        SyncManager.shared.scheduleUpload()
    }

    /// Re-read all stores from disk (used after demo seeding).
    func reload() {
        load()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL) {
            entries = (try? decoder.decode([DebriefEntry].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: attendanceURL) {
            attendance = (try? decoder.decode([String: ClientAttendance].self, from: data)) ?? [:]
        }
        if let data = try? Data(contentsOf: tagsURL) {
            meetingTags = (try? decoder.decode([String: [String]].self, from: data)) ?? [:]
        }
    }

    private func persistAttendance() {
        try? FileManager.default.createDirectory(at: NotesStore.folderURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(attendance) {
            try? data.write(to: attendanceURL)
        }
        queueSync()
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: NotesStore.folderURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL)
        }
        queueSync()
    }
}
