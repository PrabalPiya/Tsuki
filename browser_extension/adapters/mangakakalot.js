(() => {
  const core = window.TsukiAdapter;
  const source = "mangakakalot";
  const linkSelector = ".user-bookmark-item-right .bm-title, a[href*='/manga/'], a[href*='/manga-']";
  const personalSegments = new Set(["bookmark", "bookmarks", "bookmark-list", "library", "list", "my-list"]);

  const isBookmarkPage = () => location.pathname.toLowerCase().split("/")
    .map((part) => part.replace(/\.html$/, ""))
    .some((part) => personalSegments.has(part));

  const pageDocuments = async () => {
    const documents = [document];
    const numbers = [...document.querySelectorAll(".group-page a")]
      .flatMap((link) => {
        const fromUrl = Number(new URL(link.href, location.href).searchParams.get("page"));
        const fromText = Number(core.text(link).replace(/\D+/g, ""));
        return [fromUrl, fromText];
      })
      .filter((value) => Number.isInteger(value) && value > 0);
    const pageCount = Math.min(Math.max(1, ...numbers), 100);
    const currentPage = Number(new URL(location.href).searchParams.get("page")) || 1;
    const pending = [];
    for (let page = 1; page <= pageCount; page += 1) {
      if (page !== currentPage) pending.push(page);
    }
    for (let offset = 0; offset < pending.length; offset += 4) {
      const batch = pending.slice(offset, offset + 4);
      const results = await Promise.allSettled(batch.map(async (page) => {
        const url = new URL(location.href);
        url.pathname = "/bookmark";
        url.search = "";
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

  const extractCard = (card) => {
    const titleElement = card.querySelector(".bm-title");
    const titleLink = titleElement?.matches("a[href]")
      ? titleElement
      : titleElement?.querySelector("a[href]") || card.querySelector("a[href*='/manga/'], a[href*='/manga-']");
    const title = core.cleanTitle(core.text(titleElement)) || core.titleFrom(titleLink, card);
    const removeUrl = card.querySelector(".btn-remove-bookmark")?.getAttribute("data-url") || "";
    const numericId = removeUrl.match(/\d+/)?.[0];
    const sourceUrl = core.absolute(titleLink?.href);
    const pathId = sourceUrl ? new URL(sourceUrl).pathname.replace(/^\/+|\/+$/g, "") : "";
    // Tsuki's reader uses the public series slug. Numeric bookmark-action IDs
    // cannot be opened directly and caused otherwise valid imports to miss.
    const sourceMangaId = pathId || numericId;
    return core.makeEntry({
      source, sourceMangaId, sourceUrl, title, card, link: titleLink
    });
  };

  const extract = async () => {
    if (!isBookmarkPage()) return core.unsupportedPage(source, "Bookmarks");
    await core.waitForLinks(linkSelector, {recognizedPage: true});
    const documents = await pageDocuments();
    const entries = new Map();
    for (const page of documents) {
      for (const card of page.querySelectorAll(".user-bookmark-item-right")) {
        const entry = extractCard(card);
        if (entry) entries.set(entry.sourceMangaId, entry);
      }
    }
    // Fallback for a Mangakakalot layout variant without the known cards.
    if (!entries.size) {
      for (const link of core.personalLinks(linkSelector)) {
        const card = link.closest("article, li, .itemupdate, .story_item, [class*='bookmark-item']") || link.parentElement;
        const sourceUrl = core.absolute(link.href);
        const sourceMangaId = sourceUrl ? new URL(sourceUrl).pathname.replace(/^\/+|\/+$/g, "") : "";
        const entry = core.makeEntry({
          source, sourceMangaId, sourceUrl, title: core.titleFrom(link, card),
          card, link
        });
        if (entry) entries.set(sourceMangaId, entry);
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
