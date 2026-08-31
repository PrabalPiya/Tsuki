(() => {
  const core = window.TsukiAdapter;
  const linkSelector = 'a[href*="/comic/"]';
  const extract = async () => {
    const personalSegments = new Set(["bookmark", "bookmarks", "library", "follow", "follows", "list", "my-list"]);
    const recognizedPage = location.pathname.toLowerCase().split("/").some((part) => personalSegments.has(part));
    const links = await core.waitForLinks(linkSelector, {recognizedPage});
    if (!recognizedPage && !links.length) {
      return core.unsupportedPage("comick", "Bookmarks");
    }
    const byId = new Map();
    for (const link of links) {
      const match = link.getAttribute("href")?.match(/\/comic\/([^/?#]+)/i);
      if (!match) continue;
      const card = link.closest("article, li, [class*='comic']") || link.parentElement;
      const entry = core.makeEntry({
        source: "comick",
        sourceMangaId: match[1],
        sourceUrl: core.absolute(link.href),
        title: core.titleFrom(link, card),
        card,
        link
      });
      if (entry) byId.set(match[1], entry);
    }
    const entries = [...byId.values()];
    return entries.length
      ? core.result("comick", entries, linkSelector)
      : core.noEntries("comick", "Bookmarks", linkSelector);
  };
  chrome.runtime.onMessage.addListener((message, _sender, respond) => {
    if (message?.type === "TSUKI_COLLECT") {
      extract().then(respond).catch(() => respond(core.noEntries("comick", "Bookmarks", linkSelector)));
      return true;
    }
  });
})();
