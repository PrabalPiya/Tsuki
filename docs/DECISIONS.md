# Decisions

## AniList is the rating authority

averageScore divided by 10 is displayed consistently. Missing scores show
Unrated. Kitsu or source ratings are never blended.

## MangaDex is the initial page source

The documented v5 API supports search, English feeds, and MangaDex@Home page
resolution. Access is anonymous/read-only and bounded. The reader retains
MangaDex and scanlation-group attribution. No scraping, private API, CAPTCHA,
anti-bot, DRM, or paywall bypass exists.

## Discover uses honest live categories

AniList exposes current popularity, trending, and score ordering but not
trustworthy week/month/year historical series for this product. The shipped app
therefore labels these categories Trending, Popular, and Top Rated. Synthetic
development cards remain clearly marked as previews.

## Safe local development

The local profile and public read-only providers make a fork runnable without
granting it access to someone else's infrastructure. Demo mode is opt-in and is
for UI development only; production forcibly disables it.

## Stable page extents

The MVP uses stable reader extents so position restoration is predictable and
decoded images can leave memory with the lazy list. Future adapters may provide
validated dimensions without changing the reader contract.
