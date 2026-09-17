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

## Where GIPHY sits in the discovery kit (2026-09-18, #109 Phase 1a/1b)

`DevilsDictionary.Discovery.Providers.Giphy` is registered in
`config :devils_dictionary, :discovery_providers`, and that registration is the
whole of its relationship to the server pipeline. It declares
`transport: :browser`, `persistence: :transient` and `background: false`, and it
exports no `retrieve/4` — so `Providers.server_providers/1` never offers it to
the run worker, `Discovery.state/2` answers `:idle` for it on every page, and no
GIF result is ever written to the database. That is K10 of #109: nothing changes
here until written caching approval exists.

It is covered by `DevilsDictionary.Discovery.Conformance` in the **registry-only**
profile, which asserts the contract half — the slug, the source attributes, the
capability shape, the `:gif` content type — and then asserts that the pipeline
gate refuses to schedule it.

**The shelf is still its own component.** K10 says the kit renders GIPHY's shelf
through K2's chrome; the shipped code does not, and cannot as things stand:
`DevilsDictionaryWeb.Culture.section/1` draws from `Discovery.state/2` items, and
a browser-transport provider has none. `WordLive` therefore renders
`DevilsDictionaryWeb.GiphyShelf.section/1` beneath the shared section, fed by
`Giphy.browser_config/1`, exactly where it always was. Folding it into the shared
chrome means giving it a server transport first.

`config/test.exs` sets `enabled: false`, so the suite never builds a browser
config. See [`../discovery/README.md`](../discovery/README.md).
