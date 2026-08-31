(() => {
  if (window.TsukiManualPicker?.start) {
    window.TsukiManualPicker.start();
    return;
  }

  const core = window.TsukiAdapter;
  const host = location.hostname.toLowerCase().replace(/^www\./, "");
  const source = `web:${host}`.slice(0, 80);
  const excludedPath = /\/(?:chapter|chapters|read|reader|login|signup|search|genres?|categories?|authors?|latest|popular)(?:\/|$)/i;
  const excludedContainer = "aside, nav, footer, [class*='recommend'], [class*='popular'], [class*='related'], [class*='suggest'], [class*='carousel']";
  let highlighted = null;
  let selected = null;
  let previousOutline = "";

  const stableId = (value) => {
    let hash = 2166136261;
    for (const character of value) {
      hash ^= character.charCodeAt(0);
      hash = Math.imul(hash, 16777619);
    }
    return `${host}:${(hash >>> 0).toString(16)}`;
  };

  const candidateLinks = (root) => [...new Set([
    ...(root.matches?.("a[href]") ? [root] : []),
    ...root.querySelectorAll("a[href]")
  ])].filter((link) => {
    if (link.closest(excludedContainer)) return false;
    const sourceUrl = core.absolute(link.href);
    if (!sourceUrl) return false;
    const url = new URL(sourceUrl);
    if (url.hostname !== location.hostname || url.pathname === "/" || excludedPath.test(url.pathname)) return false;
    const card = link.closest("article, li, [class*='card'], [class*='item'], [class*='entry']") || link.parentElement;
    const title = core.titleFrom(link, card);
    return title.length >= 2 && title.length <= 300 &&
      !/^(?:read|open|view|details?|remove|delete|unfollow|chapter|ch\.?|home|next|previous)(?:\s|$)/i.test(title);
  });

  const candidateCount = (root) => new Set(
    candidateLinks(root).map((link) => new URL(link.href).pathname.replace(/\/$/, ""))
  ).size;

  const rootFor = (target) => {
    let element = target.closest("article, li, section, ul, ol, [role='list'], [class*='grid'], [class*='list'], [class*='library'], [class*='bookmark'], main, [role='main']") || target.parentElement;
    let firstWithLinks = null;
    while (element && element !== document.body && element !== document.documentElement) {
      const count = candidateCount(element);
      if (count > 0 && !firstWithLinks) firstWithLinks = element;
      if (count >= 2) return element;
      element = element.parentElement;
    }
    return firstWithLinks;
  };

  const setHighlight = (element) => {
    if (highlighted === element) return;
    if (highlighted) highlighted.style.outline = previousOutline;
    highlighted = element;
    if (highlighted) {
      previousOutline = highlighted.style.outline;
      highlighted.style.outline = "3px solid #8d6cff";
    }
  };

  const panel = document.createElement("div");
  panel.id = "tsuki-manual-picker";
  Object.assign(panel.style, {
    position: "fixed", top: "12px", left: "50%", transform: "translateX(-50%)",
    zIndex: "2147483647", width: "min(520px, calc(100vw - 24px))", padding: "12px",
    borderRadius: "10px", background: "#111018", color: "#f5f2ff",
    boxShadow: "0 8px 30px #000a", font: "13px system-ui, sans-serif"
  });
  const message = document.createElement("div");
  message.textContent = "Hover over your personal bookmark list, then click it. Tsuki will collect only inside the highlighted area.";
  const controls = document.createElement("div");
  Object.assign(controls.style, {display: "flex", gap: "8px", marginTop: "9px"});
  const confirm = document.createElement("button");
  confirm.textContent = "Collect selected area";
  confirm.disabled = true;
  const cancel = document.createElement("button");
  cancel.textContent = "Cancel";
  for (const button of [confirm, cancel]) {
    Object.assign(button.style, {padding: "7px 10px", border: "0", borderRadius: "7px", cursor: "pointer"});
  }
  Object.assign(confirm.style, {background: "#8d6cff", color: "white"});
  Object.assign(cancel.style, {background: "#302d39", color: "white"});
  controls.append(confirm, cancel);
  panel.append(message, controls);

  const cleanup = () => {
    setHighlight(null);
    document.removeEventListener("mousemove", onMove, true);
    document.removeEventListener("click", onPageClick, true);
    panel.remove();
  };

  const onMove = (event) => {
    if (panel.contains(event.target) || selected) return;
    setHighlight(rootFor(event.target));
  };

  const onPageClick = (event) => {
    if (panel.contains(event.target) || !highlighted || selected) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    selected = highlighted;
    const count = candidateCount(selected);
    message.textContent = `Selected area contains ${count} possible manga link${count === 1 ? "" : "s"}. Confirm to collect only this area.`;
    confirm.disabled = count === 0;
  };

  confirm.addEventListener("click", async () => {
    const entries = new Map();
    for (const link of candidateLinks(selected)) {
      const card = link.closest("article, li, [class*='card'], [class*='item'], [class*='entry']") || link.parentElement;
      const sourceUrl = core.absolute(link.href);
      if (!sourceUrl) continue;
      const sourceMangaId = stableId(new URL(sourceUrl).pathname.replace(/\/$/, ""));
      const entry = core.makeEntry({
        source, sourceMangaId, sourceUrl, title: core.titleFrom(link, card),
        card, link
      });
      if (entry) entries.set(sourceMangaId, entry);
    }
    const values = [...entries.values()];
    if (!values.length) {
      message.textContent = "No manga links were found. Cancel and select the list surrounding the manga cards.";
      return;
    }
    confirm.disabled = true;
    const collection = core.result(source, values, "manually selected area");
    try {
      const response = await chrome.runtime.sendMessage({type: "TSUKI_COLLECTION", payload: collection});
      message.textContent = response?.ok
        ? `Collected ${values.length} bookmarks from ${host}.`
        : "Collection failed. Reload the extension and try again.";
    } catch (_) {
      message.textContent = "Collection failed. Reload the extension and this website, then try again.";
    }
    confirm.remove();
    cancel.textContent = "Close";
    setHighlight(null);
  });
  cancel.addEventListener("click", cleanup);

  const start = () => {
    document.getElementById("tsuki-manual-picker")?.remove();
    selected = null;
    document.body.append(panel);
    document.addEventListener("mousemove", onMove, true);
    document.addEventListener("click", onPageClick, true);
  };
  window.TsukiManualPicker = {start};
  start();
})();
