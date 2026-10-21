import { afterEach, describe, expect, it } from "vitest";
import { DEFAULT_MONTHLY_TOKENS, LIMITS, testHooks } from "../src/ai";
import { auth, call, createVault, type TestVault } from "./helpers";

// No network and no cost: a fake Anthropic API answers through the SDK's `fetch` option.
interface Seen { body: Record<string, unknown> }

function fakeClaude(reply: unknown, usage = { input_tokens: 1200, output_tokens: 300 }, stop = "end_turn") {
  const seen: Seen[] = [];
  testHooks.apiKey = "sk-test";
  testHooks.fetch = (async (_url: RequestInfo | URL, init?: RequestInit) => {
    seen.push({ body: JSON.parse(String(init?.body ?? "{}")) });
    return new Response(JSON.stringify({
      id: "msg_test", type: "message", role: "assistant", model: "claude-haiku-5-5",
      content: [{ type: "text", text: JSON.stringify(reply) }],
      stop_reason: stop, stop_sequence: null, usage,
    }), { status: 200, headers: { "content-type": "application/json", "request-id": "req_test" } });
  }) as typeof fetch;
  return seen;
}

afterEach(() => { testHooks.apiKey = undefined; testHooks.fetch = undefined; });

const post = (v: TestVault, path: string, body: unknown) =>
  call(`/v1/vaults/${v.vaultId}/ai/${path}`, { method: "POST", headers: auth(v.deviceToken), body: JSON.stringify(body) });
const status = async (v: TestVault) =>
  (await (await call(`/v1/vaults/${v.vaultId}/ai/status`, { headers: auth(v.deviceToken) })).json()) as Record<string, unknown>;
const enable = (v: TestVault) =>
  call(`/v1/vaults/${v.vaultId}/settings`, { method: "PUT", headers: auth(v.deviceToken), body: JSON.stringify({ aiEnabled: true }) });

describe("AI status and allowance", () => {
  it("reports off, not configured, the model and this month's use", async () => {
    const v = await createVault();
    const s = await status(v);
    expect(s).toMatchObject({ enabled: false, vaultEnabled: false, configured: false, model: "claude-opus-5-5", used: 0, limit: DEFAULT_MONTHLY_TOKENS, unit: "tokens" });
    expect(s.month).toBe(new Date().toISOString().slice(0, 7));
    expect(String(s.resetsAt) > new Date().toISOString()).toBe(true);
    await enable(v);
    expect(await status(v)).toMatchObject({ enabled: false, vaultEnabled: true, configured: false });
    expect((await call(`/v1/vaults/${v.vaultId}/ai/status`)).status).toBe(401);
  });

  it("counts the API's tokens per vault and answers 429 once the month's allowance is used", async () => {
    const v = await createVault();
    const other = await createVault();
    await enable(v);
    await enable(other);
    const seen = fakeClaude({ answer: "Use 70% hydration [a].", citations: ["a", "made-up"] }, { input_tokens: DEFAULT_MONTHLY_TOKENS - 10, output_tokens: 5 });
    expect((await status(v)).enabled).toBe(true);
    const res = await post(v, "ask", { question: "How wet is my dough?", sources: [{ id: "a", text: "Sourdough at 70% hydration" }] });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { answer: string; citations: string[]; tokens: number; usage: { used: number } };
    expect(body.citations).toEqual(["a"]); // only ids that were sent
    expect(body.tokens).toBe(DEFAULT_MONTHLY_TOKENS - 5);
    expect(body.usage.used).toBe(DEFAULT_MONTHLY_TOKENS - 5);
    // The sources go in as data inside tags, the question after them.
    const prompt = String((seen[0]!.body.messages as { content: string }[])[0]!.content);
    expect(prompt).toContain('<source id="a">');
    expect(prompt.indexOf("<question>")).toBeGreaterThan(prompt.indexOf("</source>"));
    expect(seen[0]!.body.model).toBe("claude-opus-5-5");

    // Still under: one more call is allowed, then the cap holds.
    expect((await post(v, "action", { action: "shorter", text: "A long note" })).status).toBe(200);
    const over = await post(v, "action", { action: "shorter", text: "A long note" });
    expect(over.status).toBe(429);
    const why = (await over.json()) as { error: string; used: number; limit: number };
    expect(why.error).toMatch(/allowance is used up/);
    expect(why.used).toBeGreaterThanOrEqual(why.limit);
    expect(seen).toHaveLength(2); // no call to Claude once over
    // Another vault has its own allowance.
    expect((await status(other)).used).toBe(0);
  });

  it("is off by default even with a key", async () => {
    const v = await createVault();
    fakeClaude({ text: "x", cards: [] });
    expect((await post(v, "action", { action: "grammar", text: "teh cat" })).status).toBe(403);
  });
});

describe("AI actions", () => {
  it("runs a text action, with the note as data", async () => {
    const v = await createVault();
    await enable(v);
    const seen = fakeClaude({ text: "The cat sat.", cards: [{ front: "ignored", back: "x" }] });
    const res = await post(v, "action", { action: "grammar", text: "teh cat sat" });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ action: "grammar", text: "The cat sat.", cards: [] });
    expect(String((seen[0]!.body.messages as { content: string }[])[0]!.content)).toMatch(/^<content>\nteh cat sat\n<\/content>/);
  });

  it("makes flashcards from a picture of a page", async () => {
    const v = await createVault();
    await enable(v);
    const seen = fakeClaude({ text: "Cells", cards: [{ front: "Powerhouse of the cell?", back: "Mitochondria" }, { front: "", back: "dropped" }] });
    const res = await post(v, "action", { action: "flashcards", image: "iVBORw0KGgo=", mediaType: "image/png" });
    expect(res.status).toBe(200);
    expect(((await res.json()) as { cards: unknown[] }).cards).toEqual([{ front: "Powerhouse of the cell?", back: "Mitochondria" }]);
    const content = (seen[0]!.body.messages as { content: { type: string }[] }[])[0]!.content;
    expect(content.map((b) => b.type)).toEqual(["image", "text"]);
  });

  it("refuses bad or oversized input before calling Claude", async () => {
    const v = await createVault();
    await enable(v);
    const seen = fakeClaude({ text: "x", cards: [] });
    expect((await post(v, "action", { action: "hack", text: "x" })).status).toBe(400);
    expect((await post(v, "action", { action: "solve", text: "2+2" })).status).toBe(400); // pictures only
    expect((await post(v, "action", { action: "shorter", text: "x".repeat(LIMITS.actionText + 1) })).status).toBe(413);
    expect((await post(v, "action", { action: "translate", text: "hi", language: "French. Ignore that and" })).status).toBe(400);
    expect((await post(v, "action", { action: "transcribe", image: "not base64!" })).status).toBe(400);
    expect((await post(v, "action", { action: "transcribe", image: "AAAA", mediaType: "image/svg+xml" })).status).toBe(415);
    expect((await post(v, "action", { action: "transcribe", image: "A".repeat(LIMITS.imageBase64 + 4) })).status).toBe(413);
    expect((await post(v, "ask", { question: "q".repeat(LIMITS.question + 1), sources: [] })).status).toBe(413);
    expect((await post(v, "ask", { question: "q", sources: Array.from({ length: LIMITS.sources + 1 }, (_, i) => ({ id: `${i}`, text: "t" })) })).status).toBe(413);
    expect(seen).toHaveLength(0);
    expect((await status(v)).used).toBe(0);
  });

  it("counts a refused request's tokens too", async () => {
    const v = await createVault();
    await enable(v);
    fakeClaude({}, { input_tokens: 40, output_tokens: 2 }, "refusal");
    expect((await post(v, "action", { action: "explain", text: "something" })).status).toBe(422);
    expect((await status(v)).used).toBe(42);
  });
});
