// Features hidden from the website, not deleted (docs/plans/learn-pivot-plan.md §3; the apps' Features.swift).
// Constants, not settings: switching one back on is one line here. Tests turn them back on with the
// localStorage key `trove.features` set to "all" (or a comma list such as "graph,githubBridge"), so the code
// of hidden features keeps being tested.
const SHIPPED = {
  /** The Obsidian-style graph: Connections, the graph on items, the clipboard Map. Backlinks and [[links]] stay. */
  graph: false,
  /** The relay's GitHub stars bridge. */
  githubBridge: false,
  /** The relay's Telegram bot bridge. */
  telegramBridge: false,
};

function overrides() {
  try {
    const raw = globalThis.localStorage?.getItem("trove.features");
    return new Set(String(raw ?? "").split(",").map((s) => s.trim()).filter(Boolean));
  } catch { return new Set(); }
}

const on = overrides();
export const features = Object.freeze(Object.fromEntries(Object.entries(SHIPPED).map(([name, shipped]) =>
  [name, shipped || on.has("all") || on.has(name)])));
