import { parseSetupCode } from "./trv1.js";

const $ = (id) => document.getElementById(id);

async function render() {
  const { setup, queue = [] } = await chrome.storage.local.get(["setup", "queue"]);
  $("connected").hidden = !setup;
  if (setup) {
    $("vault").textContent = setup.vaultId;
    $("relay").textContent = new URL(setup.relayURL).host;
    $("queue").textContent = queue.length ? `${queue.length} save(s) waiting to upload.` : "";
  }
}

$("connect").onclick = async () => {
  try {
    const setup = parseSetupCode($("code").value);
    const origin = new URL(setup.relayURL).origin + "/*";
    const granted = await chrome.permissions.request({ origins: [origin] });
    if (!granted) throw new Error("Trove needs permission to reach your relay to upload saves.");
    const health = await fetch(`${setup.relayURL}/health`).then((r) => r.json()).catch(() => null);
    if (!health?.ok) throw new Error("Couldn't reach your relay. Check it's deployed and the URL is right.");
    await chrome.storage.local.set({ setup });
    $("code").value = "";
    $("status").textContent = "Connected ✓";
    $("status").className = "status ok";
  } catch (e) {
    $("status").textContent = e.message;
    $("status").className = "status err";
  }
  render();
};

$("retry").onclick = async () => {
  const r = await chrome.runtime.sendMessage({ type: "flush" });
  $("status").textContent = `Uploaded ${r.sent}, ${r.left} left.`;
  render();
};

$("disconnect").onclick = async () => {
  await chrome.storage.local.remove(["setup", "queue"]);
  $("status").textContent = "Disconnected.";
  render();
};

render();
