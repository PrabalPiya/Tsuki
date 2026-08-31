const statusElement = document.querySelector("#status");
const sitesElement = document.querySelector("#sites");
const totalElement = document.querySelector("#total");
const diagnosticsBox = document.querySelector("#diagnostics-box");
const diagnosticsElement = document.querySelector("#diagnostics");
const emptySitesElement = document.querySelector("#empty-sites");
const collectButton = document.querySelector("#collect");
const selectButton = document.querySelector("#select");
const exportButton = document.querySelector("#export");
const clearButton = document.querySelector("#clear");

function setStatus(message, tone = "neutral") {
  statusElement.textContent = message;
  statusElement.dataset.tone = tone;
}

function setBusy(button, busy) {
  button.setAttribute("aria-busy", String(busy));
  button.disabled = busy;
}

function showDiagnostics(collection) {
  const details = collection?.diagnostics;
  diagnosticsBox.hidden = !details;
  diagnosticsBox.open = Boolean(details && !collection?.ok);
  diagnosticsElement.textContent = details ? JSON.stringify(details, null, 2) : "";
}

function adapterFilesFor(rawUrl) {
  const url = new URL(rawUrl);
  const host = url.hostname.toLowerCase().replace(/^www\./, "");
  if (host === "mangadex.org") return ["adapters/core.js", "adapters/mangadex.js"];
  if (["comick.io", "comick.dev", "comick.art", "comick.live"].includes(host)) {
    return ["adapters/core.js", "adapters/comick.js"];
  }
  if (host === "mangakakalot.gg" || host === "mangakakalot.com") {
    return ["adapters/core.js", "adapters/mangakakalot.js"];
  }
  if (host === "demonicscans.org") {
    return ["adapters/core.js", "adapters/demonicscans.js"];
  }
  if (url.protocol === "https:" || url.protocol === "http:") {
    return ["adapters/core.js", "adapters/generic.js"];
  }
  return null;
}

async function collectFromTab(tab) {
  try {
    return await chrome.tabs.sendMessage(tab.id, {type: "TSUKI_COLLECT"});
  } catch (_) {
    const files = adapterFilesFor(tab.url);
    if (!files) {
      const host = new URL(tab.url).hostname || "this browser page";
      throw new Error(`${host} is not supported. Open a personal manga library page.`);
    }
    await chrome.scripting.executeScript({target: {tabId: tab.id}, files});
    return chrome.tabs.sendMessage(tab.id, {type: "TSUKI_COLLECT"});
  }
}

async function state() {
  const response = await chrome.runtime.sendMessage({type: "TSUKI_GET_STATE"});
  const value = response?.state || {sites: {}, entries: {}};
  render(value);
  return value;
}

function render(value) {
  sitesElement.replaceChildren();
  const sites = Object.entries(value.sites || {}).sort(([a], [b]) => a.localeCompare(b));
  for (const [site, details] of sites) {
    const row = document.createElement("div");
    row.className = "site";
    row.setAttribute("role", "listitem");
    const name = document.createElement("span");
    name.className = "site-name";
    name.textContent = site;
    const count = document.createElement("span");
    count.className = `site-count${details.error ? " failed" : ""}`;
    count.textContent = details.error ? "Failed" : `✓ ${details.count}`;
    row.append(name, count);
    sitesElement.append(row);
  }

  const entries = Object.values(value.entries || {});
  const titles = new Set(entries.map((entry) =>
    String(entry.title || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim()
  ).filter(Boolean));
  totalElement.textContent = titles.size;
  emptySitesElement.hidden = sites.length > 0;
  exportButton.disabled = entries.length === 0;
  clearButton.disabled = entries.length === 0 && sites.length === 0;
}

collectButton.addEventListener("click", async () => {
  setBusy(collectButton, true);
  setStatus("Looking for personal bookmarks on this page…");
  try {
    const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
    const collection = await collectFromTab(tab);
    if (!collection) throw new Error();
    showDiagnostics(collection);
    if (!collection.ok) {
      setStatus(collection.message, "error");
      return;
    }
    if (!collection.entries.length) {
      setStatus("No personal bookmarks are visible yet. Let the page finish loading, scroll through the list, then try again.", "error");
      return;
    }
    const result = await chrome.runtime.sendMessage({type: "TSUKI_COLLECTION", payload: collection});
    if (!result?.ok) throw new Error("The bookmarks could not be saved by the extension.");
    render(result.state);
    const profile = collection.adapterProfile ? ` using ${collection.adapterProfile}` : "";
    setStatus(`Collected ${collection.entries.length} bookmarks${profile}.`, "success");
  } catch (error) {
    showDiagnostics(null);
    setStatus(error?.message || "The site adapter could not run. Reload this page and try again.", "error");
  } finally {
    setBusy(collectButton, false);
  }
});

selectButton.addEventListener("click", async () => {
  setBusy(selectButton, true);
  try {
    const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
    const url = new URL(tab.url);
    if (url.protocol !== "https:" && url.protocol !== "http:") {
      throw new Error("Open the manga website first.");
    }
    await chrome.scripting.executeScript({
      target: {tabId: tab.id},
      files: ["adapters/core.js", "adapters/manual.js"]
    });
    window.close();
  } catch (error) {
    setStatus(error?.message || "Manual selection could not start on this page.", "error");
    setBusy(selectButton, false);
  }
});

exportButton.addEventListener("click", async () => {
  setBusy(exportButton, true);
  try {
    const value = await state();
    setBusy(exportButton, true);
    const payload = {
      format: "tsuki-migration",
      schemaVersion: 1,
      createdAt: new Date().toISOString(),
      sources: Object.keys(value.sites || {}).map((id) => ({id})),
      entries: Object.values(value.entries || {})
    };
    const url = URL.createObjectURL(new Blob([JSON.stringify(payload, null, 2)], {type: "application/json"}));
    await chrome.downloads.download({url, filename: `tsuki-migration-${Date.now()}.json`, saveAs: true});
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    setStatus(`Exported ${payload.entries.length} bookmarks. Import the downloaded JSON in Tsuki.`, "success");
  } catch (_) {
    setStatus("The export could not be downloaded. Try again.", "error");
  } finally {
    setBusy(exportButton, false);
  }
});

clearButton.addEventListener("click", async () => {
  setBusy(clearButton, true);
  try {
    await chrome.runtime.sendMessage({type: "TSUKI_CLEAR"});
    render({sites: {}, entries: {}});
    setStatus("Collected bookmarks were cleared.");
  } catch (_) {
    setStatus("Collected bookmarks could not be cleared.", "error");
    setBusy(clearButton, false);
  }
});

state().catch(() => setStatus("Stored bookmarks could not be loaded. Reload the extension.", "error"));
