// Modules the website needs only once something opens, loaded with import() so startup parses less.
// They're preloaded when the browser is idle, so opening a drawing rarely waits for them.
let draw = null, drawModule = null;

/** draw.js (the drawing editor, ~85 KB, plus pdfwrite.js). */
export function loadDraw() {
  draw ??= import("./draw.js").then((m) => (drawModule = m)).catch((e) => { draw = null; throw e; });
  return draw;
}

/** draw.js if it has loaded, else null (for code that must answer straight away). */
export const drawLoaded = () => drawModule;

export async function openInkEditor(options) { return (await loadDraw()).openInkEditor(options); }
export async function sketchThumbnail(...args) { return (await loadDraw()).sketchThumbnail(...args); }
export async function renderSketchPage(...args) { return (await loadDraw()).renderSketchPage(...args); }

/** Loads the deferred modules once the page has nothing else to do. */
export function preloadWhenIdle() {
  const idle = globalThis.requestIdleCallback ?? ((fn) => setTimeout(fn, 1500));
  idle(() => loadDraw().catch(() => {}), { timeout: 5000 });
}
