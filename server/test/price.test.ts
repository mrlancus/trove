import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { extractPrice } from "../src/price";
import type { Env, VaultObject } from "../src/vault";
import { auth, call, createVault } from "./helpers";

const HOUR = 3_600_000;

function vaultStub(vaultId: string) {
  const ns = (env as unknown as Env).VAULT;
  return ns.get(ns.idFromName(vaultId)) as DurableObjectStub<VaultObject>;
}

function productPage(price: string | number, currency = "GBP") {
  return `<html><head><script type="application/ld+json">
  {"@context":"https://schema.org","@graph":[{"@type":"WebPage"},{"@type":"Product","name":"Kettle",
   "offers":{"@type":"Offer","price":${JSON.stringify(price)},"priceCurrency":"${currency}"}}]}
  </script></head><body>Kettle</body></html>`;
}

describe("extractPrice", () => {
  it("reads schema.org Product offers, including inside @graph and AggregateOffer", () => {
    expect(extractPrice(productPage("49.99"))).toEqual({ amount: 49.99, currency: "GBP" });
    expect(extractPrice(productPage(1299, "USD"))).toEqual({ amount: 1299, currency: "USD" });
    const aggregate = `<script type="application/ld+json">{"@type":["Product"],"offers":{"@type":"AggregateOffer","lowPrice":"19.50","priceCurrency":"EUR"}}</script>`;
    expect(extractPrice(aggregate)).toEqual({ amount: 19.5, currency: "EUR" });
  });

  it("handles thousands separators and decimal commas", () => {
    expect(extractPrice(productPage("1,299.00", "USD"))?.amount).toBe(1299);
    expect(extractPrice(productPage("12,50", "EUR"))?.amount).toBe(12.5);
  });

  it("falls back to product meta tags", () => {
    const html = `<meta property="product:price:amount" content="24.00"><meta property="product:price:currency" content="USD">`;
    expect(extractPrice(html)).toEqual({ amount: 24, currency: "USD" });
  });

  it("returns null when there's no price, and skips broken JSON-LD", () => {
    expect(extractPrice("<html><body>nothing</body></html>")).toBeNull();
    expect(extractPrice(`<script type="application/ld+json">{oops</script>${productPage("5")}`)?.amount).toBe(5);
  });
});

describe("price watches", () => {
  it("adds, lists and deletes watches; only http(s) URLs", async () => {
    const v = await createVault();
    const base = `/v1/vaults/${v.vaultId}/watches`;
    const bad = await call(`${base}/watch-0001`, { method: "PUT", headers: auth(v.deviceToken), body: JSON.stringify({ url: "file:///etc/passwd" }) });
    expect(bad.status).toBe(400);
    const put = await call(`${base}/watch-0001`, {
      method: "PUT",
      headers: auth(v.deviceToken),
      body: JSON.stringify({ url: "https://shop.example/kettle", itemId: "item-1" }),
    });
    expect(put.status).toBe(201);
    expect(await put.json()).toMatchObject({ id: "watch-0001", url: "https://shop.example/kettle", itemId: "item-1", price: null });
    const again = await call(`${base}/watch-0001`, { method: "PUT", headers: auth(v.deviceToken), body: JSON.stringify({ url: "https://shop.example/kettle" }) });
    expect(again.status).toBe(200);

    const list = (await (await call(base, { headers: auth(v.deviceToken) })).json()) as { watches: { id: string }[] };
    expect(list.watches.map((w) => w.id)).toEqual(["watch-0001"]);
    expect((await call(`${base}/watch-0001`, { method: "DELETE", headers: auth(v.deviceToken) })).status).toBe(204);
    const empty = (await (await call(base, { headers: auth(v.deviceToken) })).json()) as { watches: unknown[] };
    expect(empty.watches).toHaveLength(0);
    expect((await call(base)).status).toBe(401);
  });

  it("re-checks prices, keeps history and the lowest price, and pings devices on a drop", async () => {
    const v = await createVault();
    await call(`/v1/vaults/${v.vaultId}/watches/watch-0002`, {
      method: "PUT",
      headers: auth(v.deviceToken),
      body: JSON.stringify({ url: "https://shop.example/kettle", itemId: "item-2" }),
    });

    const res = await call(`/v1/vaults/${v.vaultId}/live?token=${v.deviceToken}`, { headers: { upgrade: "websocket" } });
    const ws = res.webSocket!;
    ws.accept();
    const message = new Promise<string>((resolve) => ws.addEventListener("message", (e) => resolve(e.data as string)));

    const prices = ["59.99", "59.99", "44.00"];
    const t0 = Date.now();
    await runInDurableObject(vaultStub(v.vaultId), async (vault: VaultObject, state) => {
      await state.storage.deleteAlarm(); // drive the checks by hand instead
      const urls: string[] = [];
      vault.fetchPage = async (input) => {
        urls.push(String(input));
        return new Response(productPage(prices.shift()!));
      };
      expect(await vault.checkWatches(t0)).toBe(1);
      expect(await vault.checkWatches(t0 + HOUR)).toBe(0); // not due yet
      expect(await vault.checkWatches(t0 + 12 * HOUR)).toBe(1);
      expect(await vault.checkWatches(t0 + 24 * HOUR)).toBe(1);
      expect(urls).toEqual(Array(3).fill("https://shop.example/kettle"));
    });

    expect(JSON.parse(await message)).toEqual({ type: "price", id: "watch-0002", itemId: "item-2", price: 44, previous: 59.99, currency: "GBP" });
    ws.close();

    const list = (await (await call(`/v1/vaults/${v.vaultId}/watches`, { headers: auth(v.deviceToken) })).json()) as {
      watches: { price: number; lowest: number; currency: string; history: { price: number }[]; droppedAt: number; error: null }[];
    };
    expect(list.watches[0]).toMatchObject({ price: 44, lowest: 44, currency: "GBP", droppedAt: t0 + 24 * HOUR, error: null });
    expect(list.watches[0]!.history.map((h) => h.price)).toEqual([59.99, 44]);
  });

  it("records an error when the page has no price", async () => {
    const v = await createVault();
    await call(`/v1/vaults/${v.vaultId}/watches/watch-0003`, {
      method: "PUT",
      headers: auth(v.deviceToken),
      body: JSON.stringify({ url: "https://shop.example/blank" }),
    });
    await runInDurableObject(vaultStub(v.vaultId), async (vault: VaultObject, state) => {
      await state.storage.deleteAlarm();
      vault.fetchPage = async () => new Response("<html></html>");
      await vault.checkWatches();
    });
    const list = (await (await call(`/v1/vaults/${v.vaultId}/watches`, { headers: auth(v.deviceToken) })).json()) as {
      watches: { error: string; price: null }[];
    };
    expect(list.watches[0]).toMatchObject({ error: "no price found on the page", price: null });
  });
});
