# Architecture

## Shape

The Flutter path stays deliberately short:

Screen → Riverpod controller/provider → repository → source/Firebase

CatalogRepository owns canonical client reads. MetadataProvider, MangaSource,
RankingProvider, SynopsisService, UserStore, and the backend source adapter are
interfaces because those boundaries are genuinely replaceable.

## Canonical model

The UI addresses Manga and CanonicalChapter. A chapter contains ranked
ChapterSourceCopy records. English filtering occurs before merging and ranking.
Numeric keys preserve decimals such as 10.1 and 10.5. Non-numeric specials use
conservative distinct keys on the backend.

AniList IDs are authoritative metadata IDs. A MangaDex copy is attached only
after an exact normalized title/alias match; uncertain entries stay separate.
Author/year/external-ID matching and reversible merge audit belong on the server.

## Reading

The reader fetches the selected chapter, renders immediately, and pre-caches the
remaining images with three workers. At roughly 72% it resolves the next chapter.
Widgets remain lazy when bytes are cached. Progress is debounced while scrolling
and persisted on lifecycle changes and close. All source copies are attempted in
health order before a short error is shown.

## Trust boundary

Clients may mutate only their bookmark, progress, and settings records.
Canonical manga, rankings, mappings, health, tracking, jobs, merge audit, and
follower calculations are backend-owned. Admin SDKs bypass rules, so production
uses separate least-privilege identities.

## Environments

Development may use opt-in synthetic data and emulators. Normal builds use a
local profile and live public providers. A deployment that enables Firebase
requires valid defines plus the appAccess custom claim for cloud data; no
official production project identifiers are committed.
