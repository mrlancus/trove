// The shared question bank (src/bank.ts, PROTOCOL.md §4 "Question bank", learn-pivot plan §C7).
import { describe, expect, it } from "vitest";
import { auth, call, createVault } from "./helpers";

function question(spec = "aqa-7408", over: Record<string, unknown> = {}) {
  return {
    number: "06", stem: "A ball of mass 0.20 kg is thrown horizontally at 12 m s-1.", diagrams: [],
    parts: [
      { label: "06.1", text: "Calculate its momentum.", marks: 2, commandWord: "Calculate", answerLine: null,
        answer: { value: 2.4, unit: "kg m s-1", accept: [2.35, 2.45], text: null },
        scheme: [{ point: "MP1", mark: "M1", ao: "AO1", text: "p = mv" }, { point: "MP2", mark: "A1", ao: "AO2", text: "2.4" }],
        guidance: [], levels: null, indicativeContent: null },
    ],
    totalMarks: 2,
    tags: { board: "aqa", spec, paper: "1", level: "alevel", specPoints: ["3.4.1.6"], format: ["calculation"], commandWords: ["Calculate"], ao: null, difficulty: 0, madeFrom: ["aqa-7408-1-2025-06-qp#06"] },
    ...over,
  };
}
const body = (q: unknown) => JSON.stringify({ question: q, brief: "v1", model: "claude-haiku-5-5", effort: "low" });
const post = (v: { vaultId: string; deviceToken: string }, path: string, b?: string) =>
  call(`/v1/vaults/${v.vaultId}/bank/${path}`, { method: "POST", headers: auth(v.deviceToken), body: b ?? "{}" });
const file = async (v: { vaultId: string; deviceToken: string }, spec: string) =>
  (await (await call(`/v1/vaults/${v.vaultId}/bank/${spec}`, { headers: auth(v.deviceToken) })).json()) as { questions: { id: string; state: string }[] };

describe("the shared question bank", () => {
  it("needs a device of a vault on this relay to read or add", async () => {
    const v = await createVault();
    expect((await call(`/v1/vaults/${v.vaultId}/bank/aqa-7408`)).status).toBe(401);
    expect((await call(`/v1/vaults/${v.vaultId}/bank/aqa-7408`, { method: "POST", headers: auth("tdv_nope"), body: body(question()) })).status).toBe(401);
    expect((await call(`/v1/vaults/${v.vaultId}/bank/aqa-7408`, { method: "POST", headers: auth(v.inboxToken), body: body(question()) })).status).toBe(403);
    expect((await post(v, "aqa-7408", body(question()))).status).toBe(201);
    const f = await file(v, "aqa-7408");
    expect(f.questions.length).toBe(1);
    expect(f.questions[0]!.state).toBe("pending");
    expect(JSON.stringify(f)).not.toContain(v.vaultId);
  });

  it("refuses malformed questions, the wrong course and oversize uploads", async () => {
    const v = await createVault();
    expect((await post(v, "ocr-h556", body(question("ocr-h556", { totalMarks: 3 })))).status).toBe(400);
    const short = question("ocr-h556");
    (short.parts[0] as { scheme: unknown[] }).scheme.pop();
    expect((await post(v, "ocr-h556", body(short))).status).toBe(400);
    const untagged = question("ocr-h556");
    (untagged.tags as { specPoints: string[] }).specPoints = [];
    expect((await post(v, "ocr-h556", body(untagged))).status).toBe(400);
    expect((await post(v, "ocr-h556", body(question("aqa-7408")))).status).toBe(400); // tagged for another course
    expect((await post(v, "ocr-h556", body(question("ocr-h556", { stem: "x".repeat(40_000) })))).status).toBe(413);
    expect((await post(v, "ocr-h556", "not json")).status).toBe(400);
    expect((await file(v, "ocr-h556")).questions.length).toBe(0);
  });

  it("limits uploads per vault per day", async () => {
    const v = await createVault();
    for (let i = 0; i < 50; i++) expect((await post(v, "cie-0625", body(question("cie-0625", { number: `n${i}` })))).status).toBe(201);
    expect((await post(v, "cie-0625", body(question("cie-0625", { number: "n50" })))).status).toBe(429);
    const other = await createVault("Other Mac");
    expect((await post(other, "cie-0625", body(question("cie-0625", { number: "n51" })))).status).toBe(201);
  });

  it("3 clean attempts from different vaults make it good; 2 flags take it out", async () => {
    const vaults = await Promise.all([1, 2, 3, 4].map((i) => createVault(`Mac ${i}`)));
    const [a, b, c, d] = vaults as [typeof vaults[0], typeof vaults[0], typeof vaults[0], typeof vaults[0]];
    const { id } = (await (await post(a, "aqa-8461", body(question("aqa-8461")))).json()) as { id: string };
    await post(a, `aqa-8461/${id}/attempt`);
    await post(a, `aqa-8461/${id}/attempt`); // the same vault twice counts once
    await post(b, `aqa-8461/${id}/attempt`);
    expect((await file(a, "aqa-8461")).questions[0]!.state).toBe("pending");
    await post(c, `aqa-8461/${id}/attempt`);
    expect((await file(a, "aqa-8461")).questions[0]!.state).toBe("good");
    await post(d, `aqa-8461/${id}/flag`);
    await post(d, `aqa-8461/${id}/flag`); // one vault's flag counts once
    expect((await file(a, "aqa-8461")).questions.length).toBe(1);
    expect((await (await post(b, `aqa-8461/${id}/flag`)).json())).toMatchObject({ state: "removed" });
    expect((await file(a, "aqa-8461")).questions.length).toBe(0);
    expect((await post(b, `aqa-8461/${id}/attempt`)).status).toBe(404);
  });

  it("a flagged question never becomes good", async () => {
    const vaults = await Promise.all([1, 2, 3, 4].map((i) => createVault(`iPad ${i}`)));
    const { id } = (await (await post(vaults[0]!, "aqa-7405", body(question("aqa-7405")))).json()) as { id: string };
    await post(vaults[0]!, `aqa-7405/${id}/flag`);
    for (const v of vaults.slice(1)) await post(v, `aqa-7405/${id}/attempt`);
    expect((await file(vaults[0]!, "aqa-7405")).questions[0]!.state).toBe("pending");
  });
});
