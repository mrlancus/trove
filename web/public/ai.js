// The website's AI and looking-back UI (ROADMAP §4 A1-A3): Ask Trove, AI on a note, the AI
// settings with this month's use, link suggestions, the weekly digest, "on this day" and possible
// duplicates. Cloud features are hidden (the `ai-on` class is off) unless the relay says AI is on.
// ctx: { openItem(id), toast(text), syncSoon(), flush() } from app.js.
import { h } from "./dom.js";
import { icon } from "./icons.js";
import { renderMarkdown } from "./markdown.js";
import { AiError, aiStatus, askTrove, autoDigest, lastAiStatus, makeDigest, onAiStatus, pageAction, PAGE_ACTIONS, saveAnswer, saveFlashcards,
  setCloudAI, TEXT_ACTIONS, textAction } from "./aiactions.js";
import { digestId, isoWeek, onThisDay, possibleDuplicates, previousWeek } from "./core/digest.js";
import { suggestLinks } from "./core/suggest.js";

const number = new Intl.NumberFormat();

/** Checks the relay once and keeps `html.ai-on` in step; makes last week's digest if it's due. */
export function initAi(vault, ctx) {
  onAiStatus((s) => document.documentElement.classList.toggle("ai-on", Boolean(s?.enabled)));
  aiStatus(vault).catch(() => {});
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") aiStatus(vault).catch(() => {}); });
}

let digestChecked = false;
/** Call after a sync: once per page load, writes last week's digest if no device has yet. */
export async function afterSync(vault, ctx) {
  if (digestChecked) return;
  digestChecked = true;
  try { if (await autoDigest(vault)) ctx.syncSoon(); } catch { /* next time */ }
}

function dialog(title, ...content) {
  const onKey = (e) => { if (e.key === "Escape") close(); };
  const close = () => { backdrop.remove(); document.removeEventListener("keydown", onKey); };
  document.addEventListener("keydown", onKey);
  const id = `d-${Math.random().toString(36).slice(2)}`;
  const box = h("div", { class: "dialog ai-dialog", role: "dialog", "aria-modal": "true", "aria-labelledby": id },
    h("div", { class: "dialog-head" }, h("h2", { id, text: title }), h("button", { type: "button", class: "icon-button", "aria-label": "Close", onclick: () => close() }, icon("close"))),
    ...content);
  const backdrop = h("div", { class: "dialog-backdrop", onclick: (e) => { if (e.target === backdrop) close(); } }, box);
  document.body.append(backdrop);
  return { box, close };
}

const cloudLabel = (model) => h("p", { class: "ai-label", text: `Processed in the cloud${model ? ` by ${model}` : ""}, through your relay. Nothing is kept there.` });
const errorText = (e) => (e instanceof AiError ? e.message : "Something went wrong. Try again.");
const markdown = (text) => { const el = h("div", { class: "preview ai-result" }); el.innerHTML = renderMarkdown(text ?? ""); return el; }; // escaped by renderMarkdown

// ---------- Ask Trove ----------

export function showAsk(vault, ctx) {
  const input = h("textarea", { rows: 2, placeholder: "What did I save about…", "aria-label": "Your question", maxlength: 2000 });
  const go = h("button", { type: "submit", class: "primary" }, "Ask");
  const out = h("div", { class: "ask-out", "aria-live": "polite" });
  const form = h("form", { class: "ask-form" }, input, go);
  const { close } = dialog("Ask Trove",
    h("p", { class: "hint", text: "Trove finds the best matches on this device, then sends just those snippets and your question to Claude." }),
    form, out);
  input.addEventListener("keydown", (e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); form.requestSubmit(); } });
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const question = input.value.trim();
    if (!question) return;
    go.disabled = true;
    out.replaceChildren(h("p", { class: "hint", text: "Thinking…" }));
    try {
      const result = await askTrove(vault, question);
      if (!result.sources.length) { out.replaceChildren(h("p", { text: "Nothing in your vault matches that. Try other words." })); return; }
      const open = (id) => { close(); ctx.openItem(id); };
      out.replaceChildren(markdown(result.answer),
        result.cited.length ? h("div", { class: "link-group" }, h("span", { class: "link-label", text: "Sources" }),
          h("div", { class: "link-chips" }, result.cited.map((i) => h("span", { class: "link-chip" },
            h("a", { href: "#", onclick: (ev) => { ev.preventDefault(); open(i.id); } }, i.displayTitle))))) : null,
        h("div", { class: "row" }, h("button", { type: "button", class: "secondary", onclick: (ev) => {
          ev.target.disabled = true;
          const id = saveAnswer(vault, question, result);
          ctx.syncSoon();
          ctx.toast("Saved as a note");
          open(id);
        } }, "Save as note")),
        cloudLabel(result.model));
    } catch (err) {
      out.replaceChildren(h("p", { class: "error", role: "alert", text: errorText(err) }));
    } finally { go.disabled = false; }
  });
  input.focus();
}

// ---------- AI on a note ----------

/** The "AI" menu for a note's text (hidden by CSS while AI is off). */
export function noteAiMenu(item, vault, ctx) {
  const result = h("div", { class: "ai-note-result", hidden: true });
  const menu = h("details", { class: "ai-menu ai-only" }, h("summary", { class: "secondary small" }, "AI"),
    h("div", { class: "ai-menu-items" }, [...TEXT_ACTIONS, { id: "flashcards", label: "Make flashcards" }].map((a) =>
      h("button", { type: "button", class: "link-button", onclick: () => { menu.open = false; run(a.id); } }, a.label))));
  async function run(action) {
    ctx.flush();
    const text = vault.item(item.id)?.body ?? "";
    if (!text.trim()) { ctx.toast("Write something first"); return; }
    let language;
    if (action === "translate") {
      language = prompt("Translate into which language?", "French")?.trim();
      if (!language) return;
    }
    result.hidden = false;
    result.replaceChildren(h("p", { class: "hint", text: "Working…" }));
    try {
      const out = await textAction(vault, action, text, { language });
      if (action === "flashcards") {
        const id = saveFlashcards(vault, { cards: out.cards, title: `Flashcards: ${item.displayTitle}`, from: vault.item(item.id), model: out.model });
        ctx.syncSoon();
        result.hidden = true;
        ctx.toast(`Made ${out.cards.length} flashcards`);
        ctx.openItem(id);
        return;
      }
      const apply = (body) => { vault.setBody(item.id, body); ctx.syncSoon(); result.hidden = true; ctx.toast("Done. History has the old version."); };
      result.replaceChildren(markdown(out.text), h("div", { class: "row" },
        action === "continue" ? null : h("button", { type: "button", class: "primary small", onclick: () => apply(out.text) }, "Replace"),
        h("button", { type: "button", class: action === "continue" ? "primary small" : "secondary small", onclick: () => apply(`${(vault.item(item.id)?.body ?? text).trimEnd()}\n\n${out.text}`) }, action === "continue" ? "Add to the note" : "Add below"),
        h("button", { type: "button", class: "secondary small", onclick: () => navigator.clipboard?.writeText(out.text).then(() => ctx.toast("Copied")) }, "Copy"),
        h("button", { type: "button", class: "secondary small", onclick: () => { result.hidden = true; } }, "Discard")), cloudLabel(out.model));
    } catch (err) {
      result.replaceChildren(h("p", { class: "error", role: "alert", text: errorText(err) }));
    }
  }
  return h("div", { class: "ai-note" }, menu, result);
}

/**
 * The drawing editor's hook: runs a picture action on a PNG of a page or lasso selection and shows
 * the result, with "Save as note" (or the flashcards saved as a note). `from` is the sketch item.
 */
export async function runPageAction(vault, ctx, action, image, { from = null } = {}) {
  const label = PAGE_ACTIONS.find((a) => a.id === action)?.label ?? "AI";
  const out = h("div", { "aria-live": "polite" }, h("p", { class: "hint", text: "Working…" }));
  const { close } = dialog(label, out);
  try {
    const r = await pageAction(vault, action, image);
    if (action === "flashcards") {
      const id = saveFlashcards(vault, { cards: r.cards, title: `Flashcards: ${from?.displayTitle ?? "Sketch"}`, from, model: r.model });
      ctx.syncSoon();
      out.replaceChildren(h("p", { text: `Made ${r.cards.length} flashcards and saved them as a note.` }),
        h("div", { class: "row" }, h("button", { type: "button", class: "primary", onclick: () => { close(); ctx.openItem(id); } }, "Open them")), cloudLabel(r.model));
      return r;
    }
    out.replaceChildren(markdown(r.text), h("div", { class: "row" },
      h("button", { type: "button", class: "primary", onclick: () => {
        const id = vault.addNote({ title: `${label}: ${from?.displayTitle ?? "Sketch"}`, body: `${r.text}\n\n_Made in the cloud${r.model ? ` (${r.model})` : ""}._` });
        vault.update(id, { ai: { where: "cloud", model: r.model ?? "" }, needsEnrichment: false });
        if (from) vault.connect(id, from.id);
        ctx.syncSoon(); close(); ctx.openItem(id);
      } }, "Save as note"),
      h("button", { type: "button", class: "secondary", onclick: () => navigator.clipboard?.writeText(r.text).then(() => ctx.toast("Copied")) }, "Copy")), cloudLabel(r.model));
    return r;
  } catch (err) {
    out.replaceChildren(h("p", { class: "error", role: "alert", text: errorText(err) }));
    return null;
  }
}

// ---------- Suggest links (no AI) ----------

/** A "Suggest links" button that lists likely [[links]] with one-tap Connect; works offline. */
export function suggestLinksButton(item, vault, ctx) {
  const list = h("div", { class: "link-chips", hidden: true });
  const button = h("button", { type: "button", class: "link-button", onclick: () => {
    const found = suggestLinks(vault.item(item.id) ?? item, vault.items());
    list.hidden = false;
    list.replaceChildren(...(found.length ? found.map(({ item: o, reason }) => h("span", { class: "link-chip", title: reason },
      h("a", { href: "#", onclick: (e) => { e.preventDefault(); ctx.flush(); ctx.openItem(o.id); } }, o.displayTitle),
      h("button", { type: "button", class: "chip-action", onclick: (e) => {
        vault.connect(item.id, o.id); ctx.syncSoon(); e.target.closest(".link-chip").remove(); ctx.toast(`Connected to “${o.displayTitle}”`);
      } }, "Connect"))) : [h("span", { class: "hint", text: "No suggestions yet." })]));
  } }, "Suggest links");
  return h("div", { class: "link-group suggest-links" }, button, list);
}

// ---------- AI settings ----------

export function showAiSettings(vault, ctx) {
  const body = h("div", { class: "ai-settings" }, h("p", { class: "hint", text: "Checking your relay…" }));
  dialog("AI", body,
    h("section", {}, h("h3", { class: "section-title", text: "Works without cloud AI" }),
      h("p", { class: "hint", text: "Search, link suggestions, the weekly digest, “on this day” and possible duplicates all run on this device, for free." })));
  const render = (s) => {
    if (!s.configured) {
      body.replaceChildren(h("p", { text: "Cloud AI is off." }),
        h("p", { class: "hint", text: "It needs an Anthropic API key on your relay, which Anthropic bills for. Until then nothing is sent anywhere, and Ask Trove and the AI menus stay hidden. The relay's README explains how to add one and set a monthly cap." }));
      return;
    }
    const pct = s.limit ? Math.min(100, Math.round((s.used / s.limit) * 100)) : 0;
    const toggle = h("input", { type: "checkbox", checked: s.vaultEnabled, onchange: async (e) => {
      e.target.disabled = true;
      try { render(await setCloudAI(vault, e.target.checked)); ctx.toast(e.target.checked ? "Cloud AI on" : "Cloud AI off"); } catch { ctx.toast("Couldn't change that. Try again."); render(lastAiStatus() ?? s); }
    } });
    body.replaceChildren(
      h("label", { class: "check" }, toggle, "Use cloud AI (Claude) for this vault"),
      h("p", { class: "hint", text: "Ask Trove, AI on notes and sketches, and summaries send the text or picture you choose to Claude through your relay. Results are labelled “processed in the cloud”. Nothing is kept on the relay." }),
      h("section", {}, h("h3", { class: "section-title", text: "This month" }),
        h("div", { class: "meter", role: "meter", "aria-valuemin": "0", "aria-valuemax": String(s.limit), "aria-valuenow": String(s.used), "aria-label": "Cloud AI used this month" },
          h("span", { style: `width: ${pct}%` })),
        h("p", { class: "hint", id: "ai-usage", text: `${number.format(s.used)} of ${number.format(s.limit)} tokens used (${pct}%). Starts again on ${new Date(s.resetsAt).toLocaleDateString(undefined, { day: "numeric", month: "long" })}.` }),
        h("p", { class: "hint", text: `Model: ${s.model}` })));
  };
  aiStatus(vault, { fresh: true }).then(render);
}

// ---------- Looking back: digest, on this day, duplicates ----------

export function showReview(vault, ctx) {
  const open = (id) => { close(); ctx.openItem(id); };
  const items = vault.items();
  const byId = new Map(items.map((i) => [i.id, i]));
  const now = Date.now();
  const thisWeek = isoWeek(now), lastWeek = previousWeek(now);
  const make = async (week, button) => {
    button.disabled = true;
    try { const id = await makeDigest(vault, week); ctx.syncSoon(); open(id); } finally { button.disabled = false; }
  };
  const lastId = digestId(lastWeek.year, lastWeek.week);
  const digest = h("section", {}, h("h3", { class: "section-title", text: "Weekly digest" }),
    h("p", { class: "hint", text: "A note of what you saved, what you wrote and what you haven't opened. Trove makes last week's for you on Mondays." }),
    h("div", { class: "row" },
      h("button", { type: "button", class: "primary", onclick: (e) => make(thisWeek, e.target) }, "Make this week's digest"),
      byId.has(lastId) ? h("button", { type: "button", class: "secondary", onclick: () => open(lastId) }, "Open last week's")
        : h("button", { type: "button", class: "secondary", onclick: (e) => make(lastWeek, e.target) }, "Make last week's")));
  const day = onThisDay(items, now).slice(0, 20);
  const onDay = h("section", {}, h("h3", { class: "section-title", text: "On this day" }),
    day.length ? h("ul", { class: "review-list" }, day.map((i) => h("li", {}, h("a", { href: "#", onclick: (e) => { e.preventDefault(); open(i.id); } }, i.displayTitle),
      h("span", { class: "saved", text: ` ${new Date(i.createdAt).getUTCFullYear()}` })))) : h("p", { class: "hint", text: "Nothing saved on this date in earlier years." }));
  const dupes = h("section", {}, h("h3", { class: "section-title", text: "Possible duplicates" }));
  const renderDupes = () => {
    const groups = possibleDuplicates(vault.items()).slice(0, 30);
    dupes.replaceChildren(dupes.firstChild, groups.length ? h("ul", { class: "review-list" }, groups.map((g) => h("li", { class: "dupe" },
      h("span", { class: "saved", text: g.reason === "same link" ? "Same link" : g.reason === "same title" ? "Same title" : "Similar title" }),
      g.ids.map((id) => vault.item(id)).filter(Boolean).map((i) => h("a", { href: "#", class: "dupe-item", onclick: (e) => { e.preventDefault(); open(i.id); } }, i.displayTitle)),
      h("button", { type: "button", class: "secondary small", onclick: () => {
        // Remember on each item that the others aren't copies of it.
        for (const id of g.ids) {
          const it = vault.item(id);
          const prev = Array.isArray(it?.record.fields.notDuplicates) ? it.record.fields.notDuplicates : [];
          vault.update(id, { notDuplicates: [...new Set([...prev, ...g.ids.filter((x) => x !== id)])].sort() });
        }
        ctx.syncSoon(); renderDupes();
      } }, "Not duplicates")))) : h("p", { class: "hint", text: "None found." }));
  };
  renderDupes();
  const { close } = dialog("Look back", digest, onDay, dupes);
}
