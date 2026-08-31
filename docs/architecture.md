# Tsuki data, migration, and reader architecture

## Canonical manga identity

`Manga` remains the compatibility model used by the existing UI, Firestore,
and local cache. It now exposes a deterministic `tsukiId`, metadata-provider
IDs, chapter-source mappings, aliases, and authors. Existing `anilist:<id>`
keys are deliberately not rewritten; they map deterministically to
`tsuki:anilist:<id>`, so old bookmarks and progress remain readable without a
destructive migration. New fallback-only records use a `tsuki:<provider>:<id>`
key.

`MangaIdentityResolver` is the shared conservative matcher. Known provider or
source IDs are definitive. Exact normalized titles plus compatible year,
format, or author evidence are high-confidence. Fuzzy token overlap is review
evidence only. Conflicting format, release year, remake, colored-edition,
novel, sequel, spin-off, one-shot, or adaptation markers prevent automatic
merges. `CanonicalAliasIndex` persists learned provider IDs, source IDs, and
normalized aliases in SharedPreferences.

The live library is also a canonical identity boundary. Search results from a
different metadata provider are merged into an existing native or migrated
bookmark while retaining the bookmark's ID. Bookmark state, reading progress,
chapter caches, and imported source mappings therefore remain attached to the
same app manga.

## Metadata and search

Metadata and chapter sources are separate interfaces. AniList remains the
preferred metadata provider, with Kitsu, WEBTOON, Asura, Mangakakalot, and
Demonic Scans as independent metadata sources. Other reader sources are not
exposed as metadata providers. Chapter-source metadata carries the same stable
mapping used by its chapter adapter,
avoiding a second title match when a result is opened.
MAL IDs returned by AniList and other providers are retained and participate
in identity matching, but direct MAL search is not enabled because Tsuki has no
required MAL client key.

Search checks the local catalog/index immediately, debounces remote work by
550 ms, and ignores stale generations. Recent identical source queries are
coalesced and cached for five minutes. Query changes cancel active Dio
requests. `CatalogRepository` starts all metadata providers together, applies
provider timeouts independently, and emits a new merged result whenever one
finishes. Search never waits for a failed provider and never clears
already-visible results. Cached source-only records from disabled metadata
providers are filtered at the search boundary. Full details remain lazy.
Source-only autocomplete results receive a mandatory full-detail safety pass
before navigation, chapter loading, or migration commit. If one source detail
page is unavailable, trusted canonical metadata is tried before the open is
abandoned. Adult signals are merged with logical OR, and all
cache/UI boundaries reapply the existing friendly-content filter.

To add a metadata provider, implement `MetadataProvider`, return lightweight
search models with provider IDs and aliases, then register it in
`metadataProviders` in `providers.dart`. Put the preferred provider first.

## Chapter providers

`MangaSource` owns source search, chapter ordering, and page extraction.
`CatalogRepository` resolves and persists canonical-to-source mappings, merges
equivalent chapters, caches indexes, and isolates failures. MangaDex, Demonic
Scans, Mangakakalot, Asura, Weeb Central, and MangaKatana are registered. Manganato has been removed;
cached copies from that source are filtered, so legacy cached data falls back
to a currently enabled provider.

All enabled sources expose cold-start details. Provider failures and latency
are published through `sourceHealthProvider`; two consecutive failures mark a
source degraded for internal diagnostics without adding provider-health noise
to the normal Search UI. Numbered chapters
share a numeric canonical identity, while harmless special-chapter decorations
are removed conservatively before cross-source merging.

Mangakakalot is a separate parser for `mangakakalot.gg`, with conservative
alias matching, strict slugs/image hosts, decimal and special chapter support,
15-minute chapter caching, and retryable failure isolation. To add a chapter
provider, implement `MangaSource`, add a resolver/loader branch to
`CatalogRepository`, add its ID to the enabled set, and add fixture tests.

## Browser migration and import

`browser_extension/` is one Manifest V3 extension with isolated MangaDex,
Comick, Mangakakalot, and MangaKatana adapters. The service worker persists collections in
`chrome.storage.local`; it does not depend on remaining alive. Permissions are
limited to the supported hosts plus storage, active-tab, and download access.
Adapters export only source IDs/URLs, titles, and visible last-read chapter
labels—never cookies, tokens, credentials, or history. Add a site by creating
one adapter and adding only its explicit host match.

The versioned import envelope is `format: tsuki-migration`, `schemaVersion: 1`.
The validator caps files at 5 MiB and 2,500 entries, bounds strings and aliases,
requires HTTPS URLs, preserves raw special chapters, and normalizes safe numeric
forms such as `Ch. 72.5`. Bad entries are reported independently.

The import pipeline checks learned source mappings and the local metadata index
first. It then resolves exact exported URLs/IDs directly for supported reader
sources. Only unresolved titles use remote metadata search across AniList,
Kitsu, WEBTOON, Asura, Mangakakalot, and Demonic Scans. Exported site labels,
status tags, reader suffixes, and chapter text are removed into additional safe
query variants. It aggregates every exported title and alias before choosing a
match, with four workers and
provider-specific timeouts beneath them. Results are `matched`, `needsReview`,
`unmatched`, `conflict`, or `error`; unmatched/source-only records never enter
Library. Review candidates can be selected or skipped. Cross-site matches
collapse to one canonical bookmark and the furthest compatible numeric chapter
wins. Existing higher progress is retained. Imports use the normal
`UserLibraryController`; Firestore writes are chunked below the 500-operation
limit. Equivalent bookmarks left by older imports are repaired on library load,
with their furthest progress moved to the surviving manga ID. Sessions retain
counts, sources, and imported canonical IDs for future
diagnostics/rollback work. No new Firestore index is required; rules only add
the optional raw/normalized progress fields.

## Continuous reader

The reader renders nearby chapters as one vertical list. It preloads the next
chapter near the bottom and inserts the previous chapter near the top while
compensating the scroll offset. A maximum of three full chapter page sets is
kept in memory; distant sets are removed. The active chapter follows the
viewport and drives the header and saved resume position. Prefetching does not
mark a chapter read: a chapter is opened only after the viewport enters it.
Progress writes remain debounced, page images remain lazy `ResizeImage`s, and
the first successfully selected source is preferred for adjacent chapters.
Failures stay at a small retryable boundary, the last chapter ends with a
minimal caught-up label, and the chapter picker recenters the window directly.

## Compatibility and operational notes

Bookmarks, progress, cached AniList IDs, and Firebase document paths remain
valid. New JSON fields are optional on decode. Imported progress retains both
raw and normalized values so special labels are not corrupted and a numeric
chapter can resolve to the live ordered chapter list on resume. Firebase rules
must be deployed when cloud sync is enabled; no index change is necessary.

The browser adapters operate on library entries visible in the current page.
Sites that virtualize or paginate libraries require visiting/scrolling those
pages before collecting. Scraped chapter sites can redesign without notice;
their failures are intentionally isolated from metadata, Library, and other
chapter sources.
