// Overnight batches (src/batches.ts, learn-pivot plan §C8) against a fake Anthropic Message Batches API.
import { describe, expect, it } from "vitest";
import { NIGHTLY_CAP, step, type Deps, type Store } from "../src/batches";

function store(): Store & { map: Map<string, unknown> } {
  const map = new Map<string, unknown>();
  return { map, get: async <T>(k: string) => structuredClone(map.get(k)) as T | undefined, put: async (k, v) => { map.set(k, structuredClone(v)); } };
}

function question(point: string, over: { totalMarks?: number; value?: number } = {}) {
  return {
    number: "06", stem: "A trolley of mass 2.0 kg moves at 3.0 m s-1.", diagrams: [],
    parts: [{ label: "06.1", text: "Calculate its momentum.", marks: 2, commandWord: "Calculate", answerLine: null,
      answer: { value: over.value ?? 6, unit: "kg m s-1", accept: [5.9, 6.1], text: null },
      scheme: [{ point: "MP1", mark: "M1", ao: "AO1", text: "p = mv" }, { point: "MP2", mark: "A1", ao: "AO2", text: "6.0" }],
      guidance: [], levels: null, indicativeContent: null }],
    totalMarks: over.totalMarks ?? 2,
    tags: { board: "aqa", spec: "aqa-7408", paper: "1", level: "alevel", specPoints: [point], format: ["calculation"], commandWords: ["Calculate"], ao: null, difficulty: 0, madeFrom: ["cat:aqa-7408-1-2025-06-qp#06"] },
  };
}

/** The fake API: batches by id, each with a results function; records every request. */
function fakeApi(write: (customId: string, body: unknown) => unknown, check: (customId: string) => unknown) {
  const batches = new Map<string, { requests: { custom_id: string; params: Record<string, unknown> }[]; ended: boolean }>();
  const calls: { url: string; init?: RequestInit }[] = [];
  let n = 0;
  const fetch: Deps["fetch"] = async (url, init) => {
    calls.push({ url, init });
    if (url.endsWith("/aqa-7408.json")) return Response.json({ docs: [{ id: "aqa-7408-1-2025-06-qp", url: "https://board/qp.pdf" }, { id: "aqa-7408-1-2025-06-ms", url: "https://board/ms.pdf" }] });
    if (url.startsWith("https://board/")) return new Response(new Uint8Array([37, 80, 68, 70]));
    if (url === "https://api.anthropic.com/v1/messages/batches" && init?.method === "POST") {
      const id = `batch_${++n}`;
      batches.set(id, { ...(JSON.parse(String(init.body)) as { requests: { custom_id: string; params: Record<string, unknown> }[] }), ended: false });
      return Response.json({ id, processing_status: "in_progress" });
    }
    const m = /batches\/(batch_\d+)(\/results)?$/.exec(url);
    if (m) {
      const b = batches.get(m[1]!)!;
      if (!m[2]) return Response.json({ id: m[1], processing_status: b.ended ? "ended" : "in_progress", results_url: b.ended ? `${url}/results` : null });
      // Results in reverse order: they must be read by custom_id.
      const lines = [...b.requests].reverse().map((r) => {
        const isCheck = r.custom_id.startsWith("c");
        const out = isCheck ? check(r.custom_id) : write(r.custom_id, r.params);
        return JSON.stringify({ custom_id: r.custom_id, result: { type: "succeeded", message: { content: [{ type: "text", text: JSON.stringify(out) }], usage: { input_tokens: 1000, output_tokens: 500 } } } });
      });
      return new Response(lines.join("\n"));
    }
    return new Response("not found", { status: 404 });
  };
  return { fetch, batches, calls, end: () => { for (const b of batches.values()) b.ended = true; } };
}

function deps(api: ReturnType<typeof fakeApi>, bank: Record<string, { id: string; question: Record<string, unknown> }[]>, limit = 10_000_000) {
  const added: { spec: string; question: Record<string, unknown>; effort: string }[] = [];
  let used = 0;
  const d: Deps = {
    apiKey: "sk-test", fetch: api.fetch,
    bankQuestions: async (s) => bank[s] ?? [], addPending: async (spec, question, effort) => { added.push({ spec, question, effort }); },
    courses: async () => Object.keys(bank), usage: async () => ({ used, limit }), addUsage: async (n) => { used += n; },
  };
  return { d, added, used: () => used };
}

const night = Date.UTC(2026, 10, 6, 2);

describe("overnight batches", () => {
  it("submits, polls, collects by custom_id, checks, and adds the passes as pending", async () => {
    const api = fakeApi((_, params) => ({ brief: "v1", questions: [question(String(JSON.stringify(params)).includes("3.4.1.7") ? "3.4.1.7" : "3.4.1.6")] }),
      () => ({ answers: [{ label: "06.1", value: 6, unit: null, text: null }], problems: [] }));
    const s = store();
    const { d, added, used } = deps(api, { "aqa-7408": [{ id: "a", question: question("3.4.1.6") }, { id: "b", question: question("3.4.1.7") }] });
    expect(await step(s, d, night)).toBe("writing");
    const first = api.batches.get("batch_1")!;
    expect(first.requests.length).toBe(2); // both points are short (1 < 3)
    const p = first.requests[0]!.params as { model: string; output_config: { effort: string; format: { type: string } }; system: { cache_control: unknown }[]; messages: { content: { type: string; cache_control?: unknown }[] }[] };
    expect(p.model).toBe("claude-haiku-5-5");
    expect(p.output_config.effort).toBe("low");
    expect(p.output_config.format.type).toBe("json_schema");
    expect(p.system[0]!.cache_control).toEqual({ type: "ephemeral" });
    expect(p.messages[0]!.content.map((c) => c.type)).toEqual(["document", "document", "text"]);
    expect(p.messages[0]!.content[1]!.cache_control).toEqual({ type: "ephemeral" });
    expect(JSON.stringify(p)).not.toMatch(/temperature|top_p|budget_tokens/);
    expect(await step(s, d, night + 1000)).toBe("writing"); // not ended yet
    api.end();
    expect(await step(s, d, night + 2000)).toBe("checking");
    const checkReq = api.batches.get("batch_2")!.requests[0]!.params as { messages: { content: { text: string }[] }[] };
    expect(checkReq.messages[0]!.content[0]!.text).not.toContain("MP1"); // the checker never sees the scheme
    api.end();
    expect(await step(s, d, night + 3000)).toBe("idle");
    expect(added.map((a) => (a.question.tags as { specPoints: string[] }).specPoints[0]).sort()).toEqual(["3.4.1.6", "3.4.1.7"]);
    expect(added.every((a) => a.effort === "low")).toBe(true);
    expect(used()).toBe(4 * 1500); // two writes and two checks metered
    expect(await step(s, d, night + 4000)).toBe("idle"); // once a night
    expect(api.batches.size).toBe(2);
  });

  it("a failure is rewritten once at medium the next night; a second failure is dropped", async () => {
    let checks = 0;
    const api = fakeApi(() => ({ brief: "v1", questions: [question("3.4.1.6", { totalMarks: 3 })] }), () => { checks++; return { answers: [], problems: [] }; });
    const s = store();
    const { d, added } = deps(api, { "aqa-7408": [{ id: "a", question: question("3.4.1.6") }] });
    await step(s, d, night);
    api.end();
    expect(await step(s, d, night + 1000)).toBe("idle"); // the marks don't add up: no check batch
    expect(checks).toBe(0);
    expect(await step(s, d, night + 86_400_000)).toBe("writing");
    const req = api.batches.get("batch_2")!.requests;
    const effort = (req[0]!.params as { output_config: { effort: string } }).output_config.effort;
    expect(effort).toBe("medium");
    expect(JSON.stringify(req[0]!.params)).toContain("An earlier version had these problems");
    api.end();
    expect(await step(s, d, night + 86_400_000 + 1000)).toBe("idle");
    expect(added.length).toBe(0);
    expect(((await s.get<{ rewrites: unknown[] }>("batch:state"))!.rewrites ?? []).length).toBe(0); // dropped, not retried again
  });

  it("respects the nightly cap and the monthly allowance", async () => {
    const api = fakeApi(() => ({ brief: "v1", questions: [] }), () => ({ answers: [], problems: [] }));
    const bank = { "aqa-7408": Array.from({ length: NIGHTLY_CAP + 50 }, (_, i) => ({ id: `q${i}`, question: question(`9.${i}`) })) };
    const s = store();
    const { d } = deps(api, bank);
    await step(s, d, night);
    expect(api.batches.get("batch_1")!.requests.length).toBe(NIGHTLY_CAP);
    const spent = deps(api, bank, 100);
    await spent.d.addUsage(100);
    const s2 = store();
    expect(await step(s2, spent.d, night)).toBe("idle");
    expect(api.batches.size).toBe(1);
  });
});
