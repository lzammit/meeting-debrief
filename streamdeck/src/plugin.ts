import { execFile } from "node:child_process";
import { readFileSync, watch, type FSWatcher } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import streamDeck, { action, type KeyDownEvent, SingletonAction, type WillAppearEvent } from "@elgato/streamdeck";

import { idleKey, noticeKey, offKey, recordingKey } from "./render.ts";

/** Mirrors RemoteControl.StateFile in the app. */
type AppState = {
	recording: boolean;
	title?: string;
	startedAt?: number;
	systemAudioOK: boolean;
	lastError?: string;
	lastErrorAt?: number;
	pid: number;
	appPath: string;
	updatedAt: number;
};

const STATE_DIR = join(homedir(), "Library", "Application Support", "MeetingDebrief");
const STATE_FILE = join(STATE_DIR, "recording-state.json");
const TOGGLE_URL = "meetingdebrief://record/toggle";
const NOTICE_MS = 3000;

let lastReadError = "";

function readState(): AppState | undefined {
	try {
		return JSON.parse(readFileSync(STATE_FILE, "utf8")) as AppState;
	} catch (e) {
		const msg = (e as Error).message;
		if (msg !== lastReadError) streamDeck.logger.warn(`cannot read ${STATE_FILE}: ${msg}`);
		lastReadError = msg;
		return undefined;
	}
}

function isAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (e) {
		// EPERM still means the process exists; only ESRCH means it's gone.
		return (e as NodeJS.ErrnoException).code === "EPERM";
	}
}

@action({ UUID: "com.meetingdebrief.record.toggle" })
class RecordToggle extends SingletonAction {
	private state: AppState | undefined;
	private running = false;
	private notice: { message: string; until: number } | undefined;
	private pressedAt = 0;
	private watcher: FSWatcher | undefined;
	private ticker: NodeJS.Timeout | undefined;

	override onWillAppear(_ev: WillAppearEvent): void {
		this.lastFace = "";
		this.startWatching();
		this.refresh();
	}

	override onKeyDown(ev: KeyDownEvent): void {
		this.pressedAt = Date.now() / 1000;
		// Send the URL to the copy that is running (dist/ build or /Applications).
		// Nothing running: let LaunchServices launch the app for the scheme.
		const args = this.running && this.state ? ["-g", "-a", this.state.appPath, TOGGLE_URL] : ["-g", TOGGLE_URL];
		execFile("/usr/bin/open", args, (err) => {
			if (err) {
				streamDeck.logger.error(`open failed: ${err.message}`);
				void ev.action.showAlert();
			}
		});
	}

	private startWatching(): void {
		if (this.watcher) return;
		// Watch the folder, not the file: the app replaces it atomically.
		try {
			this.watcher = watch(STATE_DIR, (_e, name) => {
				if (name === "recording-state.json") this.refresh();
			});
		} catch (e) {
			streamDeck.logger.warn(`cannot watch ${STATE_DIR}: ${(e as Error).message}`);
		}
		// Once a second: the timer face, plus catching an app that quit or crashed.
		this.ticker = setInterval(() => this.refresh(), 1000);
	}

	private refresh(): void {
		this.state = readState();
		const s = this.state;
		this.running = !!s && isAlive(s.pid);
		if (s?.lastError && (s.lastErrorAt ?? 0) >= this.pressedAt - 1 && this.pressedAt > 0) {
			this.pressedAt = 0;
			this.notice = { message: s.lastError === "no-meeting" ? "No meeting now" : s.lastError, until: Date.now() + NOTICE_MS };
			for (const a of this.actions) if (a.isKey()) void a.showAlert();
		}
		void this.redraw();
	}

	private face(): string {
		if (this.notice && Date.now() < this.notice.until) return noticeKey(this.notice.message);
		this.notice = undefined;
		const s = this.state;
		if (!s || !this.running) return offKey();
		if (s.recording && s.startedAt) return recordingKey(Date.now() - s.startedAt * 1000, s.title ?? "Recording", !s.systemAudioOK);
		return idleKey();
	}

	private lastFace = "";

	private async redraw(): Promise<void> {
		const image = this.face();
		if (image === this.lastFace) return;
		this.lastFace = image;
		for (const a of this.actions) {
			if (!a.isKey()) continue;
			await a.setImage(image);
			await a.setTitle("");
		}
	}
}

streamDeck.logger.setLevel("info");
streamDeck.actions.registerAction(new RecordToggle());
streamDeck.connect();
