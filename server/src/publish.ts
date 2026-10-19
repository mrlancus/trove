// Publish-to-link (PROTOCOL.md §6). The user explicitly chooses to make one note public, so it is
// stored in plaintext and served at /p/:vault/:slug. Markdown is rendered here with everything
// escaped first, so a published page can never run script.

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

function safeHref(url: string): string | null {
  try {
    const u = new URL(url);
    return u.protocol === "https:" || u.protocol === "http:" || u.protocol === "mailto:" ? u.toString() : null;
  } catch {
    return null;
  }
}

/** Inline Markdown on already-escaped text: **bold**, *italic*, `code`, [text](url), [[wikilinks]]. */
function inline(escaped: string): string {
  return escaped
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>")
    .replace(/~~([^~]+)~~/g, "<del>$1</del>")
    .replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (_, target: string, alias?: string) => `<span class="wikilink">${alias ?? target}</span>`)
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (whole, text: string, href: string) => {
      const url = safeHref(href.replace(/&amp;/g, "&"));
      return url ? `<a href="${escapeHtml(url)}" rel="noopener nofollow">${text}</a>` : whole;
    });
}

export function renderMarkdown(markdown: string): string {
  const out: string[] = [];
  let list: "ul" | "ol" | null = null;
  let code: string[] | null = null;
  const closeList = () => {
    if (list) out.push(`</${list}>`);
    list = null;
  };
  for (const raw of markdown.replace(/\r\n/g, "\n").split("\n")) {
    if (raw.trim().startsWith("```")) {
      if (code) { out.push(`<pre><code>${code.map(escapeHtml).join("\n")}</code></pre>`); code = null; }
      else { closeList(); code = []; }
      continue;
    }
    if (code) { code.push(raw); continue; }
    const line = raw.trim();
    if (!line) { closeList(); continue; }
    const e = escapeHtml(line);
    let m: RegExpMatchArray | null;
    if ((m = line.match(/^(#{1,3})\s+(.*)$/))) {
      closeList();
      const level = m[1]!.length + 1; // the page title is the <h1>
      out.push(`<h${level}>${inline(escapeHtml(m[2]!))}</h${level}>`);
    } else if ((m = line.match(/^[-*•]\s+\[( |x|X)\]\s+(.*)$/))) {
      if (list !== "ul") { closeList(); out.push('<ul class="tasks">'); list = "ul"; }
      out.push(`<li><input type="checkbox" disabled${m[1] === " " ? "" : " checked"}> ${inline(escapeHtml(m[2]!))}</li>`);
    } else if ((m = line.match(/^[-*•]\s+(.*)$/))) {
      if (list !== "ul") { closeList(); out.push("<ul>"); list = "ul"; }
      out.push(`<li>${inline(escapeHtml(m[1]!))}</li>`);
    } else if ((m = line.match(/^\d+[.)]\s+(.*)$/))) {
      if (list !== "ol") { closeList(); out.push("<ol>"); list = "ol"; }
      out.push(`<li>${inline(escapeHtml(m[1]!))}</li>`);
    } else if (line.startsWith(">")) {
      closeList();
      out.push(`<blockquote>${inline(escapeHtml(line.replace(/^>\s?/, "")))}</blockquote>`);
    } else if (/^(-{3,}|\*{3,})$/.test(line)) {
      closeList();
      out.push("<hr>");
    } else {
      closeList();
      out.push(`<p>${inline(e)}</p>`);
    }
  }
  if (code) out.push(`<pre><code>${code.map(escapeHtml).join("\n")}</code></pre>`);
  closeList();
  return out.join("\n");
}

export function publishedPage(title: string, markdown: string, updatedAt: number): Response {
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>${escapeHtml(title)}</title>
<style>
:root{color-scheme:light dark;--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#e5e5ea;--accent:#c2410c}
@media (prefers-color-scheme:dark){:root{--bg:#121214;--fg:#f2f2f7;--muted:#a1a1a6;--line:#2c2c2e;--accent:#ff9f5a}}
body{margin:0;background:var(--bg);color:var(--fg);font:18px/1.6 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
main{max-width:680px;margin:0 auto;padding:56px 20px 80px}
h1{font-size:2.2em;line-height:1.15;margin:0 0 .3em;letter-spacing:-.01em}
h2,h3,h4{line-height:1.25;margin:1.6em 0 .4em}
a{color:var(--accent)}code{font:.9em ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--line);padding:.1em .35em;border-radius:5px}
pre{background:var(--line);padding:14px;border-radius:10px;overflow-x:auto}pre code{background:none;padding:0}
blockquote{margin:1em 0;padding-left:16px;border-left:3px solid var(--accent);color:var(--muted);font-style:italic}
ul.tasks{list-style:none;padding-left:0}hr{border:0;border-top:1px solid var(--line);margin:2em 0}
.wikilink{border-bottom:1px dashed var(--muted)}
footer{margin-top:56px;padding-top:16px;border-top:1px solid var(--line);color:var(--muted);font-size:14px}
</style></head>
<body><main><h1>${escapeHtml(title)}</h1>
${renderMarkdown(markdown)}
<footer>Shared from Trove · updated ${new Date(updatedAt).toISOString().slice(0, 10)}</footer></main></body></html>`;
  return new Response(html, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; img-src https: data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
      "cache-control": "public, max-age=60",
    },
  });
}
