(() => {
  const text = (element) => element?.textContent?.replace(/\s+/g, " ").trim() || "";
  const absolute = (value) => {
    if (!value) return null;
    try {
      const url = new URL(value, location.href);
      return url.protocol === "https:" ? url.href : null;
    } catch (_) {
      return null;
    }
  };

  const isExcluded = (element) => Boolean(element?.closest(
    "aside, nav, footer, [class*='recommend'], [class*='popular'], " +
    "[class*='suggest'], [class*='related'], [class*='carousel'], " +
    "[data-testid*='recommend'], [data-testid*='popular']"
  ));

  const rootSelectors = [
      "[data-testid*='follow']",
      "[data-testid*='bookmark']",
      "[data-testid*='library']",
      "[class*='follow-list']",
      "[class*='bookmark-list']",
      "[class*='library-list']"
  ];

  const linksWithin = (roots, selector) => [...new Set(
    roots.flatMap((root) => [...root.querySelectorAll(selector)])
  )].filter((link) => !isExcluded(link));

  const personalLinks = (selector) => {
    // Use every root at the first specificity tier that works. Previously the
    // first matching card ended collection, which could return only one title.
    for (const rootSelector of rootSelectors) {
      const roots = [...document.querySelectorAll(rootSelector)].filter((root) => !isExcluded(root));
      const links = linksWithin(roots, selector);
      if (links.length) return links;
    }
    const main = document.querySelector("main, [role='main']");
    return main && !isExcluded(main) ? linksWithin([main], selector) : [];
  };

  const explicitPersonalLinks = (linkSelector) => {
    const markers = [...document.querySelectorAll(
      "[aria-label*='unfollow' i], [aria-label*='remove bookmark' i], " +
      "[aria-label*='remove from library' i], [title*='unfollow' i], " +
      "[title*='remove bookmark' i], [data-bookmarked='true'], " +
      "[data-following='true'], [data-in-library='true']"
    )];
    const links = [];
    for (const marker of markers) {
      const card = marker.closest("article, li, [class*='card'], [class*='item']") || marker.parentElement;
      const link = card?.querySelector(linkSelector);
      if (link && !isExcluded(link)) links.push(link);
    }
    return [...new Set(links)];
  };

  const waitForLinks = async (selector, {recognizedPage, timeoutMs = 7000} = {}) => {
    const started = Date.now();
    let latest = [];
    let stablePolls = 0;
    let previousCount = -1;
    while (Date.now() - started < timeoutMs) {
      latest = recognizedPage ? personalLinks(selector) : explicitPersonalLinks(selector);
      stablePolls = latest.length > 0 && latest.length === previousCount ? stablePolls + 1 : 0;
      if (stablePolls >= 3) return latest;
      previousCount = latest.length;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    return latest;
  };

  const cleanTitle = (rawValue) => {
    let value = String(rawValue || "")
      .replace(/[\u200B-\u200D\uFEFF]/g, "")
      .replace(/\s+/g, " ")
      .replace(/^\s*(?:title|manga|comic)\s*:\s*/i, "")
      .replace(/^\s*(?:view|open)\s+(?:manga|comic)\s*:\s*/i, "")
      .replace(/\s+(?:manga|comic)\s+details?\s*$/i, "")
      .trim();
    if (/^(?:latest|new(?:est)?|last)\s+(?:chapter|ch\.?|episode|ep\.?)\s*[:#-]?\s*\d/i.test(value)) return "";
    const chapterSuffix = value.match(/^(.{2,}?)\s+(?:[-|•]\s*)?(?:chapter|ch\.?|episode|ep\.?)\s*[:#-]?\s*\d+(?:\.\d+)?(?:\s.*)?$/i);
    if (chapterSuffix) value = chapterSuffix[1].trim();
    if (!value || value.length > 300) return "";
    if (/^(?:bookmark(?:ed)?|favorite|favourite|follow(?:ing)?|library|read|open|view|details?|remove|delete|continue reading)$/i.test(value)) return "";
    if (/^(?:(?:latest|new(?:est)?|last)\s+)?(?:chapter|ch\.?|episode|ep\.?)\s*[:#-]?\s*\d/i.test(value)) return "";
    return value;
  };

  const titleFrom = (link, card) => {
    const values = [
      card?.getAttribute("data-title"),
      card?.querySelector("h1, h2, h3, h4, [data-title], .title, .manga-title, .comic-title, .series-title, .name")?.textContent,
      link?.querySelector("img")?.getAttribute("alt"),
      card?.querySelector("img")?.getAttribute("alt"),
      link?.getAttribute("data-title"),
      link?.getAttribute("title"),
      link?.textContent,
      link?.getAttribute("aria-label")
    ];
    return values.map(cleanTitle).find(Boolean) || "";
  };

  const authorFrom = (card) => {
    const raw = text(card?.querySelector(
      "[data-author], [class*='author'], [class*='artist'], [itemprop='author']"
    )).replace(/^\s*(?:author|artist)\s*:?\s*/i, "").trim();
    return raw && raw.length <= 200 ? raw : null;
  };

  const coverFrom = (card, link) => {
    const image = link?.querySelector("img") || card?.querySelector("img");
    return absolute(image?.getAttribute("src") || image?.getAttribute("data-src") || image?.getAttribute("data-lazy-src"));
  };

  const makeEntry = ({source, sourceMangaId, sourceUrl, title, aliases = [], card, link}) => {
    const normalizedSource = String(source || "").trim().toLowerCase().slice(0, 80);
    const normalizedId = String(sourceMangaId || "").trim().slice(0, 200);
    const normalizedUrl = absolute(sourceUrl);
    const normalizedTitle = cleanTitle(title) || titleFrom(link, card);
    if (!normalizedSource || !normalizedId || !normalizedUrl || !normalizedTitle) return null;
    const normalizedAliases = [...new Set(aliases.map(cleanTitle).filter((value) =>
      value && value.toLowerCase() !== normalizedTitle.toLowerCase()
    ))].slice(0, 20);
    const author = authorFrom(card);
    const coverUrl = coverFrom(card, link);
    return {
      source: normalizedSource,
      sourceMangaId: normalizedId,
      sourceUrl: normalizedUrl,
      title: normalizedTitle,
      aliases: normalizedAliases,
      author,
      coverUrl,
      bookmarked: true
    };
  };

  const unsupportedPage = (source, expectedPage) => ({
    ok: false,
    source,
    code: "WRONG_PAGE",
    message: `Open your personal ${expectedPage} page before collecting.`,
    entries: [],
    diagnostics: diagnostics(source)
  });

  const diagnostics = (source, linkSelector) => ({
    source,
    url: location.href,
    path: location.pathname,
    readyState: document.readyState,
    title: document.title,
    totalSourceLinks: linkSelector ? document.querySelectorAll(linkSelector).length : 0,
    explicitPersonalMarkers: document.querySelectorAll(
      "[aria-label*='unfollow' i], [aria-label*='remove bookmark' i], " +
      "[title*='unfollow' i], [data-bookmarked='true'], [data-following='true']"
    ).length
  });

  const result = (source, entries, linkSelector) => ({
    ok: true,
    source,
    adapterVersion: 15,
    pageUrl: location.href,
    entries,
    diagnostics: {
      ...diagnostics(source, linkSelector),
      normalizedEntries: entries.length
    }
  });

  const noEntries = (source, expectedPage, linkSelector) => ({
    ok: false,
    source,
    code: "NO_PERSONAL_ENTRIES",
    message: `No personal bookmarks were found on this ${expectedPage} page after waiting for it to load.`,
    entries: [],
    diagnostics: diagnostics(source, linkSelector)
  });

  window.TsukiAdapter = {
    text,
    absolute,
    personalLinks,
    explicitPersonalLinks,
    waitForLinks,
    cleanTitle,
    titleFrom,
    authorFrom,
    coverFrom,
    makeEntry,
    unsupportedPage,
    result,
    noEntries,
    diagnostics
  };
})();
