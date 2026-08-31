(() => {
  const core = window.TsukiAdapter;
  const linkSelector = 'a[href*="/title/"]';
  const extract = async () => {
    const recognizedPage = /^\/titles?\/follows\/?$/i.test(location.pathname);
    const links = await core.waitForLinks(linkSelector, {recognizedPage});
    if (!recognizedPage && !links.length) {
      return core.unsupportedPage("mangadex", "Follows → Titles");
    }
    const byId = new Map();
    for (const link of links) {
      const match = link.getAttribute("href")?.match(/\/title\/([0-9a-f-]{36})/i);
      if (!match) continue;
      const card = link.closest("article, li, .manga-card, .dense-manga-container") || link.parentElement;
      const entry = core.makeEntry({
        source: "mangadex",
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
      ? core.result("mangadex", entries, linkSelector)
      : core.noEntries("mangadex", "Follows → Titles", linkSelector);
  };
  chrome.runtime.onMessage.addListener((message, _sender, respond) => {
    if (message?.type === "TSUKI_COLLECT") {
      extract().then(respond).catch(() => respond(core.noEntries("mangadex", "Follows → Titles", linkSelector)));
      return true;
    }
  });
})();
