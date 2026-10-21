// Ask Trove's retrieval (ROADMAP §4 A1): find the items that best answer a question with the local
// search, then cut each to the passage that matters. Only these snippets leave the device, and only
// when the user asks with cloud AI on. Uses the public `search(items, query)` and `terms(text)` only.
import { search, terms } from "./items.js";

/** Words that make a question a question but say nothing about what to look for. */
const QUESTION_WORDS = new Set(["what", "which", "who", "whom", "whose", "when", "where", "why", "how", "did", "do", "does",
  "can", "could", "should", "would", "about", "any", "some", "there", "anything", "something", "tell", "show", "find", "give",
  "list", "know", "save", "saved", "wrote", "write", "written", "note", "notes", "thing", "things", "trove", "ive", "im", "us",
  "our", "all", "much", "many", "been", "had", "get", "got", "ever", "last", "please"]);

/** The search words of a question, most specific last (order kept, no repeats). */
export function questionTerms(question) {
  const out = [];
  for (const t of terms(String(question ?? ""))) if (!QUESTION_WORDS.has(t) && !out.includes(t)) out.push(t);
  return out;
}

/** Text the snippet can come from, best parts first. */
function textOf(item) {
  return [item.summary, item.body, item.ocrText, item.sketchText, item.inkText].filter((t) => typeof t === "string" && t.trim()).join("\n\n");
}

/**
 * The window of `text` (up to `max` characters, cut at line or sentence ends where possible) that
 * holds the most question words; the start of the text when nothing matches.
 */
export function bestPassage(text, words, max = 1200) {
  const clean = String(text ?? "").replace(/\r\n?/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  if (clean.length <= max) return clean;
  // Pieces: lines, and long lines split into sentences; `sep` is what joins a piece to the one before.
  const pieces = [];
  for (const line of clean.split("\n")) {
    if (line.length <= max / 2) { pieces.push({ text: line, sep: "\n" }); continue; }
    (line.match(/[^.!?]+[.!?]*\s*/g) ?? [line]).forEach((s, i) => pieces.push({ text: s.slice(0, max), sep: i ? "" : "\n" }));
  }
  const wanted = [...new Set(words)];
  const hits = pieces.map((p) => terms(p.text).filter((t) => wanted.some((w) => t === w || (w.length >= 4 && t.startsWith(w)))).length);
  const take = (start) => {
    let len = 0, score = 0, end = start;
    while (end < pieces.length && len + pieces[end].text.length + 1 <= max) { len += pieces[end].text.length + 1; score += hits[end]; end++; }
    return { score, end };
  };
  let best = 0, bestScore = -1;
  for (let start = 0; start < pieces.length; start++) {
    const { score } = take(start);
    if (score > bestScore) { bestScore = score; best = start; } // ties keep the earlier window
  }
  // Start just before the first matching piece rather than far ahead of it.
  const first = hits.findIndex((n, i) => i >= best && n > 0);
  if (first > best + 1) best = first - 1;
  const { end } = take(best);
  const body = pieces.slice(best, end).map((p, i) => (i ? p.sep : "") + p.text).join("").trim();
  return `${best > 0 ? "… " : ""}${body}${end < pieces.length ? " …" : ""}`;
}

/**
 * Ranks items for a question: everything matching all its words first, then any of them (each
 * word searched on its own, ranks fused), so a chatty question still finds things.
 */
export function rankForQuestion(items, question, limit = 20) {
  const words = questionTerms(question);
  if (!words.length) return [];
  const scores = new Map();
  const add = (hits, weight) => hits.slice(0, 60).forEach((item, rank) => {
    const s = scores.get(item.id) ?? { item, score: 0, words: 0 };
    s.score += weight / (10 + rank);
    if (weight < 2) s.words++;
    scores.set(item.id, s);
  });
  if (words.length > 1) add(search(items, words.join(" ")), 3);
  for (const w of words) add(search(items, w), 1);
  return [...scores.values()]
    .sort((a, b) => b.score - a.score || b.words - a.words || b.item.createdAt - a.item.createdAt)
    .slice(0, limit)
    .map((s) => s.item);
}

/**
 * The sources to send for a question: `[{id, title, text, item}]`, at most `limit` items, each
 * snippet at most `snippetChars`, all of them at most `totalChars` (well under the relay's limits).
 */
export function askSources(items, question, { limit = 20, snippetChars = 1200, totalChars = 24_000 } = {}) {
  const words = questionTerms(question);
  const out = [];
  let budget = totalChars;
  for (const item of rankForQuestion(items, question, limit)) {
    const head = [`Title: ${item.displayTitle}`, item.url ? `Link: ${item.url.toString()}` : "",
      item.createdAt ? `Saved: ${new Date(item.createdAt).toISOString().slice(0, 10)}` : "", `Type: ${item.kind}`].filter(Boolean).join("\n");
    const room = Math.min(snippetChars, budget) - head.length - 5; // the whole snippet, "… " marks included, fits
    if (room < 80) break;
    const text = `${head}\n${bestPassage(textOf(item), words, room)}`.trim();
    budget -= text.length;
    out.push({ id: item.id, title: item.displayTitle, text, item });
  }
  return out;
}

/** A title made safe to put inside [[ ]]. */
export const linkTitle = (title) => String(title ?? "").replace(/[[\]|#\n]/g, " ").replace(/\s+/g, " ").trim();

/**
 * An answer as a note: the question as the title, the answer, then its sources as [[links]].
 * `cited` are items; `model` labels where it ran.
 */
export function answerNote(question, answer, cited, { model = "", where = "cloud" } = {}) {
  const q = String(question ?? "").trim();
  const title = q.length > 80 ? `${q.slice(0, 79)}…` : q;
  const lines = [String(answer ?? "").trim(), ""];
  const sources = cited.map((i) => linkTitle(i.displayTitle)).filter(Boolean);
  if (sources.length) lines.push("Sources:", ...sources.map((t) => `- [[${t}]]`), "");
  lines.push(`_Answered by Ask Trove (${where === "cloud" ? "processed in the cloud" : "on this device"}${model ? `, ${model}` : ""})._`);
  return { title: title || "Ask Trove", body: lines.join("\n") };
}
