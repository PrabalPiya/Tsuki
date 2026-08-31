const STORAGE_KEY = "tsukiMigrationStateV1";

async function loadState() {
  const stored = await chrome.storage.local.get(STORAGE_KEY);
  const state = stored[STORAGE_KEY];
  if (!state || state.collectorVersion !== 15) {
    const clean = {schemaVersion: 1, collectorVersion: 15, sites: {}, entries: {}};
    await chrome.storage.local.set({[STORAGE_KEY]: clean});
    return clean;
  }
  return state;
}

async function mergeCollection(collection) {
  const state = await loadState();
  const site = collection.source;
  if (state.sites[site]?.adapterVersion !== collection.adapterVersion) {
    for (const [key, entry] of Object.entries(state.entries)) {
      if (entry.source === site) delete state.entries[key];
    }
  }
  for (const rawEntry of collection.entries || []) {
    const entry = normalizeEntry(site, rawEntry);
    if (!entry) continue;
    const key = `${site}:${entry.sourceMangaId}`;
    state.entries[key] = entry;
  }
  state.sites[site] = {
    count: Object.values(state.entries).filter((entry) => entry.source === site).length,
    collectedAt: new Date().toISOString(),
    adapterVersion: collection.adapterVersion,
    error: collection.error || null
  };
  await chrome.storage.local.set({[STORAGE_KEY]: state});
  return state;
}

function normalizeEntry(site, raw) {
  const clean = (value, maximum) => String(value || "").replace(/\s+/g, " ").trim().slice(0, maximum);
  const source = clean(site, 80).toLowerCase();
  const sourceMangaId = clean(raw?.sourceMangaId, 200);
  const title = clean(raw?.title, 300);
  if (!source || !sourceMangaId || !title) return null;
  let sourceUrl;
  try {
    const parsed = new URL(raw?.sourceUrl);
    if (parsed.protocol !== "https:" || parsed.username || parsed.password) return null;
    sourceUrl = parsed.href;
  } catch (_) {
    return null;
  }
  const aliases = [...new Set((Array.isArray(raw?.aliases) ? raw.aliases : [])
    .map((value) => clean(value, 300))
    .filter((value) => value && value.toLowerCase() !== title.toLowerCase()))].slice(0, 20);
  const author = clean(raw?.author, 200);
  let coverUrl;
  try {
    const parsed = new URL(raw?.coverUrl);
    if (parsed.protocol === "https:") coverUrl = parsed.href;
  } catch (_) {
    coverUrl = null;
  }
  return {
    source,
    sourceMangaId,
    sourceUrl,
    title,
    aliases,
    author: author || null,
    coverUrl: coverUrl || null,
    bookmarked: true
  };
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "TSUKI_COLLECTION") {
    mergeCollection(message.payload)
      .then((state) => sendResponse({ok: true, state}))
      .catch(() => sendResponse({ok: false}));
    return true;
  }
  if (message?.type === "TSUKI_GET_STATE") {
    loadState().then((state) => sendResponse({ok: true, state}));
    return true;
  }
  if (message?.type === "TSUKI_CLEAR") {
    chrome.storage.local.remove(STORAGE_KEY).then(() => sendResponse({ok: true}));
    return true;
  }
});
