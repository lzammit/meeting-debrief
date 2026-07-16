# Architecture

MeetingDebrief is a single-process SwiftUI + AppKit macOS app, built with Swift
Package Manager (no Xcode project). It has no backend — all state is the macOS
Calendar (read via EventKit) plus plain files in `~/Documents/MeetingDebrief/`.

This document explains how the pieces fit together and, more usefully, **why**
several non-obvious choices were made — most of them the result of hitting a
macOS constraint the hard way.

---

## High-level shape

```
                    ┌──────────────────────────────────────────┐
                    │            MeetingDebriefApp               │
                    │  Window + MenuBarExtra + Settings scenes   │
                    └───────────────┬────────────────────────────┘
                                    │ @EnvironmentObject
        ┌───────────────────────────┼───────────────────────────┐
        ▼                           ▼                           ▼
  EventWatcher              DebriefStore               RecordingManager
  (calendar source)         (notes/tags/               (capture +
                             attendance)                orchestration)
        │                           │                           │
        │ reads                     │ persists                  │ writes
        ▼                           ▼                           ▼
   EKEventStore          ~/Documents/MeetingDebrief/     recordings/*.m4a
   (macOS Calendar)      *.json + *.md                          │
                                                                ▼
                                                          Transcriber
                                                    (SpeechAnalyzer / SFSpeech)
                                                                │
                                                                ▼
                                          AppleSummarizer / ClaudeSummarizer
```

The three `ObservableObject`s (`EventWatcher`, `DebriefStore`,
`RecordingManager`) are created once in `MeetingDebriefApp` and injected as
environment objects. The UI observes them; there is no other global state.

---

## Module map

| File | Responsibility |
|------|----------------|
| `MeetingDebriefApp.swift` | `@main` App. Declares the three scenes (main **Window**, **MenuBarExtra**, **Settings**), the `AppDelegate` (accessory activation policy, keep-running-when-window-closed, emergency stop on quit), and wires up the environment objects. |
| `MainWindow.swift` | The bulk of the UI. `MainWindowView` (sidebar list with grouping, search, attendance/tag filters, sort order, NOW/NEXT highlight, toolbar, navigation split view), `MeetingRow` (one sidebar row), and `MeetingDetailView` (header, attendance control, tags, debrief entries, Previous meetings, transcript, summarize buttons). |
| `EventWatcher.swift` | The calendar source of truth. `@MainActor ObservableObject` wrapping `EKEventStore`: loads events for the configured window, reacts to change notifications + a 5-minute poll + a midnight reload, merges duplicate bookings, detects the client domain, finds related past meetings, and schedules the end-of-meeting popups and auto-recordings. |
| `DebriefStore.swift` | Persistence for everything the user captures: debrief entries (`entries.json`), attendance (`attendance.json`), tags (`tags.json`). Publishes them for the UI. `DebriefEntry` / `ClientAttendance` models live here. |
| `DebriefPanel.swift` | The floating end-of-meeting popup. `DebriefPanelController` manages a borderless `NSPanel`; `DebriefView` is its SwiftUI content (choice → editor → saved states, Snooze menu, attendance control). Also defines `NoteKind` and the shared `AttendanceControl`. |
| `MeetingRecorder.swift` | `RecordingManager` (`@MainActor`) orchestrates capture: mic via `MicCapture`, system audio via `SystemAudioTapCapture` (CoreAudio) or `SystemAudioCapture` (ScreenCaptureKit), multi-part recordings, the "recording already exists" conflict dialog, and kicking off transcription on stop. |
| `Transcriber.swift` | On-device speech-to-text. Prefers macOS 26 `SpeechAnalyzer`/`SpeechTranscriber` (long-form), falls back to `SFSpeechRecognizer`. Stitches multi-part recordings into one timeline, labels Me/Them by source stream, and removes mic-bleed duplicates. |
| `AppleSummarizer.swift` | Summaries via Apple Foundation Models (on-device). Chunks long transcripts and recursively reduces the notes to fit the small context window. |
| `ClaudeSummarizer.swift` | Summaries via the Claude API (`claude-opus-4-8`). Contains `KeychainHelper` for API-key storage. |
| `NotesStore.swift` | The shared folder path and the human-readable per-day markdown export. |
| `SettingsView.swift` | The SwiftUI **Settings** scene: Claude API key, meeting-list window, client-detection domains, and recording options. |

---

## Data flow

### Calendar → list
`EventWatcher.reload()` queries `EKEventStore` for events in
`[now - pastWindow, now + 7d]`, filters out all-day / cancelled / declined,
runs duplicate merging, and publishes `events`. `MainWindowView` groups them by
day and applies the search/filter/sort UI state. The list refreshes on three
triggers: the `EKEventStoreChanged` notification, a 5-minute poll (which also
calls `refreshSourcesIfNecessary()` to force an Exchange re-sync), and a
midnight reload to roll the day windows.

### Meeting ends → popup
During `reload()`, `EventWatcher` schedules a `Timer` at each of today's
meetings' end times. When it fires, the meeting is enqueued in a single-panel
queue (`DebriefPanelController`) so overlapping meetings prompt one at a time.
Saving an entry calls `DebriefStore.add(...)`, which appends to `entries.json`
**and** the daily markdown, then the UI reactively updates.

### Recording → transcript → summary
If auto-record is on (and it's a weekday, if that option is set),
`RecordingManager.startRecording` fires at the meeting's start. It writes
`mic.m4a` (+ `system.m4a` if system audio is available) into
`recordings/<occurrenceKey>/`. On stop, `Transcriber.transcribeFolder` runs,
writing `transcript.json`. The detail view then offers the two summarizers,
which write their output back through `DebriefStore` as ordinary entries.

### Identity keys
Every meeting occurrence is identified by a stable `occurrenceKey` =
`eventIdentifier | startTimeInterval | endTimeInterval`. This survives restarts,
distinguishes occurrences of a recurring meeting, and is the folder name for
recordings and the key for notes/tags/attendance.

---

## Design decisions & hard-won lessons

These are the choices that aren't obvious from the code, usually because they
work around a macOS behavior.

### Calendar via EventKit, not Microsoft Graph
Reading the macOS Calendar covers Exchange/Outlook/iCloud/Google in one API
with zero OAuth, zero server, and zero admin consent. A direct Graph/Entra
integration was considered and rejected: corporate tenants frequently block
third-party app consent, and it would add a backend. The tradeoff is that the
calendar must be synced to macOS (Internet Accounts) — which is a user-level
setting, not an admin one.

### Permissions & code signing
macOS binds TCC permissions (Calendar, Microphone, Screen & System Audio
Recording) to the app's **code signature**. An ad-hoc signature (`codesign -s -`)
is regenerated on every build, so each rebuild looks like a different app and
macOS silently drops the previously-granted permissions. **`build.sh` signs with
an Apple Development identity when one exists**, giving a stable identity so
grants persist. This single fact caused a long chain of "permission mysteriously
stopped working" symptoms before it was understood.

Auto-record deliberately never triggers the screen-recording re-approval dialog
at launch — it pre-checks `CGPreflightScreenCaptureAccess()` and falls back to
mic-only rather than ambushing the user with a system prompt at login. The
dialog only appears when the user manually starts a recording.

### System audio: ScreenCaptureKit by default, not a CoreAudio tap
A CoreAudio process tap (the approach Hyprnote uses) needs only the "System
Audio Recording Only" permission and avoids the periodic screen-recording
re-approval nag — attractive on paper. But inserting a tap into each app's
output path **breaks conference apps' echo cancellation**: on live Webex/Teams
calls the far end hears you "from far away." ScreenCaptureKit observes the final
mixed output without touching any app's audio path, so it's the default. The tap
remains available as an opt-in for anyone who wants it.

### Microphone: inert by default, echo-cancellation optional
Apple's voice-processing audio unit cleanly removes speaker bleed from the mic —
but it **ducks system volume** while active and **conflicts with Teams'** own
audio processing (again, "you sound far away"). So the default mic path is a
plain `AVAudioRecorder` that inserts nothing. Speaker bleed into the "Me" stream
is instead removed *after the fact* in `Transcriber`: sentences that appear in
both the mic and system streams at the same timestamp are dropped from "Me".
Echo cancellation is a Settings toggle for people who prefer it and don't mind
the volume dip.

### Me / Them labeling is by stream, not voice recognition
"Me" = the mic stream, "Them" = the system-audio stream. There's no speaker
diarization — telling Igor from Fabrice would require voice enrollment. Stream
separation gives clean two-party labels for free, which covers the debrief use
case. (Per-person attribution is a noted future direction, e.g. via FluidAudio.)

### Transcription: SpeechAnalyzer, not SFSpeechRecognizer
The legacy `SFSpeechRecognizer` file API is designed for ~1-minute clips and
**silently returns nothing** on longer recordings — it looked like "no speech
detected" on a perfectly good 28-minute file. macOS 26's `SpeechAnalyzer` /
`SpeechTranscriber` is built for long-form audio and needs no speech-recognition
permission. The old API is kept only as a pre-macOS-26 fallback.

### Summaries: on-device first, Claude optional
Apple Foundation Models run locally with no key and no network, but have a small
(~4K token) context window — hence `AppleSummarizer` chunks the transcript and
recursively reduces the per-chunk notes until they fit. Claude
(`claude-opus-4-8`) is higher quality for long/nuanced meetings and is the only
path that sends data off-device; it's opt-in per click, keyed from the Keychain.
Both are prompted to output a summary **and** suggested next steps, split into
separate debrief entries.

### Duplicate-booking merge
A common pattern: block your own time ("Trinseo - PF") *and* receive the real
Webex invite ("Trinseo Web auth on wired cisco"). `EventWatcher.mergeDuplicates`
collapses time-overlapping, name/domain-related events into one, keeping the
entry with the most attendees (the real invite) as the face. This happens at the
data layer so the list, popups, auto-record, and note counts all see one
meeting.

### Client detection & history ranking
The client is the most frequent **external** attendee email domain (internal
domains — yours, plus infrastructure like `webex.com` — are excluded; the list
is configurable in Settings). A domain appearing across a large fraction of all
meetings is treated as a colleague/vendor domain, not a client, so it can't
falsely link unrelated meetings. "Previous meetings" ranks candidates by shared
tag (strongest, user-asserted) → shared client domain → title similarity.

---

## Storage format

`~/Documents/MeetingDebrief/`:

- `entries.json` — array of `DebriefEntry { occurrenceKey, eventTitle, kind, text, createdAt }`. Source of truth.
- `attendance.json` — `{ occurrenceKey: "showed" | "noShow" }`.
- `tags.json` — `{ occurrenceKey: [tag, ...] }`.
- `YYYY-MM-DD.md` — human-readable export, appended on each save.
- `recordings/<occurrenceKey>/mic.m4a`, `system.m4a` (+ `-2`, `-3`… for resumed parts), `transcript.json`.

JSON is the source of truth; the markdown is a convenience export (greppable,
Obsidian-friendly). Deleting the JSON loses data; deleting the markdown doesn't.

---

## Build & tooling

- `build.sh` — `swift build -c release`, assembles the `.app` bundle, copies
  `Info.plist` + `assets/AppIcon.icns`, and code-signs (dev identity if present).
- `tools/make-icon.swift` — draws the 1024px icon master with AppKit; the
  `.icns` is compiled from it with `sips` + `iconutil`.
- `tools/*.swift` — standalone diagnostic scripts written during development
  (Apple Intelligence availability, transcription, mic capture). Kept for
  re-checking after macOS/policy updates; not part of the app.

---

## Known limitations / future directions

- **No per-person diarization** — everyone on the far side is "Them".
- **Multi-part recording timestamps** use audio duration, not wall-clock, so a
  long gap between resumed parts is compressed in the transcript timeline (order
  is always correct).
- **On-device summary quality** on long, multi-topic meetings is below Claude's;
  an Ollama-backed local option is a candidate if Apple's model proves too thin.
- **Voice/hotkey stop** for recording was scoped but not built.
- **A local MCP server** over the notes folder (ask Claude "what were my next
  steps from last week?") is a natural follow-on given the plain-file storage.
