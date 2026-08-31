# Tsuki Migration extension

Load this directory as an unpacked Manifest V3 extension in a Chromium-based
browser. Visit a manga site's personal library or bookmark page and press
**Collect this page**. Collection is additive and survives service-worker
suspension through `chrome.storage.local`. Export creates one versioned JSON
file for Tsuki's Library -> Import screen.

Supported dedicated adapters are MangaDex, ComicK (`comick.io`, `comick.dev`,
`comick.art`, and `comick.live`), Mangakakalot (`mangakakalot.gg` and
`mangakakalot.com`), Demonic Scans (`demonicscans.org/bookmarks.php`), and
MangaKatana (`mangakatana.com`).
Other HTTP(S) manga sites can be collected by the conservative generic adapter
when the current page is clearly a personal bookmarks, favorites, follows,
saved, or library page. It is injected only after the user presses the
extension button and receives temporary access only to that active tab.

The extension is bookmark-only. It never collects or exports chapter history,
latest-chapter labels, continue-reading targets, or reading progress. It also
never accesses or exports cookies, tokens, credentials, or browsing history.

Collection runs only on recognized personal pages: MangaDex Follows -> Titles,
and the bookmark/library routes on ComicK, Mangakakalot, Demonic Scans, and
MangaKatana.
Links inside recommendation, popular, related, carousel, navigation, sidebar,
and footer containers are excluded. Chapter links and chapter labels are
ignored.

After updating or reloading the unpacked extension, its popup can inject the
adapter into an already-open tab. Version 2.3.1 resets older stored collection
data, waits for dynamically rendered bookmark cards, and collects bookmarks
without reading progress. Visit each personal library and collect again. If a
site changes its layout, expand **Adapter diagnostics** in the popup to see
non-sensitive page and selector counts useful for updating its adapter.

Each adapter is isolated in `adapters/`. A site redesign should require only
that adapter and its explicit host permission to change.

Mangakakalot uses its known `.user-bookmark-item-right` cards and `.bm-title`
titles. The adapter follows the bookmark page's pagination with four
same-origin requests at a time, up to 100 pages. Demonic Scans has its own
adapter for `/bookmarks.php` and reads only `/manga/{slug}` bookmark links.

Every adapter emits the same normalized entry contract: `source`,
`sourceMangaId`, canonical HTTPS `sourceUrl`, cleaned `title`, `aliases`,
nullable `author`, nullable `coverUrl`, and `bookmarked: true`. The background
worker validates and normalizes this contract again before storing or exporting
an entry.

Unknown domains use ordered template profiles instead of one universal set of
selectors: Madara/WordPress, explicit bookmark-card libraries, list/grid
libraries, then a conservative semantic fallback. Detection also recognizes
an active Bookmarks/Library tab on account pages whose URL does not mention
bookmarks. The selected profile is shown in the popup and diagnostics.

For an unrecognized site or layout, press **Select bookmark list manually**.
The page picker highlights a visible area and shows its candidate-link count
before collection. Nothing is collected until the user confirms the selected
area. This provides a site-independent fallback for conventional DOM-rendered
lists without requesting permanent access to every website. Content hidden in
cross-origin frames, closed shadow roots, or private APIs still requires a
dedicated adapter from that website.
