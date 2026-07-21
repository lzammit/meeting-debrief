import Foundation
import EventKit
import AppKit

/// Text-only bundle synced to the self-hosted endpoint for the iPhone
/// companion. No audio — just meeting metadata, notes, tags, attendance, and
/// transcript text. Works across different Apple IDs because it's a plain
/// HTTPS endpoint, not iCloud.

struct SyncSegment: Codable {
    let speaker: String
    let start: TimeInterval
    let text: String
}

struct SyncEntry: Codable {
    let kind: String
    let text: String
    let createdAt: Date
}

struct SyncAttendee: Codable {
    let name: String
    let status: String   // accepted | declined | tentative | unknown
}

struct SyncMeeting: Codable {
    let key: String
    let title: String
    let start: Date?
    let end: Date?
    let calendarColor: String?   // "#RRGGBB"
    let calendarTitle: String?
    let client: String?
    let location: String?
    let organizer: String?
    let attendees: [SyncAttendee]
    let inviteNotes: String?
    let tags: [String]
    let attendance: String?
    let entries: [SyncEntry]
    let transcript: [SyncSegment]
}

struct SyncBundle: Codable {
    let generatedAt: Date
    let meetings: [SyncMeeting]
}

@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()

    @Published var lastStatus: String = "Not synced yet"
    @Published var syncing = false

    private var debounce: Timer?
    private var periodic: Timer?

    static let urlDefaultsKey = "debriefSyncURL"

    var isConfigured: Bool {
        !(UserDefaults.standard.string(forKey: Self.urlDefaultsKey) ?? "").isEmpty
            && KeychainHelper.hasSyncToken
    }

    func start() {
        periodic?.invalidate()
        periodic = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow(manual: false) }
        }
        periodic?.tolerance = 30
        Task { await syncNow(manual: false) }
    }

    /// Logs in with the dedicated account and stores the returned sync token
    /// in the Keychain, so uploads can authenticate. Derives the login
    /// endpoint from the configured sync URL (…/sync → …/login).
    @discardableResult
    func logIn(username: String, password: String) async -> Bool {
        guard let syncURL = UserDefaults.standard.string(forKey: Self.urlDefaultsKey),
              let loginURL = Self.loginURL(fromSync: syncURL) else {
            lastStatus = "Set the sync URL first."
            return false
        }
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["username": username, "password": password])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastStatus = "Login failed: no response."
                return false
            }
            guard http.statusCode == 200 else {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                lastStatus = http.statusCode == 401
                    ? "Login failed: invalid username or password."
                    : "Login failed: \(msg ?? "HTTP \(http.statusCode)")."
                return false
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = obj["token"] as? String, !token.isEmpty,
                  KeychainHelper.saveSyncToken(token) else {
                lastStatus = "Login failed: could not store token."
                return false
            }
            lastStatus = "Logged in — syncing…"
            await syncNow(manual: true)
            return true
        } catch {
            lastStatus = "Login failed: \(error.localizedDescription)"
            return false
        }
    }

    func logOut() {
        KeychainHelper.saveSyncToken("")
        lastStatus = "Logged out"
    }

    /// Turn "https://host/api/debrief/sync" into ".../login".
    static func loginURL(fromSync sync: String) -> URL? {
        guard var comps = URLComponents(string: sync) else { return nil }
        var path = comps.path
        if path.hasSuffix("/sync") {
            path = String(path.dropLast("/sync".count)) + "/login"
        } else {
            return nil
        }
        comps.path = path
        return comps.url
    }

    /// Called after any debrief change; coalesces bursts into one upload.
    func scheduleUpload() {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.syncNow(manual: false) }
        }
    }

    func syncNow(manual: Bool) async {
        guard isConfigured else {
            if manual { lastStatus = "Set the sync URL and token in Settings first." }
            return
        }
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        let bundle = Self.buildBundle()
        do {
            try await upload(bundle)
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            lastStatus = "Synced \(bundle.meetings.count) meetings at \(time)"
        } catch {
            lastStatus = "Sync failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func upload(_ bundle: SyncBundle) async throws -> Int {
        guard let urlString = UserDefaults.standard.string(forKey: Self.urlDefaultsKey),
              let url = URL(string: urlString),
              let token = KeychainHelper.loadSyncToken() else {
            throw NSError(domain: "SyncManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sync not configured."])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(bundle)
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "SyncManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "No response."])
        }
        guard http.statusCode == 200 else {
            let msg = http.statusCode == 401 ? "bad token" : "HTTP \(http.statusCode)"
            throw NSError(domain: "SyncManager", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return body.count
    }

    /// Assemble the bundle: every calendar event in range (so the iPhone shows
    /// the same timeline as the Mac), plus any debrief-only keys, with their
    /// notes, tags, attendance, and transcript text.
    static func buildBundle() -> SyncBundle {
        let store = DebriefStore.shared
        let watcher = EventWatcher.shared

        var byKey: [String: EKEvent] = [:]
        for event in watcher.events { byKey[occurrenceKey(for: event)] = event }

        var keys = Set(byKey.keys)
        keys.formUnion(store.entries.map(\.occurrenceKey))
        keys.formUnion(store.attendance.keys)
        keys.formUnion(store.meetingTags.keys)

        let meetings: [SyncMeeting] = keys.map { key in
            let event = byKey[key]
            let entries = store.entries(for: key).map {
                SyncEntry(kind: $0.kind.rawValue, text: $0.text, createdAt: $0.createdAt)
            }
            let title = event?.title ?? store.entries(for: key).first?.eventTitle ?? "Untitled meeting"
            let start: Date?
            let end: Date?
            if let event {
                start = event.startDate
                end = event.endDate
            } else {
                (start, end) = parseDates(from: key, fallbackEnd: store.entries(for: key).first?.eventEnd)
            }
            let transcript = Transcriber.loadTranscript(for: key)?.segments.map {
                SyncSegment(speaker: $0.speaker, start: $0.start, text: $0.text)
            } ?? []
            let attendees: [SyncAttendee] = (event?.attendees ?? []).map {
                SyncAttendee(name: $0.name ?? "Unknown", status: statusString($0.participantStatus))
            }
            let inviteNotes = event?.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SyncMeeting(
                key: key,
                title: title,
                start: start,
                end: end,
                calendarColor: event?.calendar?.color.map(hexString),
                calendarTitle: event?.calendar?.title,
                client: event.flatMap { EventWatcher.clientDomain(of: $0) },
                location: (event?.location?.isEmpty == false) ? event?.location : nil,
                organizer: event?.organizer?.name,
                attendees: attendees,
                inviteNotes: (inviteNotes?.isEmpty == false) ? inviteNotes : nil,
                tags: store.tags(for: key),
                attendance: store.attendance(for: key)?.rawValue,
                entries: entries,
                transcript: transcript
            )
        }
        .sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }

        return SyncBundle(generatedAt: Date(), meetings: meetings)
    }

    private static func statusString(_ status: EKParticipantStatus) -> String {
        switch status {
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        default: return "unknown"
        }
    }

    private static func hexString(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// occurrenceKey is "id|startInterval|endInterval" — recover the dates.
    private static func parseDates(from key: String, fallbackEnd: Date?) -> (Date?, Date?) {
        let parts = key.split(separator: "|")
        if parts.count >= 3,
           let s = Double(parts[parts.count - 2]),
           let e = Double(parts[parts.count - 1]) {
            return (Date(timeIntervalSince1970: s), Date(timeIntervalSince1970: e))
        }
        return (nil, fallbackEnd)
    }
}
