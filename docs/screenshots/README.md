# Screenshots

Generated from **demo mode** (fictional data — no real calendar or client
information). To regenerate:

```sh
./build.sh
MEETINGDEBRIEF_DEMO=1 open -n dist/MeetingDebrief.app
```

Demo mode reads no real calendar and writes only to
`~/Documents/MeetingDebrief-Demo/`, which is safe to delete afterward.

Capture each window and save it here. Two ways:

- **To a file:** ⌘⇧4 then Space, click the window (saves to your Desktop), then
  move + rename it here.
- **Via clipboard:** ⌘⇧⌃4 then Space, click the window (copies to clipboard),
  then `./tools/save-clip.sh <name>` writes it straight to this folder.

Expected files:

- `main.png`       — main window, "Globex — Q3 Platform Review" selected
- `transcript.png` — same meeting scrolled to the transcript + summarize buttons
- `popup.png`      — the end-of-meeting debrief popup (menu bar → Test popup)
- `settings.png`   — the Settings window (⌘,)
