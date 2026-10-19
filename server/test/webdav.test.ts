import { describe, expect, it } from "vitest";
import { open, parseEnvelope } from "../src/crypto";
import { auth, call, createVault } from "./helpers";

function basic(user: string, pass: string) {
  return { authorization: "Basic " + btoa(`${user}:${pass}`) };
}

describe("GoodNotes WebDAV", () => {
  it("requires basic auth with an inbox token", async () => {
    expect((await call("/dav/", { method: "PROPFIND" })).status).toBe(401);
    const v = await createVault();
    expect((await call("/dav/", { method: "PROPFIND", headers: basic(v.vaultId, "wrong") })).status).toBe(401);
    expect((await call("/dav/", { method: "OPTIONS", headers: basic(v.vaultId, v.inboxToken) })).headers.get("dav")).toContain("1");
  });

  it("MKCOL + PUT + PROPFIND + MOVE + DELETE, with uploads sealed into the inbox", async () => {
    const v = await createVault();
    const h = basic(v.vaultId, v.inboxToken);
    expect((await call("/dav/Goodnotes", { method: "MKCOL", headers: h })).status).toBe(201);

    const pdf = new Uint8Array(150_000).map((_, i) => i % 251);
    const put = await call("/dav/Goodnotes/Biology%20Notes.pdf", {
      method: "PUT",
      headers: { ...h, "content-type": "application/pdf", "content-length": String(pdf.length) },
      body: pdf,
    });
    expect(put.status).toBe(201);

    const root = await (await call("/dav/", { method: "PROPFIND", headers: { ...h, depth: "1" } })).text();
    expect(root).toContain("/dav/Goodnotes/");
    const folder = await (await call("/dav/Goodnotes", { method: "PROPFIND", headers: { ...h, depth: "1" } })).text();
    expect(folder).toContain("Biology%20Notes.pdf");
    expect(folder).toContain("<d:getcontentlength>150000</d:getcontentlength>");

    expect((await call("/dav/Goodnotes/Biology%20Notes.pdf", { method: "GET", headers: h })).status).toBe(403);
    const head = await call("/dav/Goodnotes/Biology%20Notes.pdf", { method: "HEAD", headers: h });
    expect(head.headers.get("content-length")).toBe("150000");

    // The device can open the sealed upload and sees the original bytes + path.
    const inbox = (await (await call(`/v1/vaults/${v.vaultId}/inbox`, { headers: auth(v.deviceToken) })).json()) as {
      entries: { id: string; davPath: string }[];
    };
    expect(inbox.entries[0]!.davPath).toBe("/Goodnotes/Biology Notes.pdf");
    const sealed = new Uint8Array(await (await call(`/v1/vaults/${v.vaultId}/inbox/${inbox.entries[0]!.id}`, { headers: auth(v.deviceToken) })).arrayBuffer());
    const { header, body } = parseEnvelope(await open(sealed, { recipientPrivateKey: v.keys.privateKey, recipientPublicKey: v.publicKey }));
    expect(header).toMatchObject({ source: "webdav", name: "Biology Notes.pdf", mime: "application/pdf" });
    expect(body).toEqual(pdf);

    const move = await call("/dav/Goodnotes/Biology%20Notes.pdf", {
      method: "MOVE",
      headers: { ...h, destination: "https://relay.test/dav/Goodnotes/Bio.pdf" },
    });
    expect(move.status).toBe(201);
    const moved = (await (await call(`/v1/vaults/${v.vaultId}/inbox`, { headers: auth(v.deviceToken) })).json()) as {
      entries: { davPath: string }[];
    };
    expect(moved.entries[0]!.davPath).toBe("/Goodnotes/Bio.pdf");

    expect((await call("/dav/Goodnotes/Bio.pdf", { method: "DELETE", headers: h })).status).toBe(204);
    expect((await call("/dav/Goodnotes/Bio.pdf", { method: "PROPFIND", headers: { ...h, depth: "0" } })).status).toBe(404);
  });

  it("answers LOCK/UNLOCK so picky clients proceed", async () => {
    const v = await createVault();
    const h = basic(v.vaultId, v.inboxToken);
    const lock = await call("/dav/x.pdf", { method: "LOCK", headers: h });
    expect(lock.status).toBe(200);
    expect(lock.headers.get("lock-token")).toMatch(/opaquelocktoken/);
    expect((await call("/dav/x.pdf", { method: "UNLOCK", headers: h })).status).toBe(204);
  });
});
