import Foundation

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
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: NotesStore.folderURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL)
        }
    }
}
