# MeetingDebrief

This repo holds **two apps, maintained in separate Claude sessions**:

- **macOS app** — here (`Sources/`, `tools/`, `build.sh`). SwiftPM executable.
- **iPhone companion** — in `iOS/`, which has its own `CLAUDE.md`.

## Which app is this session about?

- **If your working directory is this repo root** → you're working on the **macOS app**.
  Do **not** edit anything under `iOS/` (that's a separate session).
- **If your working directory is `iOS/`** → ignore the rest of this file and follow
  `iOS/CLAUDE.md` instead.

## macOS app quick reference

- Build: `./build.sh` → `dist/MeetingDebrief.app` (Apple Development signing; ad-hoc breaks TCC grants).
- Key files: `Sources/MeetingDebrief/` — `MainWindow.swift`, `EventWatcher.swift`, `MeetingRecorder.swift`, `Transcriber.swift`, `DebriefStore.swift`, `DebriefSync.swift` (sync upload side), `SettingsView.swift`.
- Icon: `tools/make-icon.swift`.

## Shared sync contract

`DebriefSync.swift` builds the JSON bundle the iPhone reads; `iOS/MeetingDebriefApp/Models.swift`
mirrors it. If you change the bundle shape here, flag it so the iOS session updates `Models.swift`.
