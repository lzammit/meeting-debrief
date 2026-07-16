import Foundation
@preconcurrency import EventKit
import AppKit

enum AuthorizationState {
    case pending
    case granted
    case denied
}

/// Stable identifier for one occurrence of an event (recurring meetings get
/// one key per occurrence). Shared by the watcher, the popup, and the store.
func occurrenceKey(for event: EKEvent) -> String {
    let id = event.eventIdentifier ?? event.title ?? "unknown"
    return "\(id)|\(event.startDate.timeIntervalSince1970)|\(event.endDate.timeIntervalSince1970)"
}

/// Watches calendar events (all calendars visible to macOS Calendar,
/// including Exchange/Outlook accounts) and fires the debrief popup when an
/// event ends. Also publishes a two-week window of events for the browser UI.
@MainActor
final class EventWatcher: ObservableObject {
    static let shared = EventWatcher()

    struct DuplicateAlias: Hashable {
        let key: String
        let title: String
    }

    @Published var authorization: AuthorizationState = .pending
    /// Configurable past window (default one month) through the next 7 days,
    /// sorted by start date. Duplicate bookings of the same real meeting
    /// (personal time-blocker + actual invite) are merged; see `duplicateAliases`.
    @Published var events: [EKEvent] = []
    /// Primary occurrence key → the duplicate events it absorbed.
    @Published var duplicateAliases: [String: [DuplicateAlias]] = [:]

    /// Events still in progress or upcoming today (for the menu bar).
    var todaysRemaining: [EKEvent] {
        let now = Date()
        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 3600)
        return events.filter { $0.endDate > now && $0.startDate < endOfDay }
    }

    private let store = EKEventStore()
    private var timers: [Timer] = []
    /// Periodic full refresh — kept separate from `timers`, which reload()
    /// rebuilds every pass.
    private var periodicRefreshTimer: Timer?
    private var pendingPrompts: [(key: String, title: String, endDate: Date)] = []
    private var panelVisible = false

    /// Events that ended no more than this long ago still get a popup on
    /// launch/reload, so a meeting that just finished isn't silently missed.
    private let recentlyEndedGrace: TimeInterval = 10 * 60

    private let promptedDefaultsKey = "promptedOccurrences"

    func start() {
        if DemoData.isEnabled {
            let events = DemoData.buildAndSeed(store: store)
            DebriefStore.shared.reload()
            self.events = events.sorted { $0.startDate < $1.startDate }
            authorization = .granted
            return
        }
        Task {
            do {
                let granted = try await store.requestFullAccessToEvents()
                authorization = granted ? .granted : .denied
            } catch {
                authorization = .denied
            }
            guard authorization == .granted else { return }

            NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: store, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            }
            scheduleMidnightReload()
            schedulePeriodicRefresh()
            reload()
        }
    }

    /// The EKEventStoreChanged notification isn't always delivered (e.g.
    /// deletions synced from Exchange), so also re-pull the calendar every
    /// 5 minutes.
    private func schedulePeriodicRefresh() {
        periodicRefreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.store.refreshSourcesIfNecessary()
                self?.reload()
            }
        }
        timer.tolerance = 30
        periodicRefreshTimer = timer
    }

    // MARK: - Event loading & scheduling

    private func reload() {
        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        // How far back the meeting list reaches is a user setting
        // (default: one month).
        var pastDays = UserDefaults.standard.integer(forKey: "pastWindowDays")
        if pastDays <= 0 { pastDays = 30 }
        let rangeStart = calendar.date(byAdding: .day, value: -pastDays, to: startOfDay)!
        let rangeEnd = calendar.date(byAdding: .day, value: 8, to: startOfDay)!
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = store.predicateForEvents(withStart: rangeStart, end: rangeEnd, calendars: nil)
        let loaded = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && !isDeclined($0) }
            .sorted { $0.startDate < $1.startDate }

        let merged = Self.mergeDuplicates(loaded)
        events = merged.primaries
        duplicateAliases = merged.aliases

        timers.forEach { $0.invalidate() }
        timers = []
        pruneOldPromptedRecords()

        // Popups and recordings only for events ending today — and only for
        // merged primaries, so a blocker + invite pair prompts once.
        var autoRecord = UserDefaults.standard.bool(forKey: "autoRecordMeetings")
        if autoRecord,
           UserDefaults.standard.bool(forKey: "autoRecordWeekdaysOnly"),
           calendar.isDateInWeekend(now) {
            autoRecord = false
        }
        for event in merged.primaries where event.endDate <= endOfToday && event.endDate > startOfDay {
            let key = occurrenceKey(for: event)
            let recTitle = event.title ?? "Untitled event"
            if autoRecord {
                let startDate = event.startDate!
                if startDate > now {
                    let timer = Timer(fire: startDate, interval: 0, repeats: false) { _ in
                        Task { @MainActor in
                            await RecordingManager.shared.startRecording(occurrenceKey: key, title: recTitle)
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    timers.append(timer)
                } else if event.endDate > now, !RecordingManager.shared.isRecording {
                    // Meeting already in progress (app launch or toggle flipped mid-meeting).
                    Task { @MainActor in
                        await RecordingManager.shared.startRecording(occurrenceKey: key, title: recTitle)
                    }
                }
            }

            guard !wasPrompted(key) else { continue }

            let title = recTitle
            let endDate = event.endDate!
            if endDate > now {
                let timer = Timer(fire: endDate, interval: 0, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.fire(key: key, title: title, endDate: endDate) }
                }
                RunLoop.main.add(timer, forMode: .common)
                timers.append(timer)
            } else if now.timeIntervalSince(endDate) < recentlyEndedGrace {
                fire(key: key, title: title, endDate: endDate)
            }
        }
    }

    private func isDeclined(_ event: EKEvent) -> Bool {
        guard let attendees = event.attendees else { return false }
        return attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined }
    }

    /// Re-evaluate schedules after a settings change (e.g. auto-record toggled).
    func refresh() {
        guard authorization == .granted else { return }
        store.refreshSourcesIfNecessary()
        reload()
    }

    /// Domains that identify us (or meeting infrastructure) rather than a
    /// client. Built-ins plus the user-configured list from Settings;
    /// matching includes subdomains (webex.com also covers
    /// akamai.calendar.webex.com).
    private nonisolated static var internalDomainEntries: Set<String> {
        var entries: Set<String> = ["akamai.com", "webex.com", "webex.bot"]
        let stored = UserDefaults.standard.string(forKey: "internalDomains") ?? ""
        for raw in stored.lowercased().components(separatedBy: CharacterSet(charactersIn: ", ;")) {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            if !entry.isEmpty { entries.insert(entry) }
        }
        return entries
    }

    private nonisolated static func isInternalDomain(_ domain: String) -> Bool {
        internalDomainEntries.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// External (non-Akamai) email domains of an event's attendees.
    nonisolated static func externalDomains(of event: EKEvent) -> Set<String> {
        guard let attendees = event.attendees else { return [] }
        var domains: Set<String> = []
        for attendee in attendees where attendee.participantType == .person {
            let urlString = attendee.url.absoluteString
            let email = urlString.hasPrefix("mailto:") ? String(urlString.dropFirst(7)) : urlString
            guard let at = email.lastIndex(of: "@") else { continue }
            let domain = String(email[email.index(after: at)...]).lowercased()
            if !domain.isEmpty, !isInternalDomain(domain) {
                domains.insert(domain)
            }
        }
        return domains
    }

    /// The client a meeting belongs to: the most frequent external attendee
    /// domain, or nil for internal meetings.
    nonisolated static func clientDomain(of event: EKEvent) -> String? {
        if DemoData.isEnabled { return DemoData.client(for: event) }
        guard let attendees = event.attendees else { return nil }
        var counts: [String: Int] = [:]
        for attendee in attendees where attendee.participantType == .person {
            let urlString = attendee.url.absoluteString
            let email = urlString.hasPrefix("mailto:") ? String(urlString.dropFirst(7)) : urlString
            guard let at = email.lastIndex(of: "@") else { continue }
            let domain = String(email[email.index(after: at)...]).lowercased()
            if !domain.isEmpty, !isInternalDomain(domain) {
                counts[domain, default: 0] += 1
            }
        }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    struct PastMeeting: Hashable {
        let event: EKEvent
        let aliases: [DuplicateAlias]

        /// The primary key plus absorbed duplicates' keys — notes under any
        /// of them belong to this meeting.
        var allKeys: [String] {
            [occurrenceKey(for: event)] + aliases.map(\.key)
        }
    }

    /// Past meetings (last `monthsBack` months) related to the given event,
    /// ranked by signal strength: shared user tag (client name) first, then
    /// shared external attendee domain, then title similarity. Double-booked
    /// pairs (blocker + invite) are consolidated before ranking.
    func pastSimilarEvents(
        to event: EKEvent,
        tagsForKey: (String) -> [String],
        monthsBack: Int = 3,
        limit: Int = 5
    ) -> [PastMeeting] {
        guard authorization == .granted else { return [] }
        guard let rangeStart = Calendar.current.date(byAdding: .month, value: -monthsBack, to: event.startDate) else { return [] }

        let predicate = store.predicateForEvents(withStart: rangeStart, end: event.startDate, calendars: nil)
        let currentKey = occurrenceKey(for: event)
        let currentTags = Set(tagsForKey(currentKey).map { $0.lowercased() })
        var clientDomains = Self.externalDomains(of: event)
        let title = event.title ?? ""

        let candidates = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
        let merged = Self.mergeDuplicates(candidates)

        // A domain present across a large share of ALL meetings is a
        // teammate/vendor domain, not a client — drop it from the match set
        // so it can't link unrelated meetings.
        if !clientDomains.isEmpty, merged.primaries.count >= 6 {
            let total = Double(merged.primaries.count)
            for domain in clientDomains {
                let hits = merged.primaries.filter { Self.externalDomains(of: $0).contains(domain) }.count
                if Double(hits) / total > 0.4 {
                    clientDomains.remove(domain)
                }
            }
        }

        let scored: [(meeting: PastMeeting, score: Int)] = merged.primaries
            .compactMap { candidate in
                let candidateKey = occurrenceKey(for: candidate)
                guard candidateKey != currentKey else { return nil }
                // A booking that overlaps the current meeting in time is the
                // current meeting's own duplicate, not history.
                guard candidate.endDate <= event.startDate
                    || candidate.startDate >= event.endDate else { return nil }

                let meeting = PastMeeting(event: candidate, aliases: merged.aliases[candidateKey] ?? [])

                if !currentTags.isEmpty {
                    let candidateTags = Set(meeting.allKeys.flatMap { tagsForKey($0) }.map { $0.lowercased() })
                    if !candidateTags.isDisjoint(with: currentTags) {
                        return (meeting, 3)
                    }
                }
                if !clientDomains.isEmpty,
                   !Self.externalDomains(of: candidate).isDisjoint(with: clientDomains) {
                    return (meeting, 2)
                }
                if Self.titlesAreSimilar(candidate.title ?? "", title) {
                    return (meeting, 1)
                }
                return nil
            }

        return Array(
            scored
                .sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.meeting.event.startDate > $1.meeting.event.startDate
                }
                .prefix(limit)
                .map(\.meeting)
        )
    }

    /// Collapse duplicate bookings of the same real meeting: events that
    /// overlap in time AND look related (similar title or shared external
    /// attendee domain) — e.g. a personal "Trinseo - PF" time-blocker plus
    /// the actual "Trinseo Web auth on wired cisco" Webex invite. The event
    /// with the most attendees (the real invite) becomes the primary.
    nonisolated static func mergeDuplicates(
        _ sortedEvents: [EKEvent]
    ) -> (primaries: [EKEvent], aliases: [String: [DuplicateAlias]]) {
        var groups: [[EKEvent]] = []
        for event in sortedEvents {
            if let index = groups.firstIndex(where: { group in
                group.contains { other in
                    event.startDate < other.endDate
                        && event.endDate > other.startDate
                        && areRelated(event, other)
                }
            }) {
                groups[index].append(event)
            } else {
                groups.append([event])
            }
        }

        var primaries: [EKEvent] = []
        var aliases: [String: [DuplicateAlias]] = [:]
        for group in groups {
            var primary = group[0]
            for candidate in group.dropFirst()
            where (candidate.attendees?.count ?? 0) > (primary.attendees?.count ?? 0) {
                primary = candidate
            }
            primaries.append(primary)
            let absorbed = group
                .filter { $0 !== primary }
                .map { DuplicateAlias(key: occurrenceKey(for: $0), title: $0.title ?? "Untitled") }
            if !absorbed.isEmpty {
                aliases[occurrenceKey(for: primary)] = absorbed
            }
        }
        primaries.sort { $0.startDate < $1.startDate }
        return (primaries, aliases)
    }

    private nonisolated static func areRelated(_ a: EKEvent, _ b: EKEvent) -> Bool {
        if titlesAreSimilar(a.title ?? "", b.title ?? "") { return true }
        let domainsA = externalDomains(of: a)
        guard !domainsA.isEmpty else { return false }
        return !domainsA.isDisjoint(with: externalDomains(of: b))
    }

    /// Word-overlap similarity: at least 60% of the shorter title's
    /// significant words appear in the other title.
    private nonisolated static func titlesAreSimilar(_ a: String, _ b: String) -> Bool {
        let tokensA = titleTokens(a)
        let tokensB = titleTokens(b)
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return false }
        let overlap = tokensA.intersection(tokensB).count
        return Double(overlap) / Double(min(tokensA.count, tokensB.count)) >= 0.6
    }

    private nonisolated static func titleTokens(_ title: String) -> Set<String> {
        Set(
            title.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        )
    }

    private func fire(key: String, title: String, endDate: Date) {
        RecordingManager.shared.stopIfRecording(matching: key)
        guard !wasPrompted(key) else { return }
        markPrompted(key)
        enqueuePrompt(key: key, title: title, endDate: endDate)
    }

    private func scheduleMidnightReload() {
        let nextMidnight = Calendar.current.nextDate(
            after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 5),
            matchingPolicy: .nextTime
        )!
        let timer = Timer(fire: nextMidnight, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
                self?.scheduleMidnightReload()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    // MARK: - Popup queue (one panel at a time)

    func showTestPopup() {
        enqueuePrompt(key: "test|\(UUID().uuidString)", title: "Test meeting", endDate: Date())
    }

    private func enqueuePrompt(key: String, title: String, endDate: Date) {
        pendingPrompts.append((key, title, endDate))
        showNextPromptIfIdle()
    }

    private func showNextPromptIfIdle() {
        guard !panelVisible, !pendingPrompts.isEmpty else { return }
        let prompt = pendingPrompts.removeFirst()
        panelVisible = true
        DebriefPanelController.shared.show(
            occurrenceKey: prompt.key, eventTitle: prompt.title, eventEnd: prompt.endDate,
            onDismiss: { [weak self] in
                Task { @MainActor in
                    self?.panelVisible = false
                    self?.showNextPromptIfIdle()
                }
            },
            onSnooze: { [weak self] interval in
                Task { @MainActor in
                    self?.panelVisible = false
                    self?.scheduleSnooze(prompt, after: interval)
                    self?.showNextPromptIfIdle()
                }
            }
        )
    }

    /// Snooze timers live outside `timers` so a calendar-change reload
    /// doesn't cancel a pending snooze.
    private func scheduleSnooze(_ prompt: (key: String, title: String, endDate: Date), after interval: TimeInterval) {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.enqueuePrompt(key: prompt.key, title: prompt.title, endDate: prompt.endDate)
            }
        }
    }

    // MARK: - Prompted-occurrence bookkeeping (survives restarts)

    private func promptedRecords() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: promptedDefaultsKey) as? [String: Double]) ?? [:]
    }

    private func wasPrompted(_ key: String) -> Bool {
        promptedRecords()[key] != nil
    }

    private func markPrompted(_ key: String) {
        var records = promptedRecords()
        records[key] = Date().timeIntervalSince1970
        UserDefaults.standard.set(records, forKey: promptedDefaultsKey)
    }

    private func pruneOldPromptedRecords() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970
        let records = promptedRecords().filter { $0.value > cutoff }
        UserDefaults.standard.set(records, forKey: promptedDefaultsKey)
    }
}
