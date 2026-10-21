// Fetching other sites on a device's behalf (link previews, RSS feeds), safely: http(s) only, no
// private or local addresses, every redirect re-checked, and size and time limits. The relay sees the
// URL it fetches (like a price watch) and nothing else about the vault (PROTOCOL.md §4 "Bridges").

const ALLOWED_PORTS = new Set(["", "80", "443", "8080", "8443"]);
const LOCAL_SUFFIXES = [".localhost", ".local", ".internal", ".lan", ".home", ".home.arpa", ".corp", ".intranet", ".private"];
const UA = "Mozilla/5.0 (compatible; TroveRelay/1.0; +https://github.com/mrlancus/trove)";

export class FetchRefused extends Error {}

/** True for addresses that must never be fetched: loopback, private, link-local, CGNAT, multicast… */
export function isPrivateIPv4(host: string): boolean {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!m) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  return a === 0 || a === 10 || a === 127 || a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) || (a === 192 && b === 0) || (a === 198 && (b === 18 || b === 19));
}

/** Throws unless `raw` is an http(s) URL on a public host name or public IPv4 address. */
export function checkPublicURL(raw: string | URL): URL {
  let url: URL;
  try { url = new URL(String(raw)); } catch { throw new FetchRefused("not a valid URL"); }
  if (url.protocol !== "http:" && url.protocol !== "https:") throw new FetchRefused("only http and https links");
  if (url.username || url.password) throw new FetchRefused("links with a password aren't fetched");
  if (!ALLOWED_PORTS.has(url.port)) throw new FetchRefused("that port isn't allowed");
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  // The URL parser already turns 2130706433, 0x7f.1 and friends into dotted IPv4.
  if (host.startsWith("[")) throw new FetchRefused("IP address links aren't fetched");
  if (/^\d+\.\d+\.\d+\.\d+$/.test(host)) {
    if (isPrivateIPv4(host)) throw new FetchRefused("private addresses aren't fetched");
  } else if (!host.includes(".") || host === "localhost" || LOCAL_SUFFIXES.some((s) => host.endsWith(s))) {
    throw new FetchRefused("local addresses aren't fetched");
  }
  return url;
}

export interface SafeResponse {
  url: string;
  status: number;
  headers: Headers;
  text: string;
  truncated: boolean;
}

/**
 * GET with manual redirects (each hop checked), a timeout and a byte cap. Returns the body as text
 * (truncated at `maxBytes`). `fetcher` is the Durable Object's overridable fetch (tests).
 */
export async function safeFetch(
  raw: string,
  fetcher: typeof fetch,
  { maxBytes = 1_000_000, timeoutMs = 8000, accept = "text/html,application/xhtml+xml", headers = {} as Record<string, string> } = {},
): Promise<SafeResponse> {
  let url = checkPublicURL(raw);
  const signal = AbortSignal.timeout(timeoutMs);
  for (let hop = 0; hop < 5; hop++) {
    const res = await fetcher(url.toString(), { headers: { "user-agent": UA, accept, ...headers }, redirect: "manual", signal });
    if (res.status >= 300 && res.status < 400 && res.headers.get("location")) {
      await res.body?.cancel().catch(() => {});
      url = checkPublicURL(new URL(res.headers.get("location")!, url));
      continue;
    }
    const { text, truncated } = await readCapped(res, maxBytes);
    return { url: url.toString(), status: res.status, headers: res.headers, text, truncated };
  }
  throw new FetchRefused("too many redirects");
}

async function readCapped(res: Response, maxBytes: number): Promise<{ text: string; truncated: boolean }> {
  if (!res.body) return { text: "", truncated: false };
  const reader = res.body.getReader();
  const parts: Uint8Array[] = [];
  let size = 0, truncated = false;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    parts.push(value);
    size += value.length;
    if (size >= maxBytes) { truncated = true; await reader.cancel().catch(() => {}); break; }
  }
  const all = new Uint8Array(Math.min(size, maxBytes));
  let o = 0;
  for (const p of parts) {
    const take = Math.min(p.length, all.length - o);
    all.set(p.subarray(0, take), o);
    o += take;
    if (o >= all.length) break;
  }
  const charset = /charset=["']?([\w-]+)/i.exec(res.headers.get("content-type") ?? "")?.[1];
  let decoder: TextDecoder;
  try { decoder = new TextDecoder(charset ?? "utf-8"); } catch { decoder = new TextDecoder(); }
  return { text: decoder.decode(all), truncated };
}

// ---------- HTML metadata ----------

export function decodeEntities(s: string): string {
  return s
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => safeChar(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => safeChar(Number(d)))
    .replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ").replace(/&hellip;/g, "…").replace(/&mdash;/g, "—").replace(/&ndash;/g, "–")
    .replace(/&rsquo;/g, "’").replace(/&lsquo;/g, "‘").replace(/&rdquo;/g, "”").replace(/&ldquo;/g, "“").replace(/&amp;/g, "&");
}
function safeChar(n: number): string {
  try { return Number.isFinite(n) && n > 0 && n < 0x110000 ? String.fromCodePoint(n) : ""; } catch { return ""; }
}

/** Plain text from an HTML fragment (feed summaries, descriptions). */
export function htmlToText(html: string, max = 2000): string {
  const text = decodeEntities(
    html.replace(/<(script|style)[^>]*>[\s\S]*?<\/\1>/gi, "").replace(/<br\s*\/?>/gi, "\n").replace(/<\/(p|div|li|h\d|tr)>/gi, "\n").replace(/<[^>]+>/g, ""),
  ).replace(/[ \t ]+/g, " ").replace(/\n\s*\n\s*\n+/g, "\n\n").trim();
  return text.length > max ? text.slice(0, max - 1).trimEnd() + "…" : text;
}

export interface LinkPreview {
  url: string;
  title: string | null;
  description: string | null;
  image: string | null;
  site: string | null;
  icon: string | null;
}

function attr(tag: string, name: string): string | null {
  const m = new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, "i").exec(tag);
  return m ? decodeEntities(m[1] ?? m[2] ?? m[3] ?? "") : null;
}

const clip = (s: string | null, n: number) => (s ? (s.replace(/\s+/g, " ").trim().slice(0, n) || null) : null);

function absolute(href: string | null, base: string): string | null {
  if (!href) return null;
  try {
    const u = new URL(href.trim(), base);
    return u.protocol === "https:" || u.protocol === "http:" ? u.toString() : null;
  } catch { return null; }
}

/** Title, description, image, site name and icon from a page's <head> (Open Graph, Twitter, plain). */
export function extractPreview(html: string, pageURL: string): LinkPreview {
  const head = html.slice(0, 300_000);
  const metas = new Map<string, string>();
  for (const m of head.matchAll(/<meta\b[^>]*>/gi)) {
    const key = (attr(m[0], "property") ?? attr(m[0], "name") ?? attr(m[0], "itemprop"))?.toLowerCase();
    const content = attr(m[0], "content");
    if (key && content && !metas.has(key)) metas.set(key, content);
  }
  let icon: string | null = null;
  for (const m of head.matchAll(/<link\b[^>]*>/gi)) {
    const rel = attr(m[0], "rel")?.toLowerCase() ?? "";
    if (/\b(icon|apple-touch-icon)\b/.test(rel)) { icon = absolute(attr(m[0], "href"), pageURL); if (rel.includes("apple")) break; }
  }
  const titleTag = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(head)?.[1];
  const host = new URL(pageURL).hostname.replace(/^www\./, "");
  return {
    url: pageURL,
    title: clip(metas.get("og:title") ?? metas.get("twitter:title") ?? (titleTag ? decodeEntities(titleTag) : null), 300),
    description: clip(metas.get("og:description") ?? metas.get("twitter:description") ?? metas.get("description") ?? null, 600),
    image: absolute(metas.get("og:image:secure_url") ?? metas.get("og:image") ?? metas.get("twitter:image") ?? metas.get("twitter:image:src") ?? null, pageURL),
    site: clip(metas.get("og:site_name") ?? metas.get("application-name") ?? host, 100),
    icon: icon ?? absolute("/favicon.ico", pageURL),
  };
}

/** The link preview endpoint's work: fetch (safely) and read the page's metadata. */
export async function linkPreview(raw: string, fetcher: typeof fetch): Promise<LinkPreview> {
  const res = await safeFetch(raw, fetcher, { maxBytes: 512 * 1024 });
  if (res.status >= 400) throw new FetchRefused(`the site answered ${res.status}`);
  const type = res.headers.get("content-type") ?? "";
  if (type && !/html|xml/i.test(type)) {
    const name = decodeURIComponent(new URL(res.url).pathname.split("/").pop() ?? "") || null;
    return { url: res.url, title: name, description: null, image: /^image\//.test(type) ? res.url : null, site: new URL(res.url).hostname.replace(/^www\./, ""), icon: null };
  }
  return extractPreview(res.text, res.url);
}
