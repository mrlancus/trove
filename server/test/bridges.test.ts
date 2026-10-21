import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { open, parseEnvelope, type InboxHeader } from "../src/crypto";
import { parseFeed } from "../src/feeds";
import { checkPublicURL, extractPreview } from "../src/preview";
import { telegramURLs } from "../src/bridges";
import type { Env, VaultObject } from "../src/vault";
import { auth, BASE, call, createVault, type TestVault } from "./helpers";

function vaultStub(vaultId: string) {
  const ns = (env as unknown as Env).VAULT;
  return ns.get(ns.idFromName(vaultId)) as DurableObjectStub<VaultObject>;
}

/** Replaces the vault's outgoing fetch for the rest of the test. */
async function mockFetch(v: TestVault, handler: (url: string, init?: RequestInit) => Response | Promise<Response>) {
  const calls: string[] = [];
  await runInDurableObject(vaultStub(v.vaultId), async (vault: VaultObject) => {
    vault.fetchPage = async (input, init) => {
      calls.push(String(input));
      return handler(String(input), init);
    };
  });
  return calls;
}

async function inbox(v: TestVault): Promise<{ header: InboxHeader; body: string; bytes: Uint8Array }[]> {
  const list = (await (await call(`/v1/vaults/${v.vaultId}/inbox`, { headers: auth(v.deviceToken) })).json()) as { entries: { id: string }[] };
  const out = [];
  for (const e of list.entries) {
    const sealed = new Uint8Array(await (await call(`/v1/vaults/${v.vaultId}/inbox/${e.id}`, { headers: auth(v.deviceToken) })).arrayBuffer());
    const { header, body } = parseEnvelope(await open(sealed, { recipientPrivateKey: v.keys.privateKey, recipientPublicKey: v.publicKey }));
    out.push({ header, body: new TextDecoder().decode(body), bytes: body });
  }
  return out;
}

function bridgeCall(v: TestVault, path = "", init: RequestInit & { json?: unknown } = {}) {
  const { json: body, ...rest } = init;
  return call(`/v1/vaults/${v.vaultId}/bridges${path}`, {
    ...rest, headers: auth(v.deviceToken), ...(body !== undefined ? { body: JSON.stringify(body), method: rest.method ?? "POST" } : {}),
  });
}

type Bridge = {
  id: string; kind: string; enabled: boolean; hookURL?: string; settings: Record<string, unknown>; hasToken: boolean; title?: string;
  status: { lastRunAt: number | null; lastError: string | null; itemsAdded: number; nextRunAt: number | null };
  telegram?: { bot: string; linked: boolean; linkURL: string | null };
};

const rss = (items: number[], title = "Tech Daily") => `<?xml version="1.0"?><rss version="2.0"><channel><title>${title}</title><link>https://tech.example</link>
${items.map((n) => `<item><title>Post ${n} &amp; more</title><link>/posts/${n}</link><guid isPermaLink="false">post-${n}</guid>
<description><![CDATA[<p>Body of <b>post ${n}</b></p>]]></description><pubDate>Mon, 19 Oct 2026 10:00:00 GMT</pubDate></item>`).join("\n")}
</channel></rss>`;

describe("safe fetching and parsing", () => {
  it("refuses non-http(s), private, local and odd-port addresses", () => {
    for (const bad of ["file:///etc/passwd", "ftp://x.example/", "http://localhost/", "http://127.0.0.1/", "http://2130706433/", "http://10.1.2.3/",
      "http://192.168.0.1/", "http://169.254.169.254/latest", "http://[::1]/", "http://printer.local/", "http://intranet/", "http://user:pw@x.example/",
      "http://x.example:22/", "http://100.64.0.1/", "http://0x7f.1/"]) {
      expect(() => checkPublicURL(bad), bad).toThrow();
    }
    expect(checkPublicURL("https://example.com/a?b").toString()).toBe("https://example.com/a?b");
    expect(checkPublicURL("http://93.184.216.34:8080/").hostname).toBe("93.184.216.34");
  });

  it("reads Open Graph, Twitter and plain metadata", () => {
    const html = `<html><head><title>Plain &amp; title</title><meta property="og:title" content="OG &quot;title&quot;">
      <meta name="description" content="A page about things"><meta property="og:image" content="/img/card.png">
      <meta property="og:site_name" content="Example News"><link rel="icon" href="/favicon.svg"></head></html>`;
    expect(extractPreview(html, "https://news.example/a/b")).toEqual({
      url: "https://news.example/a/b", title: 'OG "title"', description: "A page about things", image: "https://news.example/img/card.png",
      site: "Example News", icon: "https://news.example/favicon.svg",
    });
    const bare = extractPreview("<title>Just a title</title>", "https://www.bare.example/");
    expect(bare).toMatchObject({ title: "Just a title", description: null, image: null, site: "bare.example" });
  });

  it("parses RSS 2.0 and Atom", () => {
    const r = parseFeed(rss([2, 1]), "https://tech.example/feed.xml")!;
    expect(r.title).toBe("Tech Daily");
    expect(r.entries[0]).toMatchObject({ id: "post-2", url: "https://tech.example/posts/2", title: "Post 2 & more", summary: "Body of post 2" });
    const atom = `<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title type="text">My Blog</title>
      <entry><title>Hello</title><link rel="alternate" href="https://blog.example/hello"/><id>tag:blog,1</id><updated>2026-10-01T00:00:00Z</updated>
      <summary type="html">&lt;p&gt;Hi there&lt;/p&gt;</summary><author><name>Ana</name></author></entry></feed>`;
    const a = parseFeed(atom, "https://blog.example/atom")!;
    expect(a.title).toBe("My Blog");
    expect(a.entries).toEqual([{ id: "tag:blog,1", url: "https://blog.example/hello", title: "Hello", summary: "Hi there", published: "2026-10-01T00:00:00Z", author: "Ana" }]);
    expect(parseFeed("<html><body>nope</body></html>", "https://x.example")).toBeNull();
  });

  it("finds links in Telegram messages", () => {
    expect(telegramURLs("look example.com/x now", [{ type: "url", offset: 5, length: 13 }])).toEqual(["https://example.com/x"]);
    expect(telegramURLs("this", [{ type: "text_link", offset: 0, length: 4, url: "https://t.example/" }])).toEqual(["https://t.example/"]);
    expect(telegramURLs("see https://a.example/p).", [])).toEqual(["https://a.example/p"]);
  });
});

describe("link previews", () => {
  it("fetches a page for a device, follows safe redirects and refuses unsafe ones", async () => {
    const v = await createVault();
    const calls = await mockFetch(v, (url) => {
      if (url === "https://short.example/x") return new Response(null, { status: 301, headers: { location: "https://news.example/story" } });
      if (url === "https://short.example/evil") return new Response(null, { status: 302, headers: { location: "http://169.254.169.254/" } });
      return new Response(`<meta property="og:title" content="A story"><meta property="og:image" content="https://cdn.example/s.jpg">`, { headers: { "content-type": "text/html" } });
    });
    const preview = (url: string, token = v.deviceToken) => call(`/v1/vaults/${v.vaultId}/preview`, { method: "POST", headers: auth(token), body: JSON.stringify({ url }) });
    const ok = await preview("https://short.example/x");
    expect(ok.status).toBe(200);
    expect(await ok.json()).toMatchObject({ url: "https://news.example/story", title: "A story", image: "https://cdn.example/s.jpg", site: "news.example" });
    for (const unsafe of ["https://short.example/evil", "http://127.0.0.1:8787/"]) {
      const res = await preview(unsafe);
      expect(res.status).toBe(200);
      expect(await res.json()).toMatchObject({ refused: true, title: null, image: null });
    }
    expect((await preview("")).status).toBe(400);
    expect((await preview("https://news.example/", v.inboxToken)).status).toBe(403);
    expect(calls).toEqual(["https://short.example/x", "https://news.example/story", "https://short.example/evil"]);
  });
});

describe("bridges", () => {
  it("needs a device token", async () => {
    const v = await createVault();
    expect((await call(`/v1/vaults/${v.vaultId}/bridges`)).status).toBe(401);
    expect((await call(`/v1/vaults/${v.vaultId}/bridges`, { headers: auth(v.inboxToken) })).status).toBe(403);
    expect((await bridgeCall(v, "", { json: { kind: "carrier-pigeon" } })).status).toBe(400);
    const list = (await (await bridgeCall(v)).json()) as { bridges: unknown[]; kinds: string[] };
    expect(list).toEqual({ bridges: [], kinds: ["webhook", "rss", "github", "telegram"] });
  });

  it("webhook: a secret add URL that takes JSON, forms and text, and can be regenerated or turned off", async () => {
    const v = await createVault();
    const created = await bridgeCall(v, "", { json: { kind: "webhook", settings: { name: "Shortcuts", folder: "Inbox/Shortcuts", tags: ["phone"] } } });
    expect(created.status).toBe(201);
    const hook = (await created.json()) as Bridge;
    expect(hook.hookURL).toMatch(new RegExp(`^${BASE}/hook/${v.vaultId}/thk_`));
    const path = hook.hookURL!.slice(BASE.length);

    expect((await call(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ url: "https://site.example/a", title: "A", tags: "read later" }) })).status).toBe(201);
    const form = new FormData();
    form.set("text", "Remember the milk");
    form.set("folder", "Errands");
    expect((await call(path, { method: "POST", body: form })).status).toBe(201);
    expect((await call(path, { method: "POST", body: "https://plain.example/b" })).status).toBe(201);
    const fileForm = new FormData();
    fileForm.set("file", new File([new Uint8Array([1, 2, 3])], "scan.png", { type: "image/png" }));
    expect((await call(path, { method: "POST", body: fileForm })).status).toBe(201);
    expect((await call(path, { method: "POST", body: JSON.stringify({ url: "javascript:alert(1)" }) })).status).toBe(400);
    expect((await call(path, { method: "POST", body: JSON.stringify({}) })).status).toBe(400);
    expect((await call(`/hook/${v.vaultId}/thk_${"x".repeat(43)}`, { method: "POST", body: "hi" })).status).toBe(404);

    const entries = await inbox(v);
    expect(entries.map((e) => e.header.source)).toEqual(["webhook", "webhook", "webhook", "webhook"]);
    expect(entries[0]!.header).toMatchObject({ url: "https://site.example/a", title: "A", folder: ["Inbox", "Shortcuts"], tags: ["phone", "read", "later"] });
    expect(entries[0]!.header.meta).toMatchObject({ bridge: hook.id });
    expect(entries[1]).toMatchObject({ body: "Remember the milk", header: { folder: ["Errands"], mime: "text/plain" } });
    expect(entries[2]).toMatchObject({ body: "", header: { url: "https://plain.example/b" } });
    expect(entries[3]!.header).toMatchObject({ name: "scan.png", mime: "image/png" });
    expect([...entries[3]!.bytes]).toEqual([1, 2, 3]);

    const status = (await (await bridgeCall(v, `/${hook.id}`)).json()) as Bridge;
    expect(status.status.itemsAdded).toBe(4);

    const fresh = (await (await bridgeCall(v, `/${hook.id}/regenerate`, { method: "POST" })).json()) as Bridge;
    expect(fresh.hookURL).not.toBe(hook.hookURL);
    expect((await call(path, { method: "POST", body: "old" })).status).toBe(404);
    const newPath = fresh.hookURL!.slice(BASE.length);
    await bridgeCall(v, `/${hook.id}`, { method: "PUT", json: { enabled: false } });
    expect((await call(newPath, { method: "POST", body: "off" })).status).toBe(403);
    expect((await bridgeCall(v, `/${hook.id}`, { method: "DELETE" })).status).toBe(204);
    expect((await call(newPath, { method: "POST", body: "gone" })).status).toBe(404);
  });

  it("rss: first run brings the newest few, later runs only new posts, into Feeds/<name>; errors are kept", async () => {
    const v = await createVault();
    let feed = rss([7, 6, 5, 4, 3, 2, 1]);
    await mockFetch(v, (url) => (url === "https://tech.example/feed.xml" ? new Response(feed, { headers: { "content-type": "application/rss+xml", etag: '"v1"' } }) : new Response("nope", { status: 404 })));
    const b = (await (await bridgeCall(v, "", { json: { kind: "rss", settings: { url: "https://tech.example/feed.xml" } } })).json()) as Bridge;
    expect(b.settings).toMatchObject({ url: "https://tech.example/feed.xml", folder: "Feeds" });
    expect((await bridgeCall(v, "", { json: { kind: "rss", settings: { url: "file:///x" } } })).status).toBe(400);

    const t0 = Date.now() + 5000;
    await runInDurableObject(vaultStub(v.vaultId), async (vault: VaultObject, state) => {
      expect(await state.storage.getAlarm()).not.toBeNull(); // a new feed is checked within seconds
      await state.storage.deleteAlarm();
      expect(await vault.bridges.runDue(t0)).toBe(1);
      expect(await vault.bridges.runDue(t0 + 60_000)).toBe(0); // not due again yet
    });
    let entries = await inbox(v);
    expect(entries.map((e) => e.header.title)).toEqual(["Post 3 & more", "Post 4 & more", "Post 5 & more", "Post 6 & more", "Post 7 & more"]);
    expect(entries[0]!.header).toMatchObject({ source: "rss", url: "https://tech.example/posts/3", folder: ["Feeds", "Tech Daily"], mime: "text/plain" });
    expect(entries[0]!.body).toBe("Body of post 3");

    feed = rss([9, 8, 7, 6, 5]);
    await runInDurableObject(vaultStub(v.vaultId), async (vault: VaultObject) => {
      expect(await vault.bridges.runDue(t0 + 3 * 3_600_000)).toBe(1);
    });
    entries = await inbox(v);
    expect(entries.slice(5).map((e) => e.header.title)).toEqual(["Post 8 & more", "Post 9 & more"]);
    let status = (await (await bridgeCall(v, `/${b.id}`)).json()) as Bridge;
    expect(status).toMatchObject({ title: "Tech Daily", status: { itemsAdded: 7, lastError: null } });

    await bridgeCall(v, `/${b.id}`, { method: "PUT", json: { settings: { url: "https://tech.example/missing.xml" } } });
    const ran = await bridgeCall(v, `/${b.id}/run`, { method: "POST" });
    expect(ran.status).toBe(200);
    status = (await ran.json()) as Bridge;
    expect(status.status.lastError).toBe("the feed answered 404");
    expect(status.status.nextRunAt! - status.status.lastRunAt!).toBe(4 * 3_600_000); // backs off
  });

  it("the vault alarm runs due bridges and schedules the next check, next to price watches", async () => {
    const v = await createVault();
    await mockFetch(v, () => new Response(rss([1]), { headers: { "content-type": "application/rss+xml" } }));
    await bridgeCall(v, "", { json: { kind: "rss", settings: { url: "https://tech.example/feed.xml" } } });
    await runInDurableObject(vaultStub(v.vaultId), async (vault: VaultObject, state) => {
      await state.storage.deleteAlarm();
      await vault.alarm();
      const next = await state.storage.getAlarm();
      expect(next! - Date.now()).toBeGreaterThan(2 * 3_600_000 - 60_000);
      expect(next! - Date.now()).toBeLessThanOrEqual(2 * 3_600_000);
    });
    expect((await inbox(v)).map((e) => e.header.title)).toEqual(["Post 1 & more"]);
  });

  it("github: public stars become links with description, language and topics", async () => {
    const v = await createVault();
    const repo = (id: number, name: string) => ({ id, full_name: `octo/${name}`, html_url: `https://github.com/octo/${name}`, description: `The ${name} tool`,
      language: "TypeScript", topics: ["cli", "devtools"], stargazers_count: 42 });
    await mockFetch(v, (url) => {
      if (url.startsWith("https://api.github.com/users/ana/starred?per_page=30&page=1")) return Response.json([{ starred_at: "2026-10-01T00:00:00Z", repo: repo(2, "two") }, { repo: repo(1, "one") }]);
      if (url.startsWith("https://api.github.com/users/ana/starred")) return Response.json([]);
      return new Response("{}", { status: 404 });
    });
    const b = (await (await bridgeCall(v, "", { json: { kind: "github", settings: { username: "ana" }, token: "github_pat_example" } })).json()) as Bridge;
    expect(b).toMatchObject({ hasToken: true, settings: { username: "ana", stars: true, releases: false, folder: "GitHub" } });
    expect(JSON.stringify(b)).not.toContain("github_pat_example");
    expect((await bridgeCall(v, "", { json: { kind: "github", settings: { username: "not a user!" } } })).status).toBe(400);

    await runInDurableObject(vaultStub(v.vaultId), async (vault: VaultObject, state) => {
      await state.storage.deleteAlarm();
      expect(await vault.bridges.runDue(Date.now() + 5000)).toBe(1);
    });
    const entries = await inbox(v);
    expect(entries.map((e) => e.header.title)).toEqual(["octo/one", "octo/two"]);
    expect(entries[0]!.header).toMatchObject({ source: "github", url: "https://github.com/octo/one", folder: ["GitHub", "Stars"], tags: ["github", "cli", "devtools", "typescript"] });
    expect(entries[0]!.body).toBe("The one tool\n\nLanguage: TypeScript\nTopics: cli, devtools\nStars: 42");
  });

  it("telegram: links the chat with /start, then saves texts, links and photos from that chat only", async () => {
    const v = await createVault();
    const token = "123456:ABCdefGhIJKlmnoPQRstuVWXyz_0123456";
    const sent: { method: string; body: Record<string, unknown> }[] = [];
    await mockFetch(v, async (url, init) => {
      if (url.startsWith(`https://api.telegram.org/file/bot${token}/`)) return new Response(new Uint8Array([0xff, 0xd8, 0xff]));
      const method = url.split("/").pop()!;
      sent.push({ method, body: JSON.parse(String(init?.body ?? "{}")) });
      const result = method === "getMe" ? { username: "my_trove_bot" } : method === "getFile" ? { file_path: "photos/file_1.jpg" } : true;
      return Response.json({ ok: true, result });
    });
    const res = await bridgeCall(v, "", { json: { kind: "telegram", token } });
    expect(res.status).toBe(201);
    const b = (await res.json()) as Bridge;
    expect(b.telegram).toMatchObject({ bot: "my_trove_bot", linked: false });
    const code = b.telegram!.linkURL!.split("start=")[1]!;
    const setHook = sent.find((s) => s.method === "setWebhook")!.body as { url: string; secret_token: string };
    expect(setHook.url).toMatch(new RegExp(`^${BASE}/hook/${v.vaultId}/thk_`));
    const path = setHook.url.slice(BASE.length);
    const post = (message: Record<string, unknown>, secret = setHook.secret_token) =>
      call(path, { method: "POST", headers: { "x-telegram-bot-api-secret-token": secret }, body: JSON.stringify({ update_id: 1, message: { message_id: 7, date: 1760000000, ...message } }) });

    expect((await post({ chat: { id: 5 }, text: "hello" }, "wrong")).status).toBe(404);
    expect((await post({ chat: { id: 5 }, text: "before linking" })).status).toBe(200);
    expect((await post({ chat: { id: 5 }, text: `/start ${code}` })).status).toBe(200);
    expect(((await (await bridgeCall(v, `/${b.id}`)).json()) as Bridge).telegram).toMatchObject({ linked: true, linkURL: null });
    await post({ chat: { id: 5 }, text: "Read this https://news.example/x later", entities: [{ type: "url", offset: 10, length: 22 }] });
    await post({ chat: { id: 5 }, text: "a quiet thought" });
    await post({ chat: { id: 5 }, caption: "Receipt", photo: [{ file_id: "small", width: 90, height: 90 }, { file_id: "big", width: 1280, height: 960 }] });
    await post({ chat: { id: 99 }, text: "stranger danger" });

    const entries = await inbox(v);
    expect(entries.map((e) => e.header.source)).toEqual(["telegram", "telegram", "telegram"]);
    expect(entries[0]).toMatchObject({ body: "Read this https://news.example/x later", header: { url: "https://news.example/x" } });
    expect(entries[1]).toMatchObject({ body: "a quiet thought", header: { mime: "text/plain" } });
    expect(entries[2]!.header).toMatchObject({ mime: "image/jpeg", name: "telegram-7.jpg", title: "Receipt" });
    expect([...entries[2]!.bytes]).toEqual([0xff, 0xd8, 0xff]);
    expect(sent.find((s) => s.method === "getFile")!.body).toEqual({ file_id: "big" });
    expect(sent.filter((s) => s.method === "sendMessage").length).toBe(4); // linked + 3 saved
    expect(JSON.stringify(await (await bridgeCall(v)).json())).not.toContain(token);

    expect((await bridgeCall(v, `/${b.id}`, { method: "DELETE" })).status).toBe(204);
    expect(sent.at(-1)!.method).toBe("deleteWebhook");
  });

  it("rejects bad Telegram tokens without storing anything", async () => {
    const v = await createVault();
    await mockFetch(v, () => Response.json({ ok: false, description: "Unauthorized" }, { status: 401 }));
    expect((await bridgeCall(v, "", { json: { kind: "telegram", token: "nope" } })).status).toBe(400);
    expect((await bridgeCall(v, "", { json: { kind: "telegram", token: "123:abcdefghijklmnopqrstuvwxyz" } })).status).toBe(400);
    expect(((await (await bridgeCall(v)).json()) as { bridges: unknown[] }).bridges).toHaveLength(0);
  });
});
