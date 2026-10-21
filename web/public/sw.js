// Trove's service worker: the website opens without a connection, then syncs.
// - App files (same origin, GET): network first, so a deploy shows up straight away; the cached copy
//   is used offline or when the network takes longer than a few seconds.
// - /vendor/<name>-<version>/ files never change at a path: cache first.
// - Relay routes (/v1, /dav, /p, /health, /api) and anything not GET are never touched or cached:
//   vault data stays between the page, IndexedDB (sealed, PROTOCOL.md §7) and the relay.
// Bump VERSION when this file's caching changes; old caches are deleted on activate.
const VERSION = "1";
const CACHE = `trove-shell-${VERSION}`;
const SHELL = ["/", "/app.css", "/app.js", "/manifest.webmanifest", "/icon.svg", "/icon-180.png", "/icon-192.png", "/icon-512.png"];
const NEVER = /^\/(v1|dav|p|health|api)(\/|$)/;
const NETWORK_WAIT = 4000;

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL.map((u) => new Request(u, { cache: "reload" })))).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) if (name.startsWith("trove-shell-") && name !== CACHE) await caches.delete(name);
    await self.clients.claim();
  })());
});

/** True for app files this worker may cache. */
function cacheable(url) {
  return url.origin === self.location.origin && !NEVER.test(url.pathname) && url.pathname !== "/sw.js";
}

async function put(request, response) {
  if (!response || !response.ok || response.type !== "basic" || response.status !== 200) return;
  const cache = await caches.open(CACHE);
  await cache.put(request, response);
}

async function cacheFirst(event) {
  const hit = await caches.match(event.request);
  if (hit) return hit;
  const res = await fetch(event.request);
  event.waitUntil(put(event.request, res.clone()));
  return res;
}

async function networkFirst(event, navigate) {
  const network = fetch(event.request).then((res) => {
    event.waitUntil(put(navigate ? "/" : event.request, res.clone()));
    return res;
  });
  event.waitUntil(network.catch(() => {}));
  const fallback = () => caches.match(navigate ? "/" : event.request, { ignoreSearch: navigate });
  let timer;
  const slow = new Promise((resolve) => { timer = setTimeout(resolve, NETWORK_WAIT); });
  try {
    const first = await Promise.race([network, slow]);
    if (first) return first;
    return (await fallback()) ?? (await network);
  } catch (e) {
    const hit = await fallback();
    if (hit) return hit;
    throw e;
  } finally {
    clearTimeout(timer);
  }
}

self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET" || request.headers.has("range")) return;
  const url = new URL(request.url);
  if (!cacheable(url)) return;
  if (url.pathname.startsWith("/vendor/")) { event.respondWith(cacheFirst(event)); return; }
  const navigate = request.mode === "navigate";
  // Only the app page itself is served for navigations (it routes by #hash); others go to the network.
  if (navigate && url.pathname !== "/" && url.pathname !== "/index.html") return;
  event.respondWith(networkFirst(event, navigate));
});

// The page lists the files it loaded before this worker took over (first visit), so they're cached too.
self.addEventListener("message", (event) => {
  if (event.data?.type !== "cache" || !Array.isArray(event.data.urls)) return;
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    for (const raw of event.data.urls.slice(0, 200)) {
      let url;
      try { url = new URL(raw, self.location.origin); } catch { continue; }
      if (!cacheable(url) || url.pathname === "/" || url.search) continue;
      if (await cache.match(url.pathname)) continue;
      try { await put(url.pathname, await fetch(url.pathname)); } catch { /* offline: next time */ }
    }
  })());
});
