// The shared question bank (docs/PROTOCOL.md §4 "Question bank", learn-pivot plan §C7). Questions Trove wrote
// from board papers, with their mark schemes, shared between the vaults on this relay so the bank grows and new
// questions get cheaper. Only devices of vaults on this relay can read or add (vaults need the create code).
//
// - A course's file is served whole (`bank/<spec>.json` in R2), never one topic at a time, so the relay can't see
//   what a student is revising.
// - Nothing that identifies a student is kept: per question, only salted hashes of the vaults that attempted or
//   flagged it (sha256 of question id + vault id), so the same vault can't be linked across questions.
// - Uploads arrive "pending" and are served marked new; 3 different vaults attempting one with no flag make it
//   "good"; "This is wrong" from 2 different vaults takes it out, whatever its state.
// - At most 50 uploads per vault per day; only well-formed questions (shape, every tag, marks that add up, size).
// One Durable Object (name "bank") serialises every change.
import { DurableObject } from "cloudflare:workers";
import { error, json, type Env } from "./vault";

export const BANK_DAILY_UPLOADS = 50;
export const BANK_MAX_BYTES = 32 * 1024;
export const GOOD_AFTER = 3;
export const REMOVE_AFTER = 2;
const SPEC = /^[a-z0-9][a-z0-9-]{1,40}$/;

export interface BankEntry {
  id: string;
  spec: string;
  state: "pending" | "good";
  /** The question as the apps' GeneratedQuestion JSON (stem, parts with schemes, totalMarks, tags). */
  question: Record<string, unknown>;
  brief: string;
  model: string;
  effort: string;
  addedAt: number;
}

interface Stored extends BankEntry {
  attempted: string[];
  flagged: string[];
}

async function sha256Hex(s: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  return [...d].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Why a question can't go in the bank, or null when it's well-formed. */
export function invalidQuestion(q: unknown, spec: string): string | null {
  if (!q || typeof q !== "object" || Array.isArray(q)) return "question must be an object";
  const o = q as Record<string, unknown>;
  if (typeof o.number !== "string" || typeof o.stem !== "string") return "number and stem are required";
  if (!Array.isArray(o.parts) || o.parts.length === 0) return "parts are required";
  if (typeof o.totalMarks !== "number" || !Number.isInteger(o.totalMarks) || o.totalMarks <= 0) return "totalMarks must be a positive whole number";
  let sum = 0;
  for (const p of o.parts as Record<string, unknown>[]) {
    if (!p || typeof p.label !== "string" || typeof p.text !== "string" || typeof p.commandWord !== "string") return "each part needs label, text and commandWord";
    if (typeof p.marks !== "number" || !Number.isInteger(p.marks) || p.marks <= 0) return "each part needs whole marks";
    if (!Array.isArray(p.scheme) || !Array.isArray(p.guidance)) return "each part needs scheme and guidance";
    const levels = Array.isArray(p.levels) && p.levels.length > 0;
    if (!levels) {
      const schemeMarks = (p.scheme as Record<string, unknown>[]).reduce((n, s) => n + markValue(String(s?.mark ?? "")), 0);
      if (schemeMarks !== p.marks) return `part ${p.label}: the scheme gives ${schemeMarks} marks, the part is worth ${p.marks}`;
    }
    sum += p.marks as number;
  }
  if (sum !== o.totalMarks) return `the parts add up to ${sum}, totalMarks is ${o.totalMarks}`;
  const t = o.tags as Record<string, unknown> | undefined;
  if (!t || typeof t !== "object") return "tags are required";
  for (const k of ["board", "spec", "level"]) if (typeof t[k] !== "string" || !(t[k] as string)) return `tags.${k} is required`;
  for (const k of ["specPoints", "format", "commandWords", "madeFrom"]) if (!Array.isArray(t[k]) || (t[k] as unknown[]).length === 0) return `tags.${k} is required`;
  if (t.spec !== spec) return "tags.spec must be the course it's uploaded to";
  return null;
}

/** "M1" → 1, "B2" → 2, "MP3" → 1 (QuestionChecks.markValue in TroveCore). */
export function markValue(mark: string): number {
  const m = mark.trim().toUpperCase();
  if (m.startsWith("MP")) return 1;
  const r = /^[A-Z]{1,2}(\d+)/.exec(m);
  return r ? Number(r[1]) : m ? 1 : 0;
}

export class BankObject extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const vault = request.headers.get("x-trove-vault") ?? "";
    const [, spec, id, action] = url.pathname.split("/"); // /<spec>[/<id>/<action>]
    if (!spec || !SPEC.test(spec)) return error(400, "unknown course");
    if (request.method === "POST" && !id) return this.upload(request, spec, vault);
    if (request.method === "POST" && id && (action === "attempt" || action === "flag")) return this.mark(spec, id, vault, action);
    if (request.method === "GET" && !id) return json(await this.file(spec));
    return error(404, "not found");
  }

  private async upload(request: Request, spec: string, vault: string): Promise<Response> {
    const text = await request.text();
    if (new TextEncoder().encode(text).length > BANK_MAX_BYTES) return error(413, "question too large");
    let body: { question?: unknown; brief?: unknown; model?: unknown; effort?: unknown };
    try { body = JSON.parse(text); } catch { return error(400, "not JSON"); }
    const why = invalidQuestion(body.question, spec);
    if (why) return error(400, why);
    if (typeof body.brief !== "string" || typeof body.model !== "string" || typeof body.effort !== "string") return error(400, "brief, model and effort are required");
    const day = Math.floor(Date.now() / 86_400_000);
    const countKey = `count:${await sha256Hex(`${vault}\n${day}`)}`;
    const count = (await this.ctx.storage.get<number>(countKey)) ?? 0;
    if (count >= BANK_DAILY_UPLOADS) return error(429, "this vault has added its share for today");
    const id = (await sha256Hex(JSON.stringify(body.question))).slice(0, 16);
    const key = `q:${spec}:${id}`;
    if (await this.ctx.storage.get(key)) return json({ id, duplicate: true });
    const entry: Stored = { id, spec, state: "pending", question: body.question as Record<string, unknown>, brief: body.brief, model: body.model,
      effort: body.effort, addedAt: Date.now(), attempted: [], flagged: [] };
    await this.ctx.storage.put({ [key]: entry, [countKey]: count + 1 });
    await this.publish(spec);
    return json({ id, state: entry.state }, 201);
  }

  private async mark(spec: string, id: string, vault: string, action: "attempt" | "flag"): Promise<Response> {
    const key = `q:${spec}:${id}`;
    const entry = await this.ctx.storage.get<Stored>(key);
    if (!entry) return error(404, "not in the bank");
    const who = await sha256Hex(`${id}\n${vault}`);
    const list = action === "attempt" ? entry.attempted : entry.flagged;
    if (!list.includes(who)) list.push(who);
    if (entry.flagged.length >= REMOVE_AFTER) {
      await this.ctx.storage.delete(key);
      await this.publish(spec);
      return json({ id, state: "removed" });
    }
    const clean = entry.attempted.filter((v) => !entry.flagged.includes(v)).length;
    if (entry.state === "pending" && entry.flagged.length === 0 && clean >= GOOD_AFTER) entry.state = "good";
    await this.ctx.storage.put(key, entry);
    await this.publish(spec);
    return json({ id, state: entry.state });
  }

  /** The course's whole file, as served: no hashes, no counts of who. */
  private async file(spec: string): Promise<{ v: 1; spec: string; questions: BankEntry[] }> {
    const rows = await this.ctx.storage.list<Stored>({ prefix: `q:${spec}:` });
    const questions = [...rows.values()].map(({ attempted: _a, flagged: _f, ...e }) => e).sort((a, b) => a.addedAt - b.addedAt || (a.id < b.id ? -1 : 1));
    return { v: 1, spec, questions };
  }

  private async publish(spec: string) {
    await this.env.BLOBS.put(`bank/${spec}.json`, JSON.stringify(await this.file(spec)), { httpMetadata: { contentType: "application/json" } });
  }
}

/**
 * `GET|POST /v1/vaults/:v/bank/:spec[/:id/attempt|flag]`: a device of a vault on this relay only (checked by the
 * vault's own Durable Object). Reads come from R2; changes go through the bank's Durable Object.
 */
export async function bankRoute(request: Request, env: Env, vaultId: string, rest: string[], vaultStub: DurableObjectStub): Promise<Response> {
  if (!env.BANK) return error(404, "not found");
  const who = await vaultStub.fetch(new Request("https://vault/api/info", { headers: { authorization: request.headers.get("authorization") ?? "" } }));
  if (who.status !== 200) return error(who.status === 403 ? 403 : 401, "a device of a vault on this relay is needed");
  const [spec, id, action] = rest;
  if (!spec || !SPEC.test(spec)) return error(400, "unknown course");
  if (request.method === "GET" && !id) {
    const obj = await env.BLOBS.get(`bank/${spec}.json`);
    return new Response(obj ? obj.body : JSON.stringify({ v: 1, spec, questions: [] }), { headers: { "content-type": "application/json" } });
  }
  const bank = env.BANK.get(env.BANK.idFromName("bank"));
  const path = [spec, id, action].filter(Boolean).join("/");
  return bank.fetch(new Request(`https://bank/${path}`, { method: request.method, headers: { "x-trove-vault": vaultId }, body: request.method === "POST" ? await request.text() : undefined }));
}
