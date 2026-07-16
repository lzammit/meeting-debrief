import Foundation
import AppKit

/// Appends debrief entries to one markdown file per day in
/// ~/Documents/MeetingDebrief/, e.g. 2026-07-07.md.
enum NotesStore {
    static var folderURL: URL {
        // Demo mode keeps all data in a separate folder so it never mixes
        // with real notes.
        let name = DemoData.isEnabled ? "MeetingDebrief-Demo" : "MeetingDebrief"
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }

    static func save(kind: NoteKind, text: String, eventTitle: String, eventEnd: Date) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let fileURL = folderURL.appendingPathComponent("\(dayFormatter.string(from: eventEnd)).md")

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        var entry = ""
        if !fm.fileExists(atPath: fileURL.path) {
            entry += "# Meeting debriefs — \(dayFormatter.string(from: eventEnd))\n"
        }
        entry += """

        ## \(timeFormatter.string(from: eventEnd)) — \(eventTitle)

        **\(kind.rawValue):** \(text.trimmingCharacters(in: .whitespacesAndNewlines))

        """

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        } else {
            try? Data(entry.utf8).write(to: fileURL)
        }
    }

    static func revealFolder() {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folderURL)
    }
}
