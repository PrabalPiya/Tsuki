(() => {
  const core = window.TsukiAdapter;
  const source = "mangakatana";
  const linkSelector = "#book_list .title a[href*='/manga/'], .bookmark-list .title a[href*='/manga/']";

  const isBookmarkPage = () => location.pathname.toLowerCase().split("/")
    .filter(Boolean)
    .some((part) => ["bookmark", "bookmarks", "library"].includes(part));

  const pageDocuments = async () => {
    const documents = [document];
    const numbers = [...document.querySelectorAll(".pagination a, .uk-pagination a")]
      .map((link) => Number(new URL(link.href, location.href).searchParams.get("page")) || Number(core.text(link)))
      .filter((value) => Number.isInteger(value) && value > 0);
    const pageCount = Math.min(Math.max(1, ...numbers), 100);
    const currentPage = Number(new URL(location.href).searchParams.get("page")) || 1;
    const pending = Array.from({length: pageCount}, (_, index) => index + 1)
      .filter((page) => page !== currentPage);

    for (let offset = 0; offset < pending.length; offset += 4) {
      const results = await Promise.allSettled(pending.slice(offset, offset + 4).map(async (page) => {
        const url = new URL(location.href);
        url.searchParams.set("page", String(page));
        const response = await fetch(url, {credentials: "include"});
        if (!response.ok) throw new Error(`Bookmark page ${page} returned ${response.status}`);
        return new DOMParser().parseFromString(await response.text(), "text/html");
      }));
      for (const result of results) {
        if (result.status === "fulfilled") documents.push(result.value);
      }
    }
    return documents;
  };

  const extract = async () => {
    if (!isBookmarkPage()) return core.unsupportedPage(source, "Bookmarks");
    const entries = new Map();
    for (const page of await pageDocuments()) {
      for (const link of page.querySelectorAll(linkSelector)) {
        const card = link.closest(".item, article, li") || link.parentElement;
        const sourceUrl = core.absolute(link.href);
        const match = sourceUrl && new URL(sourceUrl).pathname.match(/^\/manga\/([^/]+\.\d+)\/?$/i);
        if (!match) continue;
        const entry = core.makeEntry({
          source,
          sourceMangaId: decodeURIComponent(match[1]).toLowerCase(),
          sourceUrl,
          title: core.titleFrom(link, card),
          card,
          link
        });
        if (entry) entries.set(entry.sourceMangaId, entry);
      }
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
