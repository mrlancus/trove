// Cloud AI for the website, as plain functions (ROADMAP §4 A1-A3). Everything here goes through the
// user's own relay, only when its AI is on (PROTOCOL.md §4 "AI"): a key on the relay and the vault's
// switch. Results are labelled "processed in the cloud". The UI lives in ai.js; the drawing editor
// calls `pageAction` with a PNG of a page or a lasso selection.
import { answerNote, askSources } from "./core/ask.js";
import { digestId, isoWeek, previousWeek, weeklyDigest } from "./core/digest.js";

export const TEXT_ACTIONS = [
  ["continue", "Continue writing"], ["shorter", "Make shorter"], ["clearer", "Make clearer"], ["grammar", "Fix spelling and grammar"],
  ["bullets", "Turn into bullet points"], ["translate", "Translate…"],
].map(([id, label]) => ({ id, label }));

export const PAGE_ACTIONS = [
  ["transcribe", "Convert handwriting to text"], ["summarise", "Summarise"], ["explain", "Explain"], ["solve", "Solve the maths"],
  ["flashcards", "Make flashcards"],
].map(([id, label]) => ({ id, label }));

export class AiError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

let status = null, statusAt = 0;
const listeners = new Set();

/** The relay's AI status (PROTOCOL.md §4): `{enabled, configured, vaultEnabled, model, used, limit, resetsAt}`. */
export async function aiStatus(vault, { fresh = false } = {}) {
  if (!fresh && status && Date.now() - statusAt < 10 * 60_000) return status;
  try {
    setStatus(await vault.api("GET", "ai/status"));
  } catch {
    // An older relay, or offline: treat AI as off, which hides it.
    if (!status) setStatus({ enabled: false, configured: false, vaultEnabled: false, used: 0, limit: 0, offline: true });
  }
  return status;
}

/** The last status seen, without asking the relay (null before the first check). */
export const lastAiStatus = () => status;
/** Called with the status whenever it changes (to show or hide AI features). */
export function onAiStatus(fn) { listeners.add(fn); return () => listeners.delete(fn); }

function setStatus(next) {
  status = next;
  statusAt = Date.now();
  for (const fn of listeners) { try { fn(status); } catch { /* a stale view */ } }
}

/** Turns cloud AI on or off for the vault (all devices). */
export async function setCloudAI(vault, on) {
  await vault.api("PUT", "settings", { body: { aiEnabled: Boolean(on) } });
  return aiStatus(vault, { fresh: true });
}

async function post(vault, path, body) {
  try {
    const out = await vault.api("POST", `ai/${path}`, { body });
    if (out?.usage) setStatus(out.usage);
    return out;
  } catch (e) {
    const status = e.status ?? 0;
    let message = e.message;
    const json = /\{.*\}$/s.exec(message);
    try { message = JSON.parse(json?.[0] ?? "").error ?? message; } catch { /* plain text */ }
    if (status === 429 || status === 403) aiStatus(vault, { fresh: true });
    if (status === 0 || /fetch|network/i.test(message)) message = "You're offline, or the relay can't be reached.";
    throw new AiError(status, message);
  }
}

/**
 * Runs an action on a note's text: `continue`, `shorter`, `clearer`, `grammar`, `bullets`,
 * `translate` (with `language`), `summarise`, `explain` or `flashcards`.
 * Resolves to `{text, cards, model}`.
 */
export async function textAction(vault, action, text, { language } = {}) {
  const out = await post(vault, "action", { action, text, ...(language ? { language } : {}) });
  return { text: out.text, cards: out.cards ?? [], model: out.model };
}

async function base64Of(image) {
  if (typeof image === "string") return image.replace(/^data:[^,]*,/, "");
  const bytes = new Uint8Array(await image.arrayBuffer());
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

/**
 * Runs an action on a picture of a page or a lasso selection (the drawing editor's hook):
 * `image` is a PNG/JPEG Blob or base64 (a data: URL is fine). `transcribe`, `summarise`, `explain`,
 * `solve` or `flashcards`. Resolves to `{text, cards, model}`. Pictures over ~3.5 MB are refused.
 */
export async function pageAction(vault, action, image, { mediaType } = {}) {
  const type = mediaType ?? (typeof image === "string" ? (/^data:([^;,]+)/.exec(image)?.[1] ?? "image/png") : image.type || "image/png");
  const out = await post(vault, "action", { action, image: await base64Of(image), mediaType: type });
  return { text: out.text, cards: out.cards ?? [], model: out.model };
}

/**
 * Ask Trove: the best ~20 snippets from this device's search go to Claude; the answer cites items.
 * Resolves to `{answer, cited: [item], sources, model}`; `sources` is empty when nothing matched (no call).
 */
export async function askTrove(vault, question, { items = vault.items() } = {}) {
  const sources = askSources(items, question);
  if (!sources.length) return { answer: "", cited: [], sources, model: "" };
  const out = await post(vault, "ask", { question, sources: sources.map(({ id, text }) => ({ id, text })) });
  const byId = new Map(sources.map((s) => [s.id, s.item]));
  return { answer: out.answer, cited: (out.citations ?? []).map((id) => byId.get(id)).filter(Boolean), sources, model: out.model };
}

const aiField = (model) => ({ ai: { where: "cloud", model: model ?? "" }, needsEnrichment: false });

/** Saves an Ask Trove answer as a note linking its sources; returns the note's id. */
export function saveAnswer(vault, question, { answer, cited, model }) {
  const { title, body } = answerNote(question, answer, cited, { model });
  const id = vault.addNote({ title, body, tags: ["ask-trove"] });
  vault.update(id, aiField(model));
  for (const item of cited) vault.connect(id, item.id);
  return id;
}

/**
 * Saves flashcards as a note (PROTOCOL.md §11): field `flashcards: [{front, back}]` for a study view,
 * and the same cards in the body so every app can read them. Returns the note's id.
 */
export function saveFlashcards(vault, { cards, title = "Flashcards", from = null, model }) {
  const clean = cards.filter((c) => c?.front && c?.back).map((c) => ({ front: String(c.front).trim(), back: String(c.back).trim() }));
  const lines = from ? [`Flashcards from [[${from.displayTitle.replace(/[[\]|#\n]/g, " ").trim()}]]`, ""] : [];
  for (const c of clean) lines.push(`**Q:** ${c.front}`, `**A:** ${c.back}`, "");
  lines.push(`_Made in the cloud${model ? ` (${model})` : ""}._`);
  const id = vault.addNote({ title, body: lines.join("\n"), tags: ["flashcards"] });
  vault.update(id, { flashcards: clean, ...aiField(model) });
  if (from) vault.connect(id, from.id);
  return id;
}

/**
 * Makes (or remakes) the digest note for ISO week `year`/`week` and returns its id. With cloud AI on
 * and `summary: true`, adds a short summary paragraph (labelled).
 */
export async function makeDigest(vault, { year, week } = isoWeek(Date.now()), { summary = true } = {}) {
  let digest = weeklyDigest(vault.items(), year, week);
  const ai = lastAiStatus();
  if (summary && ai?.enabled && (digest.counts.saved || digest.counts.written)) {
    try {
      const { text, model } = await textAction(vault, "summarise", `${digest.title}\n\n${digest.body}`);
      digest = weeklyDigest(vault.items(), year, week, { summary: text, model });
    } catch { /* the digest is fine without */ }
  }
  const id = digestId(year, week);
  if (vault.store.records.has(id)) {
    vault.update(id, { _deleted: false, title: digest.title });
    vault.setBody(id, digest.body);
  } else {
    vault.addNote({ id, title: digest.title, body: digest.body, tags: ["digest"] });
  }
  vault.update(id, { digest: { year, week }, needsEnrichment: false, ...(digest.body.includes("## In short") ? { ai: { where: "cloud", model: ai?.model ?? "" } } : {}) });
  return id;
}

/**
 * Once a week, the first device to open Trove writes last week's digest. The id is the same on every
 * device, so two devices doing it at once write the same item. A digest the user deleted stays deleted.
 * Returns the new id, or null when there was nothing to do.
 */
export async function autoDigest(vault, now = Date.now()) {
  const last = previousWeek(now);
  if (vault.store.records.has(digestId(last.year, last.week))) return null;
  const { counts } = weeklyDigest(vault.items(), last.year, last.week);
  if (!counts.saved && !counts.written) return null;
  return makeDigest(vault, last);
}
