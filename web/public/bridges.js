// Settings → Bridges (PROTOCOL.md §4 "Bridges"): webhook "add" addresses, feeds, GitHub and a
// Telegram bot, all run by the relay and adding to Trove through the sealed inbox. Plus link
// previews for links saved on the website.
import { $, ago, h } from "./dom.js";
import { icon } from "./icons.js";

/** Saves a link and, when it's new, asks the relay for its title and picture (no wait). */
export function saveLink(vault, url, options = {}, onDone = () => {}) {
  const result = vault.addLink(url, options);
  if (result.isNew) vault.fillLinkPreview(result.id).then(onDone, () => {});
  return result;
}

const KIND_TITLES = { webhook: "Add address", rss: "Feed", github: "GitHub", telegram: "Telegram" };

function statusLine(b) {
  const s = b.status ?? {};
  const parts = [];
  if (!b.enabled) parts.push("Off");
  if (s.lastRunAt) parts.push(`${b.kind === "webhook" || b.kind === "telegram" ? "Last used" : "Checked"} ${ago(s.lastRunAt)}`);
  else if (b.enabled && (b.kind === "rss" || b.kind === "github")) parts.push("Waiting for its first check");
  parts.push(`${s.itemsAdded ?? 0} added`);
  if (s.lastAddedAt) parts.push(`newest ${ago(s.lastAddedAt)}`);
  return parts.join(" · ");
}

/** Opens the Bridges dialog. `toast` shows a short message. */
export function showBridges(vault, { toast = () => {} } = {}) {
  const list = h("div", { class: "bridge-list", "aria-live": "polite" }, h("p", { class: "hint", text: "Loading…" }));
  const error = h("p", { class: "error", role: "alert", hidden: true });
  const onKey = (e) => { if (e.key === "Escape") close(); };
  const close = () => { backdrop.remove(); document.removeEventListener("keydown", onKey); };
  document.addEventListener("keydown", onKey);
  const box = h("div", { class: "dialog bridges-dialog", role: "dialog", "aria-modal": "true", "aria-labelledby": "bridges-title" },
    h("div", { class: "dialog-head" }, h("h2", { id: "bridges-title", text: "Bridges" }),
      h("button", { type: "button", class: "icon-button", "aria-label": "Close", onclick: close }, icon("close"))),
    h("p", { class: "hint", text: "Bridges bring things into Trove from other places. Your relay fetches or receives them and seals them for your devices: it can add to your vault, never read it." }),
    error, list);
  const backdrop = h("div", { class: "dialog-backdrop", onclick: (e) => { if (e.target === backdrop) close(); } }, box);
  document.body.append(backdrop);

  let bridges = [];
  const fail = (e) => { error.textContent = e.message.replace(/^[A-Z]+ [^:]+: \d+ /, "").replace(/^\{"error":"(.*)"\}$/, "$1"); error.hidden = false; };
  const call = async (method, path, body) => {
    error.hidden = true;
    try { return await vault.api(method, `bridges${path}`, { body, expect: [200, 201, 204] }); } catch (e) { fail(e); throw e; }
  };
  const reload = async () => {
    try { bridges = (await call("GET", "")).bridges; render(); } catch { list.replaceChildren(); }
  };
  const replace = (b) => { bridges = bridges.map((x) => (x.id === b.id ? b : x)); render(); };
  const add = async (body) => { const b = await call("POST", "", body); bridges.push(b); render(); return b; };

  function controls(b, extra = []) {
    return h("div", { class: "bridge-controls" },
      h("label", { class: "check" }, h("input", { type: "checkbox", checked: b.enabled, onchange: (e) => call("PUT", `/${b.id}`, { enabled: e.target.checked }).then(replace, reload) }), "On"),
      ...extra,
      h("button", { type: "button", class: "secondary small danger", onclick: () => {
        if (!confirm(`Remove this ${KIND_TITLES[b.kind].toLowerCase()} bridge? What it already added stays in Trove.`)) return;
        call("DELETE", `/${b.id}`).then(() => { bridges = bridges.filter((x) => x.id !== b.id); render(); }, () => {});
      } }, "Remove"));
  }
  const runNow = (b) => h("button", { type: "button", class: "secondary small", onclick: (e) => {
    e.target.disabled = true;
    call("POST", `/${b.id}/run`).then((nb) => { replace(nb); toast(nb.status.lastError ? "That didn't work" : "Checked"); }, () => { e.target.disabled = false; });
  } }, "Check now");
  const status = (b) => [h("p", { class: "saved", text: statusLine(b) }), b.status?.lastError ? h("p", { class: "bridge-error", text: `Last problem: ${b.status.lastError}` }) : null];
  const copyField = (value, label) => h("div", { class: "bridge-copy" },
    h("input", { value, readonly: true, "aria-label": label, onfocus: (e) => e.target.select() }),
    h("button", { type: "button", class: "secondary small", onclick: () => navigator.clipboard?.writeText(value).then(() => toast("Copied")) }, "Copy"));

  function webhookSection() {
    const hooks = bridges.filter((b) => b.kind === "webhook");
    return h("section", {},
      h("h3", { class: "section-title", text: "Add from anywhere" }),
      h("p", { class: "hint", text: "A private address that saves whatever is sent to it: from a Shortcut, IFTTT, Zapier or a script. Send JSON like {\"url\": …} or {\"text\": …, \"title\": …, \"tags\": […], \"folder\": \"A/B\"}, a form, or plain text. Anyone with the address can add to Trove, so keep it to yourself; make a new one if it leaks." }),
      ...hooks.map((b) => h("div", { class: "bridge" },
        h("strong", { text: b.settings.name || "Add address" }),
        copyField(b.hookURL, "Add address"),
        ...status(b),
        controls(b, [h("button", { type: "button", class: "secondary small", onclick: () => {
          if (confirm("Make a new address? The old one stops working.")) call("POST", `/${b.id}/regenerate`).then(replace, () => {});
        } }, "New address")]))),
      h("button", { type: "button", class: "secondary", onclick: () => add({ kind: "webhook", settings: { name: hooks.length ? `Add address ${hooks.length + 1}` : "Add address" } }).catch(() => {}) },
        hooks.length ? "Make another address" : "Make an add address"));
  }

  function feedSection() {
    const feeds = bridges.filter((b) => b.kind === "rss");
    const input = h("input", { type: "url", placeholder: "https://example.com/feed.xml", "aria-label": "Feed address", required: true });
    return h("section", {},
      h("h3", { class: "section-title", text: "Feeds" }),
      h("p", { class: "hint", text: "Follow a blog or news site's RSS or Atom feed. New posts arrive as links in Feeds, checked every couple of hours." }),
      ...feeds.map((b) => h("div", { class: "bridge" },
        h("strong", { text: b.settings.name || b.title || new URL(b.settings.url).hostname }),
        h("p", { class: "saved bridge-url", text: b.settings.url }),
        ...status(b), controls(b, [runNow(b)]))),
      h("form", { class: "bridge-form", onsubmit: (e) => {
        e.preventDefault();
        add({ kind: "rss", settings: { url: input.value.trim() } }).then(() => { input.value = ""; toast("Feed added"); }, () => {});
      } }, input, h("button", { type: "submit", class: "secondary" }, "Follow")));
  }

  function githubSection() {
    const gh = bridges.find((b) => b.kind === "github");
    if (gh) {
      const toggle = (key, label) => h("label", { class: "check" }, h("input", { type: "checkbox", checked: gh.settings[key] === true,
        onchange: (e) => call("PUT", `/${gh.id}`, { settings: { [key]: e.target.checked } }).then(replace, reload) }), label);
      return h("section", {},
        h("h3", { class: "section-title", text: "GitHub" }),
        h("div", { class: "bridge" },
          h("strong", { text: gh.settings.username }),
          toggle("stars", "Starred repositories"), toggle("releases", "New releases of my own repositories"),
          h("p", { class: "saved", text: gh.hasToken ? "Uses your token." : "No token: public data only, at GitHub's shared limit." }),
          ...status(gh),
          controls(gh, [runNow(gh), gh.hasToken ? h("button", { type: "button", class: "secondary small", onclick: () => call("PUT", `/${gh.id}`, { token: "" }).then(replace, () => {}) }, "Forget token") : null])));
    }
    const user = h("input", { placeholder: "GitHub username", "aria-label": "GitHub username", required: true, autocomplete: "off" });
    const token = h("input", { type: "password", placeholder: "Token (optional)", "aria-label": "GitHub token, optional", autocomplete: "off" });
    return h("section", {},
      h("h3", { class: "section-title", text: "GitHub" }),
      h("p", { class: "hint", text: "Your starred repositories arrive as links with their description, language and topics. Public stars need no token. A token only raises GitHub's limit: make a fine-grained one with public access only and no extra permissions. Your relay keeps it to use while your devices sleep." }),
      h("form", { class: "bridge-form", onsubmit: (e) => {
        e.preventDefault();
        add({ kind: "github", settings: { username: user.value.trim() }, ...(token.value.trim() ? { token: token.value.trim() } : {}) }).then(() => toast("GitHub connected"), () => {});
      } }, user, token, h("button", { type: "submit", class: "secondary" }, "Connect")));
  }

  function telegramSection() {
    const tg = bridges.find((b) => b.kind === "telegram");
    if (tg) {
      const t = tg.telegram ?? {};
      return h("section", {},
        h("h3", { class: "section-title", text: "Telegram" }),
        h("div", { class: "bridge" },
          h("strong", { text: t.bot ? `@${t.bot}` : "Your bot" }),
          t.linked ? h("p", { class: "hint", text: "Send it links, notes, photos or files and they're saved to Trove." })
            : h("p", { class: "hint" }, "One more step: ", h("a", { href: t.linkURL, target: "_blank", rel: "noopener noreferrer" }, "open your bot in Telegram"),
              " and press Start. Only that chat can add to Trove."),
          ...status(tg), controls(tg)));
    }
    const token = h("input", { type: "password", placeholder: "123456:ABC…", "aria-label": "Bot token", required: true, autocomplete: "off" });
    return h("section", {},
      h("h3", { class: "section-title", text: "Telegram" }),
      h("p", { class: "hint" }, "Save from any phone by messaging your own bot. In Telegram, message ",
        h("a", { href: "https://t.me/BotFather", target: "_blank", rel: "noopener noreferrer" }, "@BotFather"),
        ", send /newbot, pick a name, then paste the token it gives you here. Your relay keeps the token to receive your messages."),
      h("form", { class: "bridge-form", onsubmit: (e) => {
        e.preventDefault();
        add({ kind: "telegram", token: token.value.trim() }).then(() => toast("Bot connected. Now press Start in Telegram."), () => {});
      } }, token, h("button", { type: "submit", class: "secondary" }, "Connect")));
  }

  function render() {
    list.replaceChildren(webhookSection(), feedSection(), githubSection(), telegramSection(),
      h("section", {}, h("h3", { class: "section-title", text: "Link previews" }),
        h("p", { class: "hint", text: "Links you save on this website get their title, description and picture from your relay, which sees only the link." })));
  }

  reload();
  $("button", box)?.focus();
}
