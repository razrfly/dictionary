# Automatic GIPHY discovery

Eligible definition pages load eight G-rated GIFs automatically using the dedicated
GIPHY Web API key from the ignored development `.env` (`GIPHY_API_KEY`). There is
no initial search button or approval gate. Production reads the same environment
variable. Never use the private CineGraph key here.

Search and media requests go directly from the browser to GIPHY. Results retain
provider order and original URLs. Still previews animate only after Play; Pause
and reduced-motion changes stop playback. Pagination is explicit, capped at three
pages, with duplicate in-flight prevention, navigation cancellation and a ten-second
timeout. Failures do not affect definitions or films.

No GIF results or media URLs are written to database or browser storage. Reloads
therefore spend a request. Film caching from issue #92 is unchanged. Shared GIF
caching is not part of this restored direct-browser mode.

The 100-request hourly allowance is enforced by GIPHY across the key. A conservative
in-memory browser counter and Retry-After cooldown reduce repeated calls within
LiveView navigation, but do not represent a shared cross-visitor quota or survive a
full reload. There are no automatic retries. This beta limit is unsuitable for
unrestricted traffic without an appropriate provider plan.

Verify with `node --test assets/js/giphy_shelf.test.mjs`, `mix test`, and
`mix assets.build`. Browser verification should separately record real calls,
loaded thumbnails, Play/Pause, explicit pagination and navigation.

## Film cache settings

Server discovery defaults to 30-day nonempty and 24-hour empty freshness. Override
with `DISCOVERY_POSITIVE_REFRESH_SECONDS` / `DISCOVERY_EMPTY_REFRESH_SECONDS`, or
`CINEGRAPH_DISCOVERY_POSITIVE_REFRESH_SECONDS` / `CINEGRAPH_DISCOVERY_EMPTY_REFRESH_SECONDS`.
Age triggers refresh on an eligible visit; stale allowed results remain visible
while refresh fails or is deferred. Cleanup protects the current successful set.
Source disablement and withdrawal still override display. Database request admission
coordinates server-provider budgets across processes. These cache and admission
settings do not govern the direct-browser GIPHY transport.
