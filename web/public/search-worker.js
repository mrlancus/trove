// The search Worker: indexing and searching happen here, so typing never waits on scoring.
// Messages (searchclient.js): init, apply, scope, query, save, semantic. Replies: ready, result, semantic, error.
import { idbStorage, SearchService } from "./core/searchservice.js";

let storage = null;
try { if (typeof indexedDB !== "undefined") storage = idbStorage(); } catch { storage = null; }
const service = new SearchService({ storage });
let chain = Promise.resolve();
let newestQuery = 0;

self.onmessage = (e) => {
  const msg = e.data;
  if (msg.type === "query") newestQuery = Math.max(newestQuery, msg.seq);
  chain = chain.then(() => handle(msg)).catch((err) => self.postMessage({ type: "error", message: String(err?.message ?? err) }));
};

async function handle(msg) {
  switch (msg.type) {
    case "init": self.postMessage({ type: "ready", ...(await service.init(msg.vaultId)) }); break;
    case "apply": service.apply(msg); break;
    case "scope": service.setScope(msg.key, msg.ids); break;
    case "query":
      // Typing faster than searching: only the newest question is worth answering.
      if (msg.seq < newestQuery) return;
      self.postMessage({ type: "result", seq: msg.seq, ...(await service.query(msg)) });
      break;
    case "save": await service.save(); break;
    case "semantic": await semantic(msg.enabled); break;
  }
}

// ---------- search by meaning (opt-in) ----------
// A small sentence-embedding model (all-MiniLM-L6-v2, quantised, about 25 MB) run here with
// transformers.js, fetched once from the pinned CDN build and cached by the browser. Nothing leaves
// the device. The page's Content-Security-Policy has to allow the CDN and the model host for this to
// load (it doesn't by default); until then turning it on reports that it isn't available.
const TRANSFORMERS_URL = "https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.0.2/dist/transformers.min.js";
const MODEL = "Xenova/all-MiniLM-L6-v2";
let embedding = null;

async function semantic(enabled) {
  if (!enabled) { service.embedder = null; return; }
  try {
    if (!embedding) {
      const { pipeline } = await import(TRANSFORMERS_URL);
      const extract = await pipeline("feature-extraction", MODEL, { dtype: "q8" });
      embedding = { embed: async (texts) => (await extract(texts, { pooling: "mean", normalize: true })).tolist().map((v) => Float32Array.from(v)) };
    }
    service.embedder = embedding;
    self.postMessage({ type: "semantic", ready: true });
    // Catch up in the background, a batch at a time between other messages.
    const step = () => { chain = chain.then(() => service.embedPending(32)).then((n) => { if (n && service.embedder) setTimeout(step, 50); }); };
    step();
  } catch (e) {
    service.embedder = null;
    self.postMessage({ type: "semantic", ready: false, error: String(e?.message ?? e) });
  }
}
