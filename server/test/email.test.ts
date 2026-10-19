import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "../src/index";
import type { Env } from "../src/vault";
import { open, parseEnvelope } from "../src/crypto";
import { auth, call, createVault } from "./helpers";

const RAW = [
  "From: Shop <orders@shop.example>",
  "To: save@trove.example",
  "Subject: Your receipt #1234",
  "Date: Mon, 19 Oct 2026 10:00:00 +0000",
  "MIME-Version: 1.0",
  'Content-Type: multipart/mixed; boundary="XYZ"',
  "",
  "--XYZ",
  "Content-Type: text/html; charset=utf-8",
  "",
  "<p>Thanks! Order total <b>£20</b></p>",
  "--XYZ",
  'Content-Type: application/pdf; name="receipt.pdf"',
  'Content-Disposition: attachment; filename="receipt.pdf"',
  "Content-Transfer-Encoding: base64",
  "",
  btoa("%PDF-1.7 fake receipt"),
  "--XYZ--",
  "",
].join("\r\n");

function message(raw: string, to: string) {
  let rejected: string | undefined;
  const bytes = new TextEncoder().encode(raw);
  const msg = {
    from: "orders@shop.example",
    to,
    headers: new Headers(),
    raw: new Response(bytes).body!,
    rawSize: bytes.length,
    setReject: (reason: string) => { rejected = reason; },
    forward: async () => {},
    reply: async () => {},
  } as unknown as ForwardableEmailMessage;
  return { msg, rejected: () => rejected };
}

describe("email-in", () => {
  it("rejects mail when no vault is configured", async () => {
    const m = message(RAW, "save@trove.example");
    await worker.email!(m.msg, { ...(env as unknown as Env), EMAIL_VAULT_ID: "" });
    expect(m.rejected()).toMatch(/not connected/);
  });

  it("turns an email into a sealed body entry plus one entry per attachment, linked by groupId", async () => {
    const v = await createVault();
    const m = message(RAW, "save@trove.example");
    await worker.email!(m.msg, { ...(env as unknown as Env), EMAIL_VAULT_ID: v.vaultId });
    expect(m.rejected()).toBeUndefined();

    const list = (await (await call(`/v1/vaults/${v.vaultId}/inbox`, { headers: auth(v.deviceToken) })).json()) as {
      entries: { id: string; source: string }[];
    };
    expect(list.entries.map((e) => e.source)).toEqual(["email", "email"]);

    const opened = [];
    for (const e of list.entries) {
      const sealed = new Uint8Array(await (await call(`/v1/vaults/${v.vaultId}/inbox/${e.id}`, { headers: auth(v.deviceToken) })).arrayBuffer());
      opened.push(parseEnvelope(await open(sealed, { recipientPrivateKey: v.keys.privateKey, recipientPublicKey: v.publicKey })));
    }
    const [body, attachment] = opened;
    expect(body!.header).toMatchObject({ source: "email", mime: "text/html", title: "Your receipt #1234" });
    expect(body!.header.meta).toMatchObject({ from: "orders@shop.example", attachments: 1 });
    expect(new TextDecoder().decode(body!.body)).toContain("Order total <b>£20</b>");
    expect(attachment!.header).toMatchObject({ name: "receipt.pdf", mime: "application/pdf" });
    expect(attachment!.header.groupId).toBe(body!.header.groupId);
    expect(new TextDecoder().decode(attachment!.body)).toBe("%PDF-1.7 fake receipt");
  });
});
