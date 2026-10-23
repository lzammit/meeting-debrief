# MeetingDebrief Stream Deck key

One key that records the meeting you're in, and stops the recording when you press it again.

## How it works

The app listens for `meetingdebrief://record/toggle` (also `record/start` and `record/stop`). Toggle stops the running recording. If nothing is recording, it starts one for the meeting in progress right now. When meetings overlap, it picks the one that started last. If no meeting is on right now, nothing happens and the key flashes "No meeting now" for a few seconds.

The app writes its recording state to `~/Library/Application Support/MeetingDebrief/recording-state.json` every time it changes. The plugin watches that file, so the key also follows recordings you start or stop from the app itself, or that auto-record starts.

Key faces:

- mic + "Record": app running, nothing recording
- red with a timer and the meeting title: recording
- amber triangle in the corner while recording: only your mic is captured, the other participants are not (system audio approval missing)
- grey mic + "App closed": MeetingDebrief isn't running. A press launches it, but the calendar may not be loaded yet, so press again if it says "No meeting now".

You can also do it by hand, from any folder:

```bash
open -g meetingdebrief://record/toggle
```

## Build and install

From `~/meeting-debrief/streamdeck`:

```bash
npm install
npm run build
npx streamdeck link com.meetingdebrief.record.sdPlugin
```

Then quit and reopen the Stream Deck app (a newly linked plugin only loads at startup) and drag **Record / stop** from the **MeetingDebrief** category onto a key.

After a code change, `npm run build` then `npx streamdeck restart com.meetingdebrief.record`.
