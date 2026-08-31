(() => {
  const core = window.TsukiAdapter;
  const source = "demonicscans";
  const linkSelector = "a[href^='/manga/'], a[href*='demonicscans.org/manga/']";
  const excludedContainer = "aside, nav, footer, header, [class*='popular'], [class*='recommend'], [class*='latest']";

  const isBookmarkPage = () => /^\/bookmarks(?:\.php)?\/?$/i.test(location.pathname);

  const visibleMangaLinks = () => [...new Set([...document.querySelectorAll(linkSelector)])]
    .filter((link) => !link.closest(excludedContainer))
    .filter((link) => /^\/manga\/[^/?#]+\/?$/i.test(new URL(link.href, location.href).pathname));

  const waitForMangaLinks = async () => {
    let links = [];
    let previousCount = -1;
    let stablePolls = 0;
    const started = Date.now();
    while (Date.now() - started < 7000 && stablePolls < 3) {
      links = visibleMangaLinks();
      stablePolls = links.length > 0 && links.length === previousCount ? stablePolls + 1 : 0;
      previousCount = links.length;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    return links;
  };

  const extract = async () => {
    if (!isBookmarkPage()) return core.unsupportedPage(source, "Bookmarks");
    const links = await waitForMangaLinks();
    const entries = new Map();
    for (const link of links) {
      const url = new URL(link.href, location.href);
      const path = url.pathname.replace(/\/$/, "");
      const card = link.closest("article, li, [class*='card'], [class*='item'], [class*='row']") || link.parentElement;
      const sourceMangaId = encodeURIComponent(path);
      const entry = core.makeEntry({
        source,
        sourceMangaId,
        sourceUrl: url.href,
        title: core.titleFrom(link, card),
        card,
        link
      });
      if (entry) entries.set(sourceMangaId, entry);
    }
    const values = [...entries.values()];
    return values.length
      ? core.result(source, values, linkSelector)
      : core.noEntries(source, "Bookmarks", linkSelector);
  };

  chrome.runtime.onMessage.addListener((message, _sender, respond) => {
    if (message?.type === "TSUKI_COLLECT") {
      extract().then(respond).catch(() =>
        respond(core.noEntries(source, "Bookmarks", linkSelector))
      );
      return true;
    }
  });
})();
