// Safe Markdown preview: everything is escaped first, then a small subset is turned into tags.
// Same rules as the relay's published pages (server/src/publish.ts).

export function escapeHtml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

function safeHref(url) {
  try {
    const u = new URL(url);
    return ["https:", "http:", "mailto:"].includes(u.protocol) ? u.toString() : null;
  } catch {
    return null;
  }
}

function inline(escaped) {
  return escaped
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>")
    .replace(/~~([^~]+)~~/g, "<del>$1</del>")
    .replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (_, target, alias) => `<a href="#" class="wikilink" data-target="${target}">${alias ?? target}</a>`)
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (whole, text, href) => {
      const url = safeHref(href.replace(/&amp;/g, "&"));
      return url ? `<a href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">${text}</a>` : whole;
    })
    .replace(/(^|\s)#([\p{L}\p{N}_][\p{L}\p{N}_/-]*)/gu, '$1<a href="#" class="tag" data-tag="$2">#$2</a>');
}

export function renderMarkdown(markdown) {
  const out = [];
  let list = null, code = null;
  const closeList = () => { if (list) out.push(`</${list}>`); list = null; };
  for (const raw of markdown.replace(/\r\n/g, "\n").split("\n")) {
    if (raw.trim().startsWith("```")) {
      if (code) { out.push(`<pre><code>${code.map(escapeHtml).join("\n")}</code></pre>`); code = null; } else { closeList(); code = []; }
      continue;
    }
    if (code) { code.push(raw); continue; }
    const line = raw.trim();
    if (!line) { closeList(); continue; }
    let m;
    if ((m = line.match(/^(#{1,3})\s+(.*)$/))) {
      closeList();
      out.push(`<h${m[1].length + 1}>${inline(escapeHtml(m[2]))}</h${m[1].length + 1}>`);
    } else if ((m = line.match(/^[-*•]\s+\[( |x|X)\]\s+(.*)$/))) {
      if (list !== "ul") { closeList(); out.push('<ul class="tasks">'); list = "ul"; }
      out.push(`<li><input type="checkbox" disabled${m[1] === " " ? "" : " checked"}> ${inline(escapeHtml(m[2]))}</li>`);
    } else if ((m = line.match(/^[-*•]\s+(.*)$/))) {
      if (list !== "ul") { closeList(); out.push("<ul>"); list = "ul"; }
      out.push(`<li>${inline(escapeHtml(m[1]))}</li>`);
    } else if ((m = line.match(/^\d+[.)]\s+(.*)$/))) {
      if (list !== "ol") { closeList(); out.push("<ol>"); list = "ol"; }
      out.push(`<li>${inline(escapeHtml(m[1]))}</li>`);
    } else if (line.startsWith(">")) {
      closeList();
      out.push(`<blockquote>${inline(escapeHtml(line.replace(/^>\s?/, "")))}</blockquote>`);
    } else if (/^(-{3,}|\*{3,})$/.test(line)) {
      closeList();
      out.push("<hr>");
    } else {
      closeList();
      out.push(`<p>${inline(escapeHtml(line))}</p>`);
    }
  }
  if (code) out.push(`<pre><code>${code.map(escapeHtml).join("\n")}</code></pre>`);
  closeList();
  return out.join("\n");
}
