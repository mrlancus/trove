// Price-drop watches (PROTOCOL.md §5). Opt-in per item: the relay sees the product URL (never the
// item itself), re-checks the page's schema.org Product price on a Durable Object alarm, and pings
// devices when it drops.

export interface Price {
  amount: number;
  currency: string | null;
}

/** Finds the price on a product page: schema.org JSON-LD first, then common meta tags. */
export function extractPrice(html: string): Price | null {
  for (const block of html.matchAll(/<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)) {
    let json: unknown;
    try {
      json = JSON.parse(decodeEntities(block[1]!.trim()));
    } catch {
      continue;
    }
    for (const node of flatten(json)) {
      const types = ([] as unknown[]).concat(node["@type"] ?? []);
      if (!types.includes("Product") && !types.includes("ProductGroup")) continue;
      const offers = ([] as unknown[]).concat(node.offers ?? []);
      for (const raw of offers) {
        const offer = raw as Record<string, unknown>;
        const inner = ([] as unknown[]).concat(offer.offers ?? [])[0] as Record<string, unknown> | undefined;
        const source = inner ?? offer;
        const amount = toNumber(source.price ?? source.lowPrice ?? (source.priceSpecification as Record<string, unknown> | undefined)?.price);
        if (amount !== null) return { amount, currency: (source.priceCurrency as string | undefined) ?? null };
      }
    }
  }
  const meta = (name: string) => {
    const m = html.match(new RegExp(`<meta[^>]+(?:property|name|itemprop)=["']${name}["'][^>]*>`, "i"))?.[0];
    return m?.match(/content=["']([^"']*)["']/i)?.[1] ?? null;
  };
  const amount = toNumber(meta("product:price:amount") ?? meta("og:price:amount") ?? meta("price"));
  if (amount !== null) return { amount, currency: meta("product:price:currency") ?? meta("og:price:currency") ?? meta("priceCurrency") };
  return null;
}

function flatten(json: unknown): Record<string, unknown>[] {
  if (Array.isArray(json)) return json.flatMap(flatten);
  if (!json || typeof json !== "object") return [];
  const node = json as Record<string, unknown>;
  return [node, ...flatten(node["@graph"] ?? []), ...flatten(node.mainEntity ?? [])];
}

function toNumber(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string") {
    const n = Number(v.replace(/[^0-9.,-]/g, "").replace(/,(?=\d{3}\b)/g, "").replace(",", "."));
    return Number.isFinite(n) && v.trim() !== "" ? n : null;
  }
  return null;
}

function decodeEntities(s: string): string {
  return s.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
}

/** Fetches a product page like a browser would and returns its price (or an error message). */
export async function checkPrice(url: string, fetcher: typeof fetch = fetch): Promise<Price | { error: string }> {
  try {
    const res = await fetcher(url, {
      headers: {
        "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
        accept: "text/html,application/xhtml+xml",
      },
      redirect: "follow",
    });
    if (!res.ok) return { error: `HTTP ${res.status}` };
    const html = (await res.text()).slice(0, 3_000_000);
    return extractPrice(html) ?? { error: "no price found on the page" };
  } catch (e) {
    return { error: e instanceof Error ? e.message : String(e) };
  }
}
