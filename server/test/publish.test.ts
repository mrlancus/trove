import { describe, expect, it } from "vitest";
import { renderMarkdown } from "../src/publish";
import { auth, call, createVault } from "./helpers";

describe("renderMarkdown", () => {
  it("renders headings, lists, tasks, quotes, code and inline styles", () => {
    const html = renderMarkdown(
      [
        "# Trip",
        "Some **bold**, *italic*, `code` and ~~gone~~.",
        "- one",
        "- two",
        "1. first",
        "- [x] packed",
        "- [ ] passport",
        "> quoted",
        "---",
        "```",
        "let x = 1 < 2",
        "```",
        "See [[Japan|my Japan note]] and [the site](https://example.com/a?b=1&c=2).",
      ].join("\n"),
    );
    expect(html).toContain("<h2>Trip</h2>");
    expect(html).toContain("<strong>bold</strong>");
    expect(html).toContain("<em>italic</em>");
    expect(html).toContain("<code>code</code>");
    expect(html).toContain("<del>gone</del>");
    expect(html).toContain("<ul>\n<li>one</li>\n<li>two</li>\n</ul>");
    expect(html).toContain("<ol>\n<li>first</li>\n</ol>");
    expect(html).toContain('<input type="checkbox" disabled checked> packed');
    expect(html).toContain('<input type="checkbox" disabled> passport');
    expect(html).toContain("<blockquote>quoted</blockquote>");
    expect(html).toContain("<hr>");
    expect(html).toContain("<pre><code>let x = 1 &lt; 2</code></pre>");
    expect(html).toContain('<span class="wikilink">my Japan note</span>');
    expect(html).toContain('<a href="https://example.com/a?b=1&amp;c=2" rel="noopener nofollow">the site</a>');
  });

  it("never lets markup or script URLs through", () => {
    const html = renderMarkdown(
      [
        "<script>alert(1)</script>",
        '<img src=x onerror="alert(1)">',
        "[click](javascript:alert(1))",
        '[x](https://ok.example/"onmouseover="alert(1))',
        "## <b>title</b>",
      ].join("\n"),
    );
    expect(html).not.toMatch(/<script|<img|<b>/i);
    expect(html).not.toContain('href="javascript');
    expect(html).not.toMatch(/"\s*onmouseover=/);
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
  });
});

describe("publish to link", () => {
  it("publishes a page, serves it publicly with a strict CSP, lists it and unpublishes", async () => {
    const v = await createVault();
    const put = await call(`/v1/vaults/${v.vaultId}/published/abc123def`, {
      method: "PUT",
      headers: auth(v.deviceToken),
      body: JSON.stringify({ title: "Ramen <notes>", markdown: "Hello **world**" }),
    });
    expect(put.status).toBe(201);
    expect(await put.json()).toEqual({ slug: "abc123def", path: `/p/${v.vaultId}/abc123def` });

    const page = await call(`/p/${v.vaultId}/abc123def`);
    expect(page.status).toBe(200);
    expect(page.headers.get("content-type")).toContain("text/html");
    expect(page.headers.get("content-security-policy")).toContain("default-src 'none'");
    expect(page.headers.get("x-content-type-options")).toBe("nosniff");
    const html = await page.text();
    expect(html).toContain("<h1>Ramen &lt;notes&gt;</h1>");
    expect(html).toContain("<strong>world</strong>");
    expect(html).toContain('name="robots" content="noindex"');

    const list = (await (await call(`/v1/vaults/${v.vaultId}/published`, { headers: auth(v.deviceToken) })).json()) as {
      pages: { slug: string; title: string }[];
    };
    expect(list.pages).toMatchObject([{ slug: "abc123def", title: "Ramen <notes>" }]);

    expect((await call(`/v1/vaults/${v.vaultId}/published/abc123def`, { method: "DELETE", headers: auth(v.deviceToken) })).status).toBe(204);
    expect((await call(`/p/${v.vaultId}/abc123def`)).status).toBe(404);
  });

  it("needs a device token to publish and rejects bad slugs and huge pages", async () => {
    const v = await createVault();
    const base = `/v1/vaults/${v.vaultId}/published`;
    expect((await call(`${base}/abc123def`, { method: "PUT", body: "{}" })).status).toBe(401);
    expect((await call(`${base}/x`, { method: "PUT", headers: auth(v.deviceToken), body: "{}" })).status).toBe(400);
    const huge = await call(`${base}/abc123def`, {
      method: "PUT",
      headers: auth(v.deviceToken),
      body: JSON.stringify({ title: "big", markdown: "x".repeat(300_000) }),
    });
    expect(huge.status).toBe(413);
    expect((await call(`/p/${v.vaultId}/nothere`)).status).toBe(404);
  });
});
