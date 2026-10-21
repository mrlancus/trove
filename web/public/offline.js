// Registers the service worker (sw.js) so the website opens without a connection and installs to
// the home screen. On the first visit the page loads before the worker runs, so it's told which
// files the page used and caches them too.
export function registerOffline() {
  if (!("serviceWorker" in navigator) || !window.isSecureContext) return;
  const start = () => {
    navigator.serviceWorker.register("/sw.js").catch((e) => console.warn("Offline support unavailable:", e.message));
    navigator.serviceWorker.ready.then((reg) => {
      const urls = performance.getEntriesByType("resource").map((e) => e.name).filter((u) => u.startsWith(location.origin));
      reg.active?.postMessage({ type: "cache", urls });
    }).catch(() => {});
  };
  if (document.readyState === "complete") start();
  else addEventListener("load", start, { once: true });
}
