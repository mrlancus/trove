// Parsers for what bridges fetch: RSS 0.9x/1.0/2.0 and Atom feeds, and GitHub's REST answers.
// Small regex readers on purpose: feeds are simple, and the Workers runtime has no DOM.
import { decodeEntities, htmlToText } from "./preview";

export interface FeedEntry {
  id: string;
  url: string | null;
  title: string;
  summary: string;
  published: string | null;
  author: string | null;
}

export interface Feed {
  title: string | null;
  entries: FeedEntry[];
}

function text(xml: string | undefined | null): string {
  if (!xml) return "";
  const cdata = /^\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*$/.exec(xml);
  return cdata ? cdata[1]! : decodeEntities(xml.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1"));
}

function tag(xml: string, name: string): string | null {
  const m = new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)</${name}>`, "i").exec(xml);
  return m ? m[1]! : null;
}

function attrOf(tagText: string, name: string): string | null {
  const m = new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)')`, "i").exec(tagText);
  return m ? decodeEntities(m[1] ?? m[2] ?? "") : null;
}

function absolute(href: string | null, base: string): string | null {
  if (!href) return null;
  try {
    const u = new URL(href.trim(), base);
    return u.protocol === "http:" || u.protocol === "https:" ? u.toString() : null;
  } catch { return null; }
}

const oneLine = (s: string) => s.replace(/\s+/g, " ").trim();

/** Reads an RSS or Atom document. Returns null when it's neither (an HTML page, say). */
export function parseFeed(xml: string, feedURL: string): Feed | null {
  const isAtom = /<feed[\s>]/i.test(xml) && !/<rss[\s>]|<rdf:RDF[\s>]/i.test(xml);
  const isRSS = /<rss[\s>]|<rdf:RDF[\s>]|<channel[\s>]/i.test(xml);
  if (!isAtom && !isRSS) return null;
  const entries: FeedEntry[] = [];
  if (isAtom) {
    const head = xml.split(/<entry[\s>]/i)[0] ?? "";
    for (const m of xml.matchAll(/<entry(?:\s[^>]*)?>([\s\S]*?)<\/entry>/gi)) {
      const e = m[1]!;
      let link: string | null = null;
      for (const l of e.matchAll(/<link\b[^>]*>/gi)) {
        const rel = attrOf(l[0], "rel") ?? "alternate";
        if (rel === "alternate" || !link) link = absolute(attrOf(l[0], "href"), feedURL);
        if (rel === "alternate") break;
      }
      const url = link;
      const id = oneLine(text(tag(e, "id"))) || url || oneLine(text(tag(e, "title")));
      if (!id) continue;
      entries.push({
        id, url,
        title: oneLine(htmlToText(text(tag(e, "title")), 300)),
        summary: htmlToText(text(tag(e, "summary") ?? tag(e, "content")), 1000),
        published: oneLine(text(tag(e, "published") ?? tag(e, "updated"))) || null,
        author: oneLine(text(tag(tag(e, "author") ?? "", "name"))) || null,
      });
    }
    return { title: oneLine(htmlToText(text(tag(head, "title")), 200)) || null, entries };
  }
  const head = xml.split(/<item[\s>]/i)[0] ?? "";
  for (const m of xml.matchAll(/<item(?:\s[^>]*)?>([\s\S]*?)<\/item>/gi)) {
    const e = m[1]!;
    const about = attrOf(m[0].slice(0, m[0].indexOf(">") + 1), "rdf:about");
    const guid = oneLine(text(tag(e, "guid")));
    const url = absolute(oneLine(text(tag(e, "link"))) || (/^https?:/i.test(guid) ? guid : null) || about, feedURL);
    const id = guid || about || url || oneLine(text(tag(e, "title")));
    if (!id) continue;
    entries.push({
      id, url,
      title: oneLine(htmlToText(text(tag(e, "title")), 300)),
      summary: htmlToText(text(tag(e, "description") ?? tag(e, "content:encoded")), 1000),
      published: oneLine(text(tag(e, "pubDate") ?? tag(e, "dc:date"))) || null,
      author: oneLine(text(tag(e, "dc:creator") ?? tag(e, "author"))) || null,
    });
  }
  const channel = tag(head, "channel") ?? head;
  return { title: oneLine(htmlToText(text(tag(channel, "title")), 200)) || null, entries };
}

// ---------- GitHub ----------

export interface GitHubRepo {
  id: number;
  full_name: string;
  html_url: string;
  description: string | null;
  language: string | null;
  topics?: string[];
  stargazers_count?: number;
  fork?: boolean;
}

export interface GitHubRelease {
  id: number;
  html_url: string;
  name: string | null;
  tag_name: string;
  body: string | null;
  draft?: boolean;
  prerelease?: boolean;
  published_at?: string | null;
}

/** The note saved with a starred repo: what it is, its language and topics. */
export function repoNote(repo: GitHubRepo): string {
  const lines: string[] = [];
  if (repo.description) lines.push(repo.description.trim());
  const facts: string[] = [];
  if (repo.language) facts.push(`Language: ${repo.language}`);
  if (repo.topics?.length) facts.push(`Topics: ${repo.topics.join(", ")}`);
  if (typeof repo.stargazers_count === "number") facts.push(`Stars: ${repo.stargazers_count}`);
  if (facts.length) lines.push(facts.join("\n"));
  return lines.join("\n\n");
}

/** Tags for a repo: its topics (as Trove tags) and language. */
export function repoTags(repo: GitHubRepo): string[] {
  const tags = ["github", ...(repo.topics ?? []).slice(0, 8)];
  if (repo.language) tags.push(repo.language.toLowerCase().replace(/\s+/g, "-"));
  return [...new Set(tags.map((t) => t.toLowerCase()))];
}
