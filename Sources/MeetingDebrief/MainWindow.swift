import SwiftUI
@preconcurrency import EventKit

enum AttendanceFilter: String, CaseIterable {
    case all = "All"
    case showed = "Showed"
    case noShow = "No-show"
}

struct MainWindowView: View {
    @EnvironmentObject var watcher: EventWatcher
    @EnvironmentObject var store: DebriefStore
    @EnvironmentObject var recorder: RecordingManager
    @State private var selection: String?
    /// A meeting opened via "Previous meetings" that lies outside the loaded
    /// sidebar range.
    @State private var externalEvent: EKEvent?
    @State private var attendanceFilter: AttendanceFilter = .all
    @State private var tagFilter: String?
    @State private var searchText = ""
    /// Ticks every 30s so the "happening now" highlight tracks the clock.
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @AppStorage("showPastFirst") private var showPastFirst = false

    /// The meeting in progress right now, if any.
    private var currentKey: String? {
        watcher.events.first { $0.startDate <= now && $0.endDate > now }
            .map { occurrenceKey(for: $0) }
    }

    /// The next meeting starting after now — used to mark "NEXT" when no
    /// meeting is currently in progress, so there's always a "you are here".
    private var nextKey: String? {
        watcher.events
            .filter { $0.startDate > now }
            .min { $0.startDate < $1.startDate }
            .map { occurrenceKey(for: $0) }
    }

    private var filteredEvents: [EKEvent] {
        watcher.events.filter { event in
            let key = occurrenceKey(for: event)
            switch attendanceFilter {
            case .all: break
            case .showed: guard store.attendance(for: key) == .showed else { return false }
            case .noShow: guard store.attendance(for: key) == .noShow else { return false }
            }
            if let tagFilter {
                guard store.tags(for: key).contains(where: { $0.caseInsensitiveCompare(tagFilter) == .orderedSame }) else { return false }
            }
            let query = searchText.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                guard store.tags(for: key).contains(where: { $0.localizedCaseInsensitiveContains(query) }) else { return false }
            }
            return true
        }
    }

    private var autoRecordBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "autoRecordMeetings") },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: "autoRecordMeetings")
                watcher.refresh()
            }
        )
    }

    private var eventsByKey: [String: EKEvent] {
        Dictionary(watcher.events.map { (occurrenceKey(for: $0), $0) }) { first, _ in first }
    }

    /// Events grouped by day. Default order: today first, then future days
    /// ascending, then past days descending (most recent first). With
    /// "Past first" enabled, the past block moves above today/future.
    private var sections: [(day: Date, label: String, events: [EKEvent])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let grouped = Dictionary(grouping: filteredEvents) { calendar.startOfDay(for: $0.startDate) }
        let days = grouped.keys.sorted { a, b in
            let (da, db) = (a.timeIntervalSince(today), b.timeIntervalSince(today))
            if (da >= 0) != (db >= 0) { return da >= 0 }   // today/future before past
            return da >= 0 ? da < db : da > db
        }
        let ordered = showPastFirst
            ? days.filter { $0 < today } + days.filter { $0 >= today }
            : days
        return ordered.map { day in
            (day, Self.label(for: day, today: today), grouped[day]!.sorted { $0.startDate < $1.startDate })
        }
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if watcher.authorization == .denied {
                    ContentUnavailableView(
                        "Calendar access denied",
                        systemImage: "lock.circle",
                        description: Text("Enable full calendar access for MeetingDebrief in System Settings → Privacy & Security → Calendars.")
                    )
                } else if watcher.events.isEmpty {
                    ContentUnavailableView("No meetings", systemImage: "calendar", description: Text("No events in the past or next 7 days."))
                } else {
                    VStack(spacing: 0) {
                        Picker("Attendance filter", selection: $attendanceFilter) {
                            ForEach(AttendanceFilter.allCases, id: \.self) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)

                        if filteredEvents.isEmpty {
                            ContentUnavailableView(
                                "No matching meetings",
                                systemImage: "person.crop.circle.badge.questionmark",
                                description: Text("No meetings match the current search and filters.")
                            )
                        } else {
                            List(selection: Binding(
                                get: { selection },
                                set: { newValue in
                                    selection = newValue
                                    externalEvent = nil
                                }
                            )) {
                                ForEach(sections, id: \.day) { section in
                                    Section(section.label) {
                                        ForEach(section.events, id: \.self) { event in
                                            let key = occurrenceKey(for: event)
                                            MeetingRow(
                                                event: event,
                                                entryCount: combinedEntryCount(for: key),
                                                attendance: store.attendance(for: key),
                                                isRecording: recorder.isRecording(key),
                                                tags: store.tags(for: key),
                                                isCurrent: key == currentKey,
                                                isNext: currentKey == nil && key == nextKey
                                            )
                                            .tag(key)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search by tag")
            .searchSuggestions {
                ForEach(
                    store.allTags.filter {
                        searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText)
                    },
                    id: \.self
                ) { tag in
                    Label(tag, systemImage: "tag").searchCompletion(tag)
                }
            }
            .toolbar {
                ToolbarItem {
                    Picker("Order", selection: $showPastFirst) {
                        Label("Upcoming first", systemImage: "arrow.forward.circle").tag(false)
                        Label("Past first", systemImage: "arrow.backward.circle").tag(true)
                    }
                    .pickerStyle(.menu)
                    .help("Show upcoming or past meetings at the top of the list")
                }
                ToolbarItem {
                    Menu {
                        Button("All tags") { tagFilter = nil }
                        Divider()
                        ForEach(store.allTags, id: \.self) { tag in
                            Button(tag) { tagFilter = tag }
                        }
                    } label: {
                        Label(tagFilter ?? "Tag", systemImage: "tag")
                    }
                    .help("Filter meetings by tag")
                }
                ToolbarItem {
                    Toggle(isOn: autoRecordBinding) {
                        Label("Auto-record", systemImage: "record.circle")
                    }
                    .toggleStyle(.button)
                    .help("Automatically record and transcribe meetings (mic + system audio)")
                }
                ToolbarItem {
                    if case .recording(_, let title, _) = recorder.state {
                        Button {
                            recorder.stopRecording(manual: true)
                        } label: {
                            Label("Stop recording — \(title)", systemImage: "stop.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .help("Stop the current recording")
                    }
                }
            }
        } detail: {
            if let key = selection, let event = eventsByKey[key] {
                MeetingDetailView(event: event, occurrenceKey: key, onNavigate: navigate)
                    .id(key)
            } else if let externalEvent {
                MeetingDetailView(
                    event: externalEvent,
                    occurrenceKey: occurrenceKey(for: externalEvent),
                    onNavigate: navigate
                )
                .id(occurrenceKey(for: externalEvent))
            } else {
                ContentUnavailableView("Select a meeting", systemImage: "calendar.badge.checkmark", description: Text("Click a meeting to see its details and debrief notes."))
            }
        }
        .navigationTitle("MeetingDebrief")
        .onReceive(clock) { now = $0 }
    }

    /// Notes for a meeting plus any duplicate bookings merged into it.
    private func combinedEntryCount(for key: String) -> Int {
        let keys = [key] + (watcher.duplicateAliases[key] ?? []).map(\.key)
        return keys.reduce(0) { $0 + store.entries(for: $1).count }
    }

    /// Jump to another meeting — via the sidebar when it's in the loaded
    /// range, directly in the detail pane otherwise.
    private func navigate(to target: EKEvent) {
        let targetKey = occurrenceKey(for: target)
        if eventsByKey[targetKey] != nil {
            selection = targetKey
            externalEvent = nil
        } else {
            selection = nil
            externalEvent = target
        }
    }

    private static func label(for day: Date, today: Date) -> String {
        let calendar = Calendar.current
        let diff = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        switch diff {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default:
            if calendar.component(.year, from: day) != calendar.component(.year, from: today) {
                return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
            }
            return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }
}

struct MeetingRow: View {
    let event: EKEvent
    let entryCount: Int
    let attendance: ClientAttendance?
    var isRecording = false
    var tags: [String] = []
    var isCurrent = false
    var isNext = false

    private var highlighted: Bool { isCurrent || isNext }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: event.calendar?.color ?? .systemGray))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title ?? "Untitled")
                        .lineLimit(1)
                        .foregroundStyle(titleColor)
                        .fontWeight(highlighted || attendance != nil ? .medium : .regular)
                    if isCurrent {
                        Text("NOW")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor, in: Capsule())
                    } else if isNext {
                        Text("NEXT")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Capsule().stroke(Color.accentColor, lineWidth: 1))
                    }
                }
                Text(
                    "\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))"
                        + (tags.isEmpty ? "" : "  ·  \(tags.joined(separator: ", "))")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if isRecording {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                    .help("Recording in progress")
            }
            if entryCount > 0 {
                Image(systemName: "note.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("\(entryCount) debrief note\(entryCount == 1 ? "" : "s")")
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, highlighted ? 8 : 0)
        .background(
            isCurrent
                ? Color.accentColor.opacity(0.15)
                : (isNext ? Color.accentColor.opacity(0.06) : Color.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(alignment: .leading) {
            if highlighted {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isCurrent ? Color.accentColor : Color.accentColor.opacity(0.4))
                    .frame(width: 3)
            }
        }
    }

    private var titleColor: Color {
        switch attendance {
        case .noShow: return .red
        case .showed: return .green
        case nil: return .primary
        }
    }
}

struct MeetingDetailView: View {
    let event: EKEvent
    let occurrenceKey: String
    var onNavigate: ((EKEvent) -> Void)? = nil

    @EnvironmentObject var watcher: EventWatcher
    @EnvironmentObject var store: DebriefStore
    @EnvironmentObject var recorder: RecordingManager
    @State private var editingKind: NoteKind?
    @State private var draft = ""
    @State private var transcript: Transcript?
    @State private var pastSimilar: [EventWatcher.PastMeeting] = []
    @State private var newTag = ""
    @State private var generatingSummary = false
    @State private var summaryError: String?
    @State private var confirmClearSummaries = false
    @State private var confirmDeleteRecording = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                infoGrid
                if let notes = event.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    inviteNotes(notes)
                }
                Divider()
                debriefSection
                if !pastSimilar.isEmpty {
                    Divider()
                    previousMeetingsSection
                }
                Divider()
                transcriptSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(occurrenceKey)-\(recorder.transcriptRevision)-\(store.tags(for: occurrenceKey).joined(separator: "|"))") {
            transcript = Transcriber.loadTranscript(for: occurrenceKey)
            pastSimilar = watcher.pastSimilarEvents(to: event, tagsForKey: { store.tags(for: $0) })
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(event.title ?? "Untitled")
                .font(.title2.weight(.semibold))
            HStack(spacing: 10) {
                Label {
                    Text("\(event.startDate.formatted(date: .abbreviated, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))")
                } icon: {
                    Image(systemName: "clock")
                }
                Label {
                    Text(event.calendar?.title ?? "Unknown calendar")
                } icon: {
                    Circle()
                        .fill(Color(nsColor: event.calendar?.color ?? .systemGray))
                        .frame(width: 9, height: 9)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let aliases = watcher.duplicateAliases[occurrenceKey], !aliases.isEmpty {
                Label(
                    "Also booked as: \(aliases.map(\.title).joined(separator: ", "))",
                    systemImage: "rectangle.on.rectangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            AttendanceControl(selection: store.attendance(for: occurrenceKey)) { newValue in
                store.setAttendance(newValue, for: occurrenceKey)
            }
            .padding(.top, 4)
        }
    }

    /// This meeting's key plus the keys of duplicate bookings merged into it —
    /// notes captured under either belong to the same real meeting.
    private var allKeys: [String] {
        [occurrenceKey] + (watcher.duplicateAliases[occurrenceKey] ?? []).map(\.key)
    }

    private var allEntries: [DebriefEntry] {
        allKeys
            .flatMap { store.entries(for: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var infoGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let client = EventWatcher.clientDomain(of: event) {
                detailRow(icon: "building.2", title: "Client") {
                    Text(client)
                        .fontWeight(.medium)
                }
            }
            tagsRow
            if let location = event.location, !location.isEmpty {
                detailRow(icon: "mappin.and.ellipse", title: "Location") {
                    Text(location)
                }
            }
            if let organizer = event.organizer {
                detailRow(icon: "person.crop.circle", title: "Organizer") {
                    Text(organizer.name ?? "Unknown")
                }
            }
            if let attendees = event.attendees, !attendees.isEmpty {
                detailRow(icon: "person.2", title: "Attendees (\(attendees.count))") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(attendees.enumerated()), id: \.offset) { _, attendee in
                            HStack(spacing: 5) {
                                statusIcon(attendee.participantStatus)
                                Text(attendee.name ?? "Unknown")
                            }
                        }
                    }
                }
            }
        }
    }

    private var tagsRow: some View {
        detailRow(icon: "tag", title: "Tags") {
            VStack(alignment: .leading, spacing: 6) {
                let currentTags = store.tags(for: occurrenceKey)
                if !currentTags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(currentTags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag)
                                Button {
                                    store.removeTag(tag, from: occurrenceKey)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                }
                HStack(spacing: 6) {
                    TextField("Add tag", text: $newTag)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onSubmit {
                            store.addTag(newTag, to: occurrenceKey)
                            newTag = ""
                        }
                    let existing = store.allTags.filter { tag in
                        !currentTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
                    }
                    if !existing.isEmpty {
                        Menu {
                            ForEach(existing, id: \.self) { tag in
                                Button(tag) { store.addTag(tag, to: occurrenceKey) }
                            }
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .fixedSize()
                        .help("Add an existing tag")
                    }
                }
                let suggestions = tagSuggestions
                if !suggestions.isEmpty {
                    HStack(spacing: 6) {
                        Text("Suggested:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                store.addTag(suggestion, to: occurrenceKey)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    /// Tag suggestions: client-domain company name, the title's
    /// "Client - PF" prefix, and tags used on related past meetings.
    private var tagSuggestions: [String] {
        let currentTags = Set(store.tags(for: occurrenceKey).map { $0.lowercased() })
        var out: [String] = []
        func add(_ raw: String) {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard tag.count > 1,
                  !currentTags.contains(tag.lowercased()),
                  !out.contains(where: { $0.lowercased() == tag.lowercased() }) else { return }
            out.append(tag)
        }
        if let domain = EventWatcher.clientDomain(of: event) {
            add((domain.components(separatedBy: ".").first ?? domain).capitalized)
        }
        if let title = event.title {
            for separator in [" - ", " – ", " | "] {
                if let range = title.range(of: separator) {
                    add(String(title[..<range.lowerBound]))
                    break
                }
            }
        }
        for past in pastSimilar {
            for key in past.allKeys {
                for tag in store.tags(for: key) {
                    add(tag)
                }
            }
        }
        return Array(out.prefix(4))
    }

    private func detailRow(icon: String, title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                content()
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: EKParticipantStatus) -> some View {
        switch status {
        case .accepted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .declined:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .tentative:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
        default:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private func inviteNotes(_ notes: String) -> some View {
        detailRow(icon: "text.alignleft", title: "Invite notes") {
            Text(notes.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(12)
                .textSelection(.enabled)
        }
    }

    private var debriefSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Debrief")
                    .font(.headline)
                Spacer()
                if editingKind == nil {
                    Button("Add summary") { beginEditing(.summary) }
                    Button("Add next step") { beginEditing(.nextStep) }
                    if allEntries.contains(where: { $0.kind == .summary }) {
                        Button(role: .destructive) {
                            confirmClearSummaries = true
                        } label: {
                            Label("Clear summaries", systemImage: "trash")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete all summaries for this meeting?",
                isPresented: $confirmClearSummaries
            ) {
                Button("Delete summaries", role: .destructive) {
                    for key in allKeys {
                        store.deleteSummaries(for: key)
                    }
                }
            } message: {
                Text("Hand-written and AI-generated summaries are removed. Next-step entries are kept. This can't be undone.")
            }

            let entries = allEntries
            if entries.isEmpty && editingKind == nil {
                Text("Nothing captured for this meeting yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.kind.rawValue)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(entry.kind == .summary ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            store.delete(entry)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Delete this note")
                    }
                    Text(entry.text)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            if let kind = editingKind {
                VStack(alignment: .leading, spacing: 8) {
                    Text("New \(kind.rawValue.lowercased())")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $draft)
                        .font(.body)
                        .frame(minHeight: 100)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                        .focused($editorFocused)
                    HStack {
                        Button("Cancel") { editingKind = nil }
                        Spacer()
                        Button("Save") {
                            store.add(
                                kind: kind, text: draft, occurrenceKey: occurrenceKey,
                                eventTitle: event.title ?? "Untitled event", eventEnd: event.endDate
                            )
                            editingKind = nil
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var previousMeetingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Previous meetings (\(pastSimilar.count))")
                .font(.headline)

            ForEach(pastSimilar, id: \.self) { pastMeeting in
                let past = pastMeeting.event
                let entries = pastMeeting.allKeys
                    .flatMap { store.entries(for: $0) }
                    .sorted { $0.createdAt < $1.createdAt }
                let attendance = pastMeeting.allKeys.compactMap { store.attendance(for: $0) }.first
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button {
                            onNavigate?(past)
                        } label: {
                            HStack(spacing: 4) {
                                Text(past.title ?? "Untitled")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Open this meeting")
                        Text(past.startDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        switch attendance {
                        case .showed:
                            Text("Showed").font(.caption.weight(.semibold)).foregroundStyle(.green)
                        case .noShow:
                            Text("No-show").font(.caption.weight(.semibold)).foregroundStyle(.red)
                        case nil:
                            EmptyView()
                        }
                        Spacer()
                        if entries.isEmpty {
                            Text("No notes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.kind.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(entry.kind == .summary ? Color.blue : Color.orange)
                                .frame(width: 70, alignment: .trailing)
                            Text(entry.text)
                                .font(.callout)
                                .lineLimit(6)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript")
                    .font(.headline)
                Spacer()
                if RecordingManager.hasRecording(for: occurrenceKey) {
                    Button("Show audio in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [RecordingManager.recordingFolder(for: occurrenceKey)]
                        )
                    }
                    Button(role: .destructive) {
                        confirmDeleteRecording = true
                    } label: {
                        Label("Delete recording", systemImage: "trash")
                    }
                    .disabled(recorder.isRecording(occurrenceKey) || recorder.transcribingKeys.contains(occurrenceKey))
                }
            }
            .confirmationDialog(
                "Delete this meeting's recording?",
                isPresented: $confirmDeleteRecording
            ) {
                Button("Delete recording", role: .destructive) {
                    recorder.deleteRecording(occurrenceKey: occurrenceKey)
                    transcript = nil
                }
            } message: {
                Text("The audio files and the transcript are removed from disk. Saved summaries and notes are kept. This can't be undone.")
            }

            if recorder.isRecording(occurrenceKey) {
                HStack(spacing: 12) {
                    Label("Recording…", systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                    Button("Stop recording") {
                        recorder.stopRecording(manual: true)
                    }
                }
                if let micAudioError = recorder.micAudioError {
                    Text(micAudioError)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let systemAudioError = recorder.systemAudioError {
                    Text(systemAudioError)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if recorder.micAudioError == nil, recorder.systemAudioError == nil {
                    Text("Capturing your mic (echo-cancelled) and system audio — participants will be labeled “Them”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if recorder.transcribingKeys.contains(occurrenceKey) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing on-device…")
                        .foregroundStyle(.secondary)
                }
            } else if let transcript, !transcript.segments.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        generateSummary(transcript, engine: .apple)
                    } label: {
                        Label("Summarize (on-device)", systemImage: "sparkles")
                    }
                    .disabled(generatingSummary)
                    Button {
                        generateSummary(transcript, engine: .claude)
                    } label: {
                        Label("With Claude", systemImage: "cloud")
                    }
                    .disabled(generatingSummary)
                    if generatingSummary {
                        ProgressView().controlSize(.small)
                        Text("Summarizing…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let summaryError {
                    Text(summaryError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(transcript.segments) { segment in
                        HStack(alignment: .top, spacing: 8) {
                            Text(segment.speaker)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(segment.speaker == "Me" ? Color.blue : Color.purple)
                                .frame(width: 42, alignment: .trailing)
                            Text(Self.timeString(segment.start))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(segment.text)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } else if RecordingManager.hasRecording(for: occurrenceKey) {
                Button("Transcribe recording") {
                    Task { await recorder.transcribe(occurrenceKey: occurrenceKey) }
                }
                if let transcriptionError = recorder.transcriptionErrors[occurrenceKey] {
                    Text(transcriptionError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } else if !isInProgress {
                Text("No recording for this meeting. Enable “Auto-record meetings” in the menu bar to capture future ones.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Meeting still in progress: offer to (re)start recording, without
            // hiding any existing recording's transcript or transcribe button.
            if isInProgress, !recorder.isRecording {
                Button {
                    Task {
                        await recorder.startRecording(
                            occurrenceKey: occurrenceKey,
                            title: event.title ?? "Untitled event",
                            force: true,
                            interactive: true
                        )
                    }
                } label: {
                    Label(
                        RecordingManager.hasRecording(for: occurrenceKey)
                            ? "Record again…"
                            : "Record this meeting now",
                        systemImage: "record.circle"
                    )
                }
            }
        }
    }

    private enum SummaryEngine {
        case apple
        case claude
    }

    private func generateSummary(_ transcript: Transcript, engine: SummaryEngine) {
        generatingSummary = true
        summaryError = nil
        let title = event.title ?? "Untitled event"
        let end = event.endDate!
        let key = occurrenceKey
        Task {
            do {
                let text: String
                switch engine {
                case .apple:
                    guard #available(macOS 26.0, *) else {
                        throw AppleSummarizerError.unavailable("On-device summaries require macOS 26 — use the Claude button instead.")
                    }
                    text = try await AppleSummarizer.summarize(
                        transcript: transcript, eventTitle: title, eventEnd: end
                    )
                case .claude:
                    text = try await ClaudeSummarizer.summarize(
                        transcript: transcript, eventTitle: title, eventEnd: end
                    )
                }
                let (summaryText, nextSteps) = Self.splitSummaryAndNextSteps(text)
                store.add(kind: .summary, text: summaryText, occurrenceKey: key, eventTitle: title, eventEnd: end)
                if let nextSteps {
                    store.add(kind: .nextStep, text: nextSteps, occurrenceKey: key, eventTitle: title, eventEnd: end)
                }
            } catch {
                summaryError = error.localizedDescription
            }
            generatingSummary = false
        }
    }

    /// AI output carries a ===NEXT STEPS=== marker separating the summary
    /// from suggested next steps; split them into their two entry kinds.
    private static func splitSummaryAndNextSteps(_ text: String) -> (summary: String, nextSteps: String?) {
        guard let markerRange = text.range(of: "===NEXT STEPS===", options: .caseInsensitive) else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let summary = String(text[..<markerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nextSteps = String(text[markerRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = nextSteps.lowercased()
        if nextSteps.isEmpty || normalized == "none" || normalized.hasPrefix("none.") || normalized.hasPrefix("none\n") {
            return (summary, nil)
        }
        return (summary, nextSteps)
    }

    private var isInProgress: Bool {
        let now = Date()
        return event.startDate <= now && event.endDate > now
    }

    private static func timeString(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func beginEditing(_ kind: NoteKind) {
        draft = ""
        editingKind = kind
        DispatchQueue.main.async { editorFocused = true }
    }
}
