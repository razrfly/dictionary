# Issue 88: automatic cultural discovery handoff

Date: 2026-09-12

This slice adds demand-driven, term-level cultural discovery to every valid
definition page. Definitions are built and rendered from the local registry
first. A connected LiveView then subscribes to its exact target, checks each
eligible server provider independently, lazily creates an automatic recipe, and
admits an Oban job. Provider completion updates only the `In culture` section
over PubSub. Invalid routes, audit/demo pages, disabled providers, and dead
renders do not create discovery work.

The first live provider is CineGraph. There are no per-word mappings, preloaded
answers, title-search fallback, accepted `illustrates` assertions, contributor
controls, or additional live adapters in this change.

## Data and lifecycle

Migration `20260912085220_create_discovery_cache` adds exactly three tables:

- `discovery_mappings` stores immutable provider instructions. Its foreign keys
  point to the existing object, source, and actor registries. `(mapping_key,
  version)` is unique; a partial unique index permits one enabled version. A
  database trigger rejects inactive/non-lexeme/non-sense targets, identity-
  inactive senses, and inactive providers. Another trigger permits only the
  operational `enabled` flag to change on an existing version.
- `discovery_runs` stores one bounded root or cursor-page attempt, including the
  adapter version, sanitized exact request, stable request/position keys, page
  context, request count, status, completion reason, timing, refresh/expiry,
  safe error code, and display permission. Constraints enforce typed lifecycle
  shapes. A partial unique index coordinates one pending/running request across
  nodes. Completed request semantics and outcomes are immutable at the database
  boundary, apart from display withdrawal.
- `discovery_results` stores stable namespaced provider identity, response
  position, validated match details, and the permitted bounded preview. An
  optional nullable FK links only to a pre-existing verified object identity.
  A second FK points to the provider's existing durable `source_records`
  identity; display policy lives there so cache deletion or refresh cannot
  resurrect a withdrawn item. Results are unique by external identity and
  position within one response.

Runs delete their disposable results; mappings delete their disposable runs.
Registry objects use `nilify_all`, while mapping target/source/actor FKs use
`restrict`. Cleanup therefore cannot cascade into objects, claims, or evidence.
An Oban cron worker runs bounded cleanup independently of successful requests,
removes completed attempts older than seven days, keeps at most three attempts
per mapping/request position, and requeues abandoned leased runs. Source-record
display policy survives this disposable-cache cleanup.

Reader selection uses only the current enabled mapping and a successful,
display-allowed, unexpired root response. It selects the newest successful root
by start time, so an older slow response cannot replace it. A newer failure does
not hide or extend an older still-permitted response. Cursor pages must share
the root's mapping and UUID context. The visible feed deduplicates evidenced
object identity first and provider identity otherwise; matching titles do not
merge unrelated films. Withdrawal is enforced even when an independently
retained object or claim survives. Reinstatement is a separate explicit
operation requiring an existing actor and reason; ordinary visits, refreshes,
and provider responses cannot do it.

## Provider contract and CineGraph behavior

The provider behaviour makes transport, background execution, persistence,
operations, pagination, attribution, and automatic mapping capabilities
explicit. A transient non-film fixture proves the lifecycle can deliver a
provider card over PubSub without persisting result rows. It is test evidence,
not another live integration.

CineGraph runs server-to-server with the existing `CINEGRAPH_API_KEY` Bearer
credential. `CINEGRAPH_GRAPHQL_URL` optionally overrides the endpoint. The key
is loaded only by runtime configuration and never enters mappings, runs,
LiveView assigns, task output, or browser code. Missing credentials disable the
provider without affecting definitions.

For each new root attempt the adapter:

1. Calls `searchMovieKeywords` for the original visited term.
2. Applies only trimmed, case-insensitive exact-name matching. Substrings are
   ignored. An absent exact match is a successful negative cache.
3. Retains every distinct exact TMDb keyword ID, sorted deterministically, and
   calls `discoverMovies` with explicit `ANY` semantics. There is no title or
   synonym fallback.
4. Normalizes at most 12 items with `tmdb_movie` identity, source URL, optional
   TMDb poster reference, title/year, and every supplied matched keyword/genre.
   Full responses and overviews are not stored.

Cards say `Found through the keyword …` only when CineGraph supplied a match.
Otherwise they say `Search results for …`. Polysemous resolver pages explicitly
say that relevance to the particular meaning is unverified. The reader sees
`CineGraph · keywords: TMDb`, a factual details disclosure, a source link, and
an intentional text card when no poster exists. Successful zero results,
failure, capacity deferral, hard expiry, and withdrawal remain distinct states.
Remote poster references are loaded lazily from TMDb's image CDN with no
rehosting and no referrer.

## Operating values

The initial values are adjustable application configuration:

| Control | Value |
|---|---:|
| Root/page result limit | 12 |
| Cursor pages retained per context | 5 maximum, only on reader demand |
| Database-enforced provider execution leases | 2 |
| Admission queue cap per provider | 100 pending/running runs |
| Rolling provider budget | 30 outbound attempts/minute, retries included |
| Positive and negative refresh eligibility | 24 hours, demand-triggered |
| Explicit refresh collision cooldown | 60 seconds per mapping/position |
| Hard preview expiry | 7 days |
| HTTP timeout and retry | 10 seconds; at most 2 bounded retries |
| Failure backoff | 5 minutes |
| Retention | 7 days; 3 completed attempts per mapping/position |

Budget claims use a PostgreSQL advisory lock and are charged before every HTTP
attempt. Per-stage attempt counters persist in the run across Oban snoozes, so
deferral cannot reset retry accounting. Numeric and HTTP-date `Retry-After`
values become a provider-wide database not-before time; long waits snooze the
job and never block a worker process. Resolution progress is stored in the run
so a resumed film stage does not repeat a successful keyword lookup. Admission,
provider-wide queue capacity, provider-wide execution leases, mapping version
creation, and refresh deduplication use database locks and constraints rather
than browser-local flags or node-local Oban concurrency claims.

## Reusable task

`mix dd.discovery` is intentionally a last-stage testing/warming surface. It
selects actual current definitions through their source relationships, applies
the SQL limit before enumeration, and invokes the same target, mapping,
admission, cache, Oban, transport, and normalization services as a page visit.

Examples and all supported flags are in `mix help dd.discovery`. The bounded
default is 20 and maximum is 100. `--after OBJECT_ID` starts the next
deterministic selection batch; it is never printed as proof that unfinished
work completed. Failed, queued, or deferred work produces an exact `--resume
ID,...` command, and missing/retired resume identities fail explicitly. Dry-run
labels its next checkpoint as a preview rather than progress. `--providers all`
means enabled, active, server-executable background
providers; incompatible providers are reported rather than coerced. `--dry-run`
performs only local selection/capability checks and makes no discovery writes,
jobs, or external requests. Its completion report keeps positive caches,
negative caches, new nonempty/empty successes, failures, queued, deferred, and
unsupported providers separate; enqueued work is never called complete.

## Verification evidence

### Deployed API and local live application

The deployed `https://cinegraph.org/api/graphql` endpoint authenticated with the
existing redacted development key. A direct smoke call returned the exact
keyword `war` (TMDb 273967) among substring alternatives, and `discoverMovies`
with that exact ID returned stable movie IDs, cursors, and matched keyword
metadata. The Dictionary adapter then exercised the same deployed endpoint
through its real Req transport, budget, jobs, cache, and LiveView paths.

Clean-cache pilot outcomes:

| Term | Registry target | Outcome | Requests | Items | Provider time |
|---|---:|---|---:|---:|---:|
| war | 55,026 | success | 2 | 12 | 328.9 ms |
| nepotism | 198,692 | success | 2 | 5 | 140.3 ms |
| grief | 78,062 | success | 2 | 12 | 162.6 ms |

`nepotism` included TMDb movie 667216, `Infinity Pool`, matching the issue's
example through live resolution rather than seeded data. `war` and `grief` are
polysemous in the local registry and therefore display the unverified meaning-
relevance warning. No results were hand-selected. Live titles reflect the
provider's current ordering and include obscure/future material; this is a
source-match feed, not editorial quality ranking.

The unprepared Bierce batch selected 20 real definitions in stable object-ID
order. Its 34 outbound requests were 20 keyword lookups plus 14 film queries.
It produced 14 nonempty successes, 6 successful negative caches, 0 failures,
and 126 result rows. End-to-end run latency was 129.0 ms mean and 331.9 ms p95.
The rolling budget left three admitted jobs queued; the resumed invocation
reused 11 positive and 6 negative caches and completed exactly those three.
The longest recorded queue interval was 92.0 seconds. At measurement time the
three discovery tables occupied about 464 kB for 23 mappings, 23 runs, and 155
results.

A second run over the same batch made no calls for its 17 already-completed
caches. Two simultaneous explicit-refresh tasks on previously untouched
`great` and `peroration` targets created exactly one run per target: the first
reported one nonempty and one empty success; the competing process reported one
positive and one negative cache. Database counts were one run/two outbound
requests for `great` and one run/one outbound request for `peroration`.

Dry-run source selection was also demonstrated for 20 Bierce and 20 Johnson
targets. Both came from actual eligible current definition relationships,
reported the same CineGraph capability, supplied stable checkpoints, and made
no writes or requests.

### Browser and controlled fixtures

At a 1440×900 viewport, `war` rendered a three-column grid of 12 live results
(approximately 387 px per card in a 1200 px section) with no horizontal
overflow. At 390×844, `nepotism` rendered one 342 px column, five live results,
an intentional missing-poster card, a working details disclosure, and no
horizontal overflow. `peroration` rendered the cached successful-no-exact-
keyword message rather than a provider error. Definitions remained present in
each state.

Controlled Req/LiveView fixtures cover states that cannot be made deterministic
against a changing service: delayed completion with immediate definitions and
PubSub update without reload, provider failure versus successful empty, missing
posters, demo/invalid suppression, timeout/retry, malformed data, multiple
exact IDs with `ANY`, several match reasons, stale mapping responses, page-
context isolation and cap, hard expiry, withdrawal, retired/split/merged target
rejection, cross-process admission, budget/queue deferral, object identity
reuse, independent `illustrates` claim durability, and transient-provider
no-persist behavior.

### Audit repair verification

The follow-up pass for issue comment 5645185791 reran its seven independent
reproductions: all seven pass. The final `mix precommit` completed 863 tests
with zero failures. New repository assertions cover durable
withdrawal and accountable reinstatement, provider-wide execution leases and
recovery, numeric and HTTP-date `Retry-After`, global provider backoff,
successful empty transient delivery, exact transient refetch, multi-provider
failure isolation, mounted deactivation, stale transient-event rejection, and
exact task resume diagnostics.

Authenticated live CineGraph checks used the existing local server credential
without printing it. A fresh `impenitence` request completed as a one-request
successful negative cache; a fresh exact-resume request for `redemption`
completed with 12 items in two requests; rerunning it reused the positive cache
with no new work; and explicit refresh of the existing `influence` target
completed with 12 items in two requests. The unauthenticated endpoint correctly
returned a GraphQL `unauthorized` error, confirming the credential boundary.

Browser verification used the revised application and current cached provider
responses. At 1280×720, `war` rendered 12 cards in a 1200 px three-column grid
(386.7 px cards) with document width equal to viewport width. At an explicit
390×844 viewport, `nepotism` rendered five cards in one 342 px column with no
horizontal overflow; the details disclosure opened and exposed both rationale
and source link. `peroration` retained its definition and showed successful
empty rather than provider failure. Both browser sessions had zero console
errors.

## Remaining limitations and intentionally open work

- Exact spelling is discovery, not semantic interpretation. Polysemous terms
  remain visibly unverified; no automatic sense claim is created.
- CineGraph/TMDb keyword coverage and ordering determine live usefulness.
  Substring matches, translations, synonyms, title fallback, and editorial
  ranking are intentionally absent. Distinct films with identical titles remain
  distinct when their stable IDs differ.
- Provider cursors do not promise a corpus snapshot. Five pages is the current
  safety cap, and only the reader can request pages after the first.
- Cached previews depend on provider display permission and hard expiry.
  Withdrawal is durable locally and can be explicitly reinstated; this slice
  does not add a separate remote takedown feed.
- Queue and budget deferrals are retried by the existing Oban job or a later
  visit/task resume. This feature does not continuously warm unused pages.
- Public deployment, more live providers, curation, approval/review, voting,
  contributor roles, and catalog-wide crawling remain outside issue 88.

Evidence categories are deliberately separate: provider-shaped fixtures prove
deterministic edge behavior, the local application proves the full server and
browser integration, and the deployed calls prove current CineGraph contract
and authentication. None is presented as a production throughput benchmark.

## Credential preflight (CineGraph #1128)

Run `mix dd.discovery.check` in the same environment as the server before a demo
or deployment. Missing/blank keys, a disabled provider, and an invalid endpoint
fail the command. Success confirms configuration only; it does not prove the
credential works. After provisioning a dedicated key, restart the server and
verify fresh war/nepotism/grief discovery, cache reuse and a genuine empty result.
Keep the production cutover gate open until live verification is recorded.

## Local development secrets

Copy `.env.example` to `.env` and paste the CineGraph key after
`CINEGRAPH_API_KEY=`. The file is ignored by Git and loaded only in development.
Restart the development server after editing. Exported environment variables
have precedence. Values may be unquoted or enclosed in matching single/double
quotes; shell expansion and inline comments are not supported. Only the two
CineGraph settings are read. Tests and production do not load this file.

The default endpoint is production CineGraph. For a local CineGraph server,
change `CINEGRAPH_GRAPHQL_URL` and use a key issued by that local server.
