(() => {
  const core = window.TsukiAdapter;
  const host = location.hostname.toLowerCase().replace(/^www\./, "");
  const source = `web:${host}`.slice(0, 80);
  const personalTerms = /\b(bookmarks?|favorites?|favourites?|library|follows?|my\s*list|reading\s*list|saved)\b/i;
  const excludedPath = /\/(?:chapter|chapters|read|reader|login|signup|search|genres?|categories?|authors?|latest|popular)(?:\/|$)/i;
  const excludedContainer = "aside, nav, footer, header, [class*='recommend'], [class*='popular'], [class*='related'], [class*='suggest'], [class*='carousel']";

  const profiles = [
    {
      id: "madara-wordpress",
      roots: [".c-tabs-item__content", ".tab-summary", ".page-listing-item", ".manga-bookmark"],
      cards: [".page-item-detail.manga", ".row.c-tabs-item__content", ".item-summary", ".page-listing-item"],
      links: [".post-title a[href]", ".item-summary a[href]", ".item-thumb a[href]"]
    },
    {
      id: "bookmark-cards",
      roots: [".bookmark-list", ".bookmarks", ".favorite-list", ".favorites", ".library-list", ".reading-list", "[data-testid*='library']"],
      cards: [".bookmark-item", ".favorite-item", ".library-item", ".manga-card", ".comic-card", ".series-card", "article"],
      links: [".manga-title a[href]", ".comic-title a[href]", ".series-title a[href]", ".title a[href]", "h2 a[href]", "h3 a[href]", "a[href]"]
    },
    {
      id: "list-grid",
      roots: ["[role='list']", ".manga-list", ".comic-list", ".series-list", ".manga-grid", ".comic-grid", ".series-grid"],
      cards: ["[role='listitem']", ".manga-item", ".comic-item", ".series-item", "article", "li"],
      links: ["h2 a[href]", "h3 a[href]", "h4 a[href]", "[class*='title'] a[href]", "a[href]"]
    },
    {
      id: "semantic",
      roots: ["main", "[role='main']"],
      cards: ["article", "[role='listitem']", "li", ".card", ".item"],
      links: ["h2 a[href]", "h3 a[href]", "h4 a[href]", "a[href]"]
    }
  ];

  const pageEvidence = () => {
    const route = decodeURIComponent(`${location.pathname} ${location.search}`).replace(/[-_/]+/g, " ");
    const heading = core.text(document.querySelector("main h1, main h2, [role='main'] h1, [role='main'] h2, h1"));
    const activeControl = [...document.querySelectorAll(
      "[aria-selected='true'], [aria-current='page'], .tab.active, .tabs .active, button.active, a.active"
    )].some((element) => personalTerms.test(core.text(element)));
    const personalControls = document.querySelectorAll(
      "[aria-label*='remove bookmark' i], [aria-label*='unfollow' i], " +
      "[title*='remove bookmark' i], [data-bookmarked='true'], [data-following='true']"
    ).length;
    return {
      recognized: personalTerms.test(route) || personalTerms.test(`${document.title} ${heading}`) || activeControl || personalControls > 0,
      activeControl,
      personalControls
    };
  };

  const stableId = (value) => {
    let hash = 2166136261;
    for (const character of value) {
      hash ^= character.charCodeAt(0);
      hash = Math.imul(hash, 16777619);
    }
    return `${host}:${(hash >>> 0).toString(16)}`;
  };

  const validLink = (link) => {
    if (!link || link.closest(excludedContainer)) return false;
    const sourceUrl = core.absolute(link.href);
    if (!sourceUrl) return false;
    const url = new URL(sourceUrl);
    if (url.hostname !== location.hostname || url.pathname === "/" || excludedPath.test(url.pathname)) return false;
    return url.pathname !== location.pathname;
  };

  const firstLink = (card, selectors) => {
    for (const selector of selectors) {
      const link = card.matches?.(selector) ? card : card.querySelector(selector);
      if (validLink(link) && core.titleFrom(link, card)) return link;
    }
    return null;
  };

  const rootsFor = (profile) => {
    const values = [];
    for (const selector of profile.roots) {
      for (const root of document.querySelectorAll(selector)) {
        if (!root.closest(excludedContainer)) values.push(root);
      }
    }
    return [...new Set(values)];
  };

  const entriesFor = (profile) => {
    const entries = new Map();
    const roots = rootsFor(profile);
    for (const root of roots) {
      let cards = [];
      for (const selector of profile.cards) cards.push(...root.querySelectorAll(selector));
      cards = [...new Set(cards)];
      if (!cards.length) cards = [root];
      for (const card of cards) {
        if (card.closest(excludedContainer)) continue;
        const link = firstLink(card, profile.links);
        if (!link) continue;
        const sourceUrl = core.absolute(link.href);
        const path = new URL(sourceUrl).pathname.replace(/\/$/, "");
        const sourceMangaId = stableId(path);
        const entry = core.makeEntry({
          source,
          sourceMangaId,
          sourceUrl,
          title: core.titleFrom(link, card),
          card,
          link
        });
        if (entry) entries.set(sourceMangaId, entry);
      }
    }
    return [...entries.values()];
  };

  const bestProfile = () => {
    const matches = profiles.map((profile) => ({profile, entries: entriesFor(profile)}));
    return matches.find((match) => match.entries.length > 0) || matches[matches.length - 1];
  };

  const extract = async () => {
    const evidence = pageEvidence();
    if (!evidence.recognized) return core.unsupportedPage(source, "bookmark/library");
    let match = {profile: profiles[0], entries: []};
    let previousCount = -1;
    let stable = 0;
    const started = Date.now();
    while (Date.now() - started < 7000 && stable < 3) {
      match = bestProfile();
      stable = match.entries.length > 0 && match.entries.length === previousCount ? stable + 1 : 0;
      previousCount = match.entries.length;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    if (!match.entries.length) return core.noEntries(source, "bookmark/library", "a[href]");
    const collection = core.result(source, match.entries, "a[href]");
    collection.adapterProfile = match.profile.id;
    collection.diagnostics = {
      ...collection.diagnostics,
      adapterProfile: match.profile.id,
      activePersonalTab: evidence.activeControl,
      personalControls: evidence.personalControls,
      normalizedEntries: match.entries.length,
      collectionMode: "bookmarks-only"
    };
    return collection;
  };

  chrome.runtime.onMessage.addListener((message, _sender, respond) => {
    if (message?.type === "TSUKI_COLLECT") {
      extract().then(respond).catch(() =>
        respond(core.noEntries(source, "bookmark/library", "a[href]"))
      );
      return true;
    }
  });
})();
