/**
 * Key faces, drawn as 144x144 SVG (the @2x size of a Stream Deck MK.2 key).
 * Same palette as the Kimai Deck keys: idle stays dark, recording turns red.
 */

const SANS = "-apple-system, 'SF Pro Display', 'Helvetica Neue', Arial, sans-serif";
const MONO = "'SF Mono', Menlo, Monaco, monospace";
const REC = "#D92D20";
const WARN = "#F5A524";
const INK = "#F4F4F5";
const DIM = "#8E8E96";
const BG = "#16161A";

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

const svg = (body: string, bg = BG) =>
	"data:image/svg+xml;charset=utf8," +
	encodeURIComponent(
		`<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144"><rect width="144" height="144" fill="${bg}"/>${body}</svg>`,
	);

const text = (s: string, y: number, size: number, opts: { fill?: string; weight?: number; font?: string } = {}) =>
	`<text x="72" y="${y}" text-anchor="middle" font-family="${opts.font ?? SANS}" font-size="${size}" font-weight="${opts.weight ?? 500}" fill="${opts.fill ?? INK}">${esc(s)}</text>`;

const mic = (cx: number, cy: number, scale: number, stroke: string) =>
	`<g transform="translate(${cx} ${cy}) scale(${scale})" stroke="${stroke}" stroke-width="3.4" stroke-linecap="round" fill="none">` +
	`<rect x="-9" y="-22" width="18" height="30" rx="9"/><path d="M-16 0 a16 16 0 0 0 32 0"/><path d="M0 16 v8"/></g>`;

/** Splits a label over at most two lines of roughly `width` characters, ellipsing the rest. */
function wrap(label: string, width = 13): string[] {
	const words = label.split(/\s+/).filter(Boolean);
	const lines: string[] = [];
	let line = "";
	for (const w of words) {
		if (!line) line = w;
		else if ((line + " " + w).length <= width) line += " " + w;
		else {
			lines.push(line);
			line = w;
		}
	}
	if (line) lines.push(line);
	const clip = (s: string) => (s.length > width ? s.slice(0, width - 1) + "…" : s);
	if (lines.length > 2) lines[1] = lines[1] + "…";
	return lines.slice(0, 2).map(clip);
}

/** m:ss under an hour, h:mm:ss after. */
export function elapsed(ms: number): string {
	const secs = Math.max(0, Math.floor(ms / 1000));
	const h = Math.floor(secs / 3600);
	const m = Math.floor((secs % 3600) / 60);
	const s = String(secs % 60).padStart(2, "0");
	return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`;
}

export function idleKey(): string {
	return svg(mic(72, 62, 1.5, INK) + text("Record", 122, 19, { fill: DIM }));
}

/** App not running: the key still works (a press launches it), so it only dims. */
export function offKey(): string {
	return svg(mic(72, 62, 1.5, "#52525B") + text("App closed", 122, 17, { fill: DIM }));
}

/** Recording: red key, white light, timer, meeting title. A mic-only recording gets an amber badge. */
export function recordingKey(ms: number, title: string, micOnly: boolean): string {
	const time = elapsed(ms);
	const lines = wrap(title);
	const timeY = lines.length > 1 ? 70 : 78;
	const badge = micOnly
		? `<path d="M122 12 l14 24 h-28 z" fill="${WARN}"/><rect x="120.5" y="20" width="3" height="9" rx="1.5" fill="#16161A"/><circle cx="122" cy="32" r="1.8" fill="#16161A"/>`
		: "";
	return svg(
		`<circle cx="22" cy="22" r="7" fill="#FFFFFF"/>` +
			badge +
			text(time, timeY, time.length > 5 ? 34 : 44, { weight: 700, font: MONO }) +
			lines.map((l, i) => text(l, timeY + 32 + i * 21, 17, { fill: "rgba(255,255,255,0.88)" })).join(""),
		REC,
	);
}

/** Shown for a few seconds when a press found no meeting to record. */
export function noticeKey(message: string): string {
	const lines = wrap(message, 12);
	return svg(
		`<circle cx="72" cy="48" r="22" fill="none" stroke="${WARN}" stroke-width="5"/>` +
			`<rect x="69.5" y="35" width="5" height="17" rx="2.5" fill="${WARN}"/><circle cx="72" cy="60" r="3" fill="${WARN}"/>` +
			lines.map((l, i) => text(l, 100 + i * 21, 18)).join(""),
		"#232327",
	);
}
