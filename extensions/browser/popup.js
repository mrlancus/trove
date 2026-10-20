const $ = (id) => document.getElementById(id);

const { setup } = await chrome.storage.local.get("setup");
if (!setup) {
  $("setup").hidden = false;
  $("open-options").onclick = () => chrome.runtime.openOptionsPage();
} else {
  $("ready").hidden = false;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const page = tab?.id ? await chrome.runtime.sendMessage({ type: "read-page", tabId: tab.id }) : {};
  const capture = { url: page.url || tab?.url, title: page.title || tab?.title, text: page.text, description: page.description };
  $("title").textContent = capture.title || "Untitled";
  try { $("host").textContent = new URL(capture.url).hostname.replace(/^www\./, ""); } catch { $("host").textContent = ""; }
  if (capture.text) {
    $("selection").hidden = false;
    $("selection").textContent = capture.text.length > 280 ? capture.text.slice(0, 280) + "…" : capture.text;
  }
  $("note").focus();
  const go = async () => {
    $("save").disabled = true;
    $("status").textContent = "Encrypting…";
    const result = await chrome.runtime.sendMessage({ type: "save", capture: { ...capture, note: $("note").value.trim() } });
    $("status").textContent = result.ok ? "Saved" : result.error;
    $("status").className = "status " + (result.ok ? "ok" : result.queued ? "warn" : "err");
    if (result.ok || result.queued) setTimeout(() => window.close(), 900);
    else $("save").disabled = false;
  };
  $("save").onclick = go;
  $("note").addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) go(); });
}
