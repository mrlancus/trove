// Minimal write-only WebDAV endpoint so GoodNotes "Auto Backup → WebDAV" lands notebooks in the
// sealed inbox. We never keep plaintext, so GET of a file is refused; PROPFIND/HEAD answer from the
// listing we record on upload, which is all a backup client needs.
import type { VaultObject } from "./vault";

const DAV_HEADERS = { DAV: "1, 2", "MS-Author-Via": "DAV" };

function normalise(path: string): string {
  const decoded = decodeURIComponent(path);
  const clean = ("/" + decoded).replace(/\/+/g, "/");
  return clean.length > 1 ? clean.replace(/\/$/, "") : "/";
}

function escapeXml(s: string): string {
  return s.replace(/[<>&'"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&apos;", '"': "&quot;" })[c]!);
}

function entryXml(href: string, isDir: boolean, size: number, etag: string, updated: number): string {
  const encoded = href.split("/").map(encodeURIComponent).join("/");
  return `<d:response><d:href>/dav${escapeXml(encoded)}${isDir && href !== "/" ? "/" : ""}</d:href><d:propstat><d:prop>
<d:resourcetype>${isDir ? "<d:collection/>" : ""}</d:resourcetype>
${isDir ? "" : `<d:getcontentlength>${size}</d:getcontentlength><d:getcontenttype>application/octet-stream</d:getcontenttype>`}
<d:getetag>"${etag}"</d:getetag><d:getlastmodified>${new Date(updated).toUTCString()}</d:getlastmodified>
</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>`;
}

function multistatus(body: string): Response {
  return new Response(`<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">${body}</d:multistatus>`, {
    status: 207,
    headers: { "content-type": 'application/xml; charset="utf-8"', ...DAV_HEADERS },
  });
}

function parentDirs(path: string): string[] {
  const parts = path.split("/").filter(Boolean);
  return parts.slice(0, -1).map((_, i) => "/" + parts.slice(0, i + 1).join("/"));
}

export async function handleDav(vault: VaultObject, request: Request, rawPath: string): Promise<Response> {
  const path = normalise(rawPath);
  const method = request.method.toUpperCase();

  switch (method) {
    case "OPTIONS":
      return new Response(null, {
        status: 200,
        headers: { ...DAV_HEADERS, Allow: "OPTIONS, PROPFIND, MKCOL, PUT, HEAD, DELETE, MOVE, LOCK, UNLOCK" },
      });

    case "PROPFIND": {
      const depth = request.headers.get("depth") ?? "1";
      if (path === "/") {
        const children = depth === "0" ? [] : vault.davList("/").filter((r) => r.path.split("/").length === 2);
        return multistatus(
          entryXml("/", true, 0, "root", Date.now()) +
            children.map((r) => entryXml(r.path, r.is_dir === 1, r.size, r.etag, r.updated_at)).join(""),
        );
      }
      const item = vault.davGet(path);
      if (!item) return new Response(null, { status: 404, headers: DAV_HEADERS });
      let body = entryXml(item.path, item.is_dir === 1, item.size, item.etag, item.updated_at);
      if (item.is_dir === 1 && depth !== "0") {
        const depthOf = path.split("/").length + 1;
        body += vault
          .davList(path)
          .filter((r) => r.path !== path && r.path.split("/").length === depthOf)
          .map((r) => entryXml(r.path, r.is_dir === 1, r.size, r.etag, r.updated_at))
          .join("");
      }
      return multistatus(body);
    }

    case "MKCOL":
      if (vault.davGet(path)) return new Response(null, { status: 405, headers: DAV_HEADERS });
      for (const dir of parentDirs(path)) if (!vault.davGet(dir)) vault.davPut(dir, 0, true);
      vault.davPut(path, 0, true);
      return new Response(null, { status: 201, headers: DAV_HEADERS });

    case "PUT": {
      const length = Number(request.headers.get("content-length"));
      if (!request.body || !Number.isFinite(length)) return new Response("Content-Length required", { status: 411 });
      const name = path.split("/").pop() ?? "upload";
      await vault.sealIntoInbox(
        {
          v: 1,
          source: "webdav",
          receivedAt: new Date().toISOString(),
          name,
          mime: request.headers.get("content-type") ?? (name.toLowerCase().endsWith(".pdf") ? "application/pdf" : "application/octet-stream"),
          meta: { davPath: path },
        },
        request.body,
        length,
        path,
      );
      for (const dir of parentDirs(path)) if (!vault.davGet(dir)) vault.davPut(dir, 0, true);
      const etag = vault.davPut(path, length, false);
      return new Response(null, { status: 201, headers: { ...DAV_HEADERS, ETag: `"${etag}"` } });
    }

    case "HEAD": {
      const item = vault.davGet(path);
      if (!item && path !== "/") return new Response(null, { status: 404 });
      return new Response(null, {
        status: 200,
        headers: { ...DAV_HEADERS, "content-length": String(item?.size ?? 0), ETag: `"${item?.etag ?? "root"}"` },
      });
    }

    case "GET":
      // Contents are end-to-end encrypted; the server cannot serve them back.
      return new Response("Trove WebDAV is write-only", { status: path === "/" ? 200 : 403, headers: DAV_HEADERS });

    case "DELETE":
      vault.davDelete(path);
      return new Response(null, { status: 204, headers: DAV_HEADERS });

    case "MOVE": {
      const destination = request.headers.get("destination");
      if (!destination) return new Response(null, { status: 400 });
      const to = normalise(new URL(destination, request.url).pathname.replace(/^\/dav/, ""));
      const existed = vault.davGet(to);
      if (!vault.davMove(path, to)) return new Response(null, { status: 404 });
      return new Response(null, { status: existed ? 204 : 201, headers: DAV_HEADERS });
    }

    case "LOCK": {
      const token = `opaquelocktoken:${crypto.randomUUID()}`;
      const xml = `<?xml version="1.0" encoding="utf-8"?><d:prop xmlns:d="DAV:"><d:lockdiscovery><d:activelock>
<d:locktype><d:write/></d:locktype><d:lockscope><d:exclusive/></d:lockscope><d:depth>0</d:depth>
<d:timeout>Second-3600</d:timeout><d:locktoken><d:href>${token}</d:href></d:locktoken></d:activelock></d:lockdiscovery></d:prop>`;
      return new Response(xml, {
        status: 200,
        headers: { "content-type": 'application/xml; charset="utf-8"', "Lock-Token": `<${token}>`, ...DAV_HEADERS },
      });
    }

    case "UNLOCK":
      return new Response(null, { status: 204, headers: DAV_HEADERS });

    default:
      return new Response(null, { status: 405, headers: DAV_HEADERS });
  }
}
