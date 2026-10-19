// Worker entry: routes /v1/vaults/:vault/* and /dav/* to the vault's Durable Object, creates vaults,
// and turns incoming email (Cloudflare Email Routing) into sealed inbox entries.
import PostalMime from "postal-mime";
import { b64uDecode, randomId, type InboxHeader } from "./crypto";
import { error, json, type Env } from "./vault";

export { VaultObject } from "./vault";

const VERSION = "0.1.0";
const VAULT_ID = /^[A-Za-z0-9_-]{16,64}$/;

function stub(env: Env, vaultId: string) {
  return env.VAULT.get(env.VAULT.idFromName(vaultId));
}

/** Forward to the Durable Object under an internal path, keeping method, headers and body. */
function forward(env: Env, vaultId: string, request: Request, path: string): Promise<Response> {
  const url = new URL(request.url);
  url.pathname = path;
  return stub(env, vaultId).fetch(new Request(url.toString(), request));
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);

    if (url.pathname === "/health") return json({ ok: true, version: VERSION });

    if (parts[0] === "v1" && parts[1] === "vaults") {
      if (parts.length === 2 && request.method === "POST") {
        if (env.ALLOW_NEW_VAULTS === "false") return error(403, "this relay isn't accepting new vaults");
        const body = (await request.json().catch(() => ({}))) as { vaultPublicKey?: string; deviceName?: string; deviceKind?: string; deviceId?: string };
        if (!body.vaultPublicKey || b64uDecode(body.vaultPublicKey).length !== 32) return error(400, "vaultPublicKey (32-byte X25519, b64u) required");
        const vaultId = randomId();
        const init = new Request("https://vault/internal/init", {
          method: "POST",
          body: JSON.stringify({ vaultId, vaultPublicKey: body.vaultPublicKey, deviceName: body.deviceName, deviceKind: body.deviceKind, deviceId: body.deviceId }),
        });
        return stub(env, vaultId).fetch(init);
      }
      const vaultId = parts[2];
      if (!vaultId || !VAULT_ID.test(vaultId)) return error(404, "not found");
      return forward(env, vaultId, request, "/api/" + parts.slice(3).join("/"));
    }

    if (parts[0] === "p" && parts.length === 3 && request.method === "GET") {
      const [, vaultId, slug] = parts;
      if (!VAULT_ID.test(vaultId!) || !/^[A-Za-z0-9_-]{6,64}$/.test(slug!)) return error(404, "not found");
      return stub(env, vaultId!).fetch(new Request(`https://vault/public/${slug}`));
    }

    if (parts[0] === "dav") {
      // Basic auth username is the vault id.
      const auth = request.headers.get("authorization") ?? "";
      const user = auth.startsWith("Basic ") ? atob(auth.slice(6)).split(":")[0] ?? "" : "";
      if (!VAULT_ID.test(user)) {
        return new Response("Authentication required", { status: 401, headers: { "WWW-Authenticate": 'Basic realm="Trove"' } });
      }
      const res = await forward(env, user, request, "/dav/" + parts.slice(1).join("/"));
      if (res.status === 401) {
        return new Response("Authentication required", { status: 401, headers: { "WWW-Authenticate": 'Basic realm="Trove"' } });
      }
      return res;
    }

    return error(404, "not found");
  },

  /** Cloudflare Email Routing → "Send to Worker". Each email becomes 1 + N sealed inbox entries. */
  async email(message: ForwardableEmailMessage, env: Env): Promise<void> {
    if (!env.EMAIL_VAULT_ID) {
      message.setReject("This address is not connected to a Trove vault");
      return;
    }
    const parsed = await PostalMime.parse(message.raw);
    const groupId = randomId();
    const base = { v: 1 as const, source: "email" as const, receivedAt: new Date().toISOString(), groupId };
    const send = (header: InboxHeader, body: Uint8Array) =>
      stub(env, env.EMAIL_VAULT_ID).fetch(
        new Request("https://vault/internal/inbox", {
          method: "POST",
          headers: { "x-trove-envelope": JSON.stringify(header) },
          body,
        }),
      );

    const bodyText = parsed.html ?? parsed.text ?? "";
    await send(
      {
        ...base,
        name: "email.html",
        mime: parsed.html ? "text/html" : "text/plain",
        title: parsed.subject ?? "(no subject)",
        meta: { from: parsed.from?.address, to: message.to, date: parsed.date, attachments: parsed.attachments.length },
      },
      new TextEncoder().encode(bodyText),
    );
    for (const attachment of parsed.attachments) {
      const content =
        typeof attachment.content === "string" ? new TextEncoder().encode(attachment.content) : new Uint8Array(attachment.content);
      await send({ ...base, name: attachment.filename ?? "attachment", mime: attachment.mimeType }, content);
    }
  },
} satisfies ExportedHandler<Env>;
