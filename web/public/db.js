// Tiny IndexedDB key-value store. CryptoKeys are stored as structured clones (still non-extractable).
// One connection is kept open (opening per call cost more than the writes); it's reopened if the
// browser closes it.
const DB = "trove", STORE = "kv";
let connection = null;

function open() {
  connection ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => {
      const db = req.result;
      db.onclose = () => { connection = null; };
      db.onversionchange = () => { db.close(); connection = null; };
      resolve(db);
    };
    req.onerror = () => { connection = null; reject(req.error); };
  });
  return connection;
}

function run(mode, fn) {
  return open().then((db) => new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, mode);
    const req = fn(tx.objectStore(STORE));
    tx.oncomplete = () => resolve(req?.result);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  }));
}

export const storage = {
  get: (key) => run("readonly", (s) => s.get(key)),
  set: (key, value) => run("readwrite", (s) => s.put(value, key)),
  delete: (key) => run("readwrite", (s) => s.delete(key)),
  // The search Worker keeps its own (encrypted) index in another database: forgetting this browser removes it too.
  clear: () => { try { indexedDB.deleteDatabase("trove-search"); } catch { /* none */ } return run("readwrite", (s) => s.clear()); },
};
