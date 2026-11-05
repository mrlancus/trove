// The 8-digit code that creating a vault needs (PROTOCOL.md §4 "Creating a vault", learn-pivot plan §7 E2).
// The code is the Worker secret VAULT_CREATE_CODE, set by the relay's owner; it's never in the repo or a log.
// Wrong codes are limited, because 100 million codes can be tried quickly otherwise:
//   - 5 wrong codes per IP an hour (the next try from that IP is refused, right or wrong);
//   - 50 wrong codes an hour across the whole relay, after which creation pauses for an hour.
// The counts live in one small Durable Object (GateObject, name "create").
import { DurableObject } from "cloudflare:workers";
import { error, json, type Env } from "./vault";

export const CREATE_CODE_HEADER = "x-trove-create-code";
export const PER_IP_WRONG = 5;
export const GLOBAL_WRONG = 50;
export const WINDOW_MS = 60 * 60 * 1000;

/** Constant-time comparison: both sides are hashed, then every byte compared. */
export async function sameCode(given: string, expected: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([given, expected].map(async (s) => new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(s)))));
  let diff = 0;
  for (let i = 0; i < a!.length; i++) diff |= a![i]! ^ b![i]!;
  return diff === 0;
}

interface Counts { wrong: number[]; }

/** Counts wrong codes per IP and in total, over the last hour. */
export class GateObject extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const now = Date.now();
    const ip = url.searchParams.get("ip") ?? "unknown";
    const ipKey = `ip:${ip}`;
    const recent = async (key: string) => ((await this.ctx.storage.get<Counts>(key))?.wrong ?? []).filter((t) => now - t < WINDOW_MS);
    if (url.pathname === "/check") {
      const [mine, all] = await Promise.all([recent(ipKey), recent("all")]);
      return json({ allowed: mine.length < PER_IP_WRONG && all.length < GLOBAL_WRONG });
    }
    if (url.pathname === "/wrong") {
      const [mine, all] = await Promise.all([recent(ipKey), recent("all")]);
      mine.push(now);
      all.push(now);
      await this.ctx.storage.put({ [ipKey]: { wrong: mine }, all: { wrong: all } });
      // Forget this IP an hour after its last wrong try.
      await this.ctx.storage.setAlarm(now + WINDOW_MS + 1000);
      return json({ ok: true });
    }
    return error(404, "not found");
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    for (const [key, value] of await this.ctx.storage.list<Counts>()) {
      if (!value.wrong.some((t) => now - t < WINDOW_MS)) await this.ctx.storage.delete(key);
    }
  }
}

/**
 * Checks the create code on `POST /v1/vaults`. Returns a response to send instead, or null to go ahead.
 * No secret set: as before (anyone may create, unless ALLOW_NEW_VAULTS is "false").
 */
export async function checkCreateCode(request: Request, env: Env): Promise<Response | null> {
  const expected = env.VAULT_CREATE_CODE;
  if (!expected || !env.GATE) return null;
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  const gate = env.GATE.get(env.GATE.idFromName("create"));
  const q = `?ip=${encodeURIComponent(ip)}`;
  const status = (await (await gate.fetch(`https://gate/check${q}`)).json()) as { allowed: boolean };
  if (!status.allowed) {
    return json({ error: "too many wrong codes; try again in an hour", code: "create_code_limited" }, 429);
  }
  const given = (request.headers.get(CREATE_CODE_HEADER) ?? "").trim();
  if (!given) return json({ error: "this relay needs its code to create a vault", code: "create_code_required" }, 403);
  if (!(await sameCode(given, expected))) {
    await gate.fetch(`https://gate/wrong${q}`, { method: "POST" });
    return json({ error: "that code isn't right", code: "create_code_required" }, 403);
  }
  return null;
}
