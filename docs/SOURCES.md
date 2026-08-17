# Sources

## Shipped providers

| Provider | Search | Metadata | Chapters | Pages | Updates |
|---|---:|---:|---:|---:|---:|
| AniList | Yes | Yes | No | No | No |
| MangaDex | Yes | Supplemental | Yes | Yes | Yes |

AniList GraphQL is the only displayed rating source. Its documented base rate is
90 requests/minute, but the official documentation currently notes a degraded
30 requests/minute limit; deployments must honor response headers and Retry-After.
Discover uses AniList's current TRENDING_DESC, POPULARITY_DESC, and SCORE_DESC
sorts and labels them accordingly; it does not claim historical rankings.

MangaDex uses the official v5 API and MangaDex@Home. The adapter requests English
only, validates page lists, bounds pagination, and retains MangaDex/scanlation
group credits. Review the current acceptable-use policy before every release;
at the time of implementation it requires attribution and prohibits ads/paid
services for API consumers.

Official docs:

- https://anilist.gitbook.io/anilist-apiv2-docs
- https://api.mangadex.org/docs/
- https://gitlab.com/mangadex-pub/mangadex-api-docs

## Adding a source

Implement MangaSource with explicit capabilities. Return source records; never
make UI-specific models. Validate response sizes, page counts, MIME types, URLs,
redirects, languages, and chapter values. Add timeouts and bounded concurrency.

An official integration must use a documented public API, supported integration,
or explicit permission. It must not bypass DRM, CAPTCHAs, anti-bot systems,
paywalls, or Cloudflare, and must not reverse-engineer a private API. Fork-only
adapters are not automatically accepted upstream.
