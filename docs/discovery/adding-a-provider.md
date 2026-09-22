# Adding a provider

The checklist, in order. Read [`README.md`](README.md) first — it is the model
this list assumes, and it is short.

Do the steps in this order. Each one exists because skipping it has cost a
session: the probe before the spec because a source's published rate limit is not
its real one; the spec before the generator because `--content-type` and
`--archetype` are decisions, not defaults; conformance before the browser because
a browser check measures whichever node won the job.

Everything below runs from the project root.

---

## 0. Before anything

```bash
mise install
mix deps.get
mix compile
```

Confirm the suite is green **before** you change anything, so a failure later is
yours:

```bash
mix precommit
```

One failure is environmental and not yours: `test/devils_dictionary/sources/manifest_test.exs`
needs the untracked `data/` dumps and fails in every fresh worktree. Anything
else is a real failure — **unless another checkout is running tests at the same
time**. Every checkout defaults to the same `devils_dictionary_test`, so two
concurrent runs trample each other's sandboxes and produce dozens of
`Ecto.StaleEntryError`, `MatchError` and `query_canceled` failures scattered
across modules you never touched. Measured on this repository: 45 failures
concurrent, **1 failure** on its own. Take your own database rather than
guessing which failures are real:

```bash
MIX_TEST_PARTITION=p1b mix precommit
```

`config/test.exs` appends that value to the database name, and the `test` alias
creates and migrates it. It is the same rule as one dev server per database, one
layer down.

---

## 1. A bounded probe, with a ceiling and a running ledger

**The ceiling is per phase, and the phase states it.** 200 requests is the
default; #109's Phase 3 sessions were each given **300**. Read your own brief
for the number, decide it before you start, and stop at it. A probe answers
questions the documentation cannot:

- What does the source actually return, field by field, for a word we care about?
- What **identifier** does it publish, and does the encyclopedia already hold the
  same one? (See *The one rule* in the README. If the answer is "none", the
  provider is a text provider matching by attestation, or it is not a provider.)
- What is the **measured** sustainable rate? The Met publishes 80 req/s and
  refused 44% of 2,600 requests at 1 req/s.
- What does it do when you go too fast — which status, and is there a
  `Retry-After`?
- What does the licence permit being **stored**, not merely shown?

Use `Req`. Never another HTTP client — `:httpoison`, `:tesla` and `:httpc` are
out, and `Req.Test` is what makes the suite offline.

Write the ledger **as you go**, into `docs/integrations/<slug>.md`. Running
totals, never a total at the end: a run that gets killed leaves a range instead
of a number, and #102 2b's ledger is a range for exactly that reason. The
generator writes the template for this file in step 3; if you want it before the
probe, run the generator first and fill the probe section afterwards.

Two rules that are not negotiable during a probe:

- **Never download image bytes.** Store a URL and the attribution that travels
  with it.
- **Public domain or explicitly licensed only**, checked on the object you are
  about to show, not on the query that found it. The Met's `isPublicDomain=true`
  search parameter is **not honoured** — measured, objects 108646 and 261944 —
  which is why the gate is applied to the hydrated object.

---

## 2. The spec — four decisions, written down

Put these in `docs/integrations/<slug>.md` before you generate anything. They are
the generator's flags, and changing one afterwards means regenerating.

| Decision | Values | How to choose |
|---|---|---|
| **archetype** | `discovery`, `corpus`, `both` | Live answers to a page → discovery. A fixed, checksummed selection seeded once → corpus. Both is legitimate; the Met is both. |
| **content type** | `film`, `artwork`, `image`, `text`, `news`, `music`, `gif` | Which shelf it lands on. It must already be in `DevilsDictionary.Discovery.ContentTypes`; adding an eighth is an entry in that table and nothing else. If the shelf already has a source, read [*Adding a source to an existing shelf*](#adding-a-source-to-an-existing-shelf) — the row's `attribution` and `evidence` columns are obligations on your items. |
| **transport** | `get`, `graphql` | What the API is. |
| **pagination** | `offset`, `cursor` | Whether the next page is an offset you compute or a token the source hands back. |

Also decide, and write down:

- the **identifier** the match is made on, and the crosswalk to the
  encyclopedia's
- the **pacing**, if the probe found a throttle: `request_interval_ms` and
  `min_retry_interval_ms` in `capabilities/0`
- whether the provider can **decline** a target (`covers?/1`), and how that is
  answerable as a cheap existence query

---

## 3. The generator

```bash
mix dd.provider.new demo --archetype discovery --content-type text --transport get --pagination offset
```

It writes:

| Path | What |
|---|---|
| `lib/devils_dictionary/discovery/providers/<slug>.ex` | the provider |
| `test/support/discovery/conformance/<slug>_fixture.ex` | its `Req.Test` stub and the target it covers |
| `test/devils_dictionary/discovery/conformance/<slug>_conformance_test.exs` | the one-line conformance suite |
| `docs/integrations/<slug>.md` | the ledger template |

and edits `config/config.exs` (the `:discovery_providers` entry, kept sorted, and
a `config :devils_dictionary, :<slug>` stanza) and `config/test.exs` (the test
stanza that makes `enabled?/0` true and points the endpoint at a `.test` host).

An unknown `--content-type`, an out-of-range flag value or a missing flag is
refused with the list of valid values. Every output path is checked before the
first one is written, so a collision on *any* of them refuses the whole run and
leaves nothing behind.

A slug is lowercase letters and digits in hyphen-separated words —
`poetrydb`, `open-library`, `chronicling-america` — with no leading, trailing or
doubled hyphen. It names the source row, the config key, the generated files
*and* the module, and `Macro.camelize/1` folds `demo-` and `demo` to the same
`Demo`, so anything ambiguous is refused rather than quietly redefining a module
someone else generated.

`--archetype corpus` writes `lib/devils_dictionary/artworks/corpus/<slug>.ex` and
then tells you about **two edits it cannot make**, both pattern matches in shared
modules:

1. the kind in `@kinds` in `lib/devils_dictionary/artworks/corpus/manifest.ex`,
   with all five keys:

   | key | what |
   |---|---|
   | `source` | the source slug the rows are attributed to |
   | `identity` | the row field this kind is keyed on |
   | `namespace` | the `external_identifiers` namespace that field is written to |
   | `work_kind` | the `work_details.work_kind` the seeder writes — `"artwork"`, `"poem"` |
   | `evidence` | `:depiction` when a row records the QIDs of what the work *shows* and a page can match on them; `:none` when it records identity and display facts only |

   `identity` and `namespace` differ for Wikidata, whose rows are keyed on
   `qid` and identified as `wikidata`, and `Corpus.Conformance` reads a seeded
   row back through `Manifest.identity_namespace/1`.

   `work_kind` and `evidence` exist because they used to be assumptions. The
   suite counted seeded rows as `work_kind == "artwork"` and asked every corpus
   to round-trip a depicted QID onto a page — both true of every corpus until
   one held poems, and a poem does not depict the word it uses. A corpus is now
   asked for the contract its `evidence` declares and held to that declaration:
   `:depiction` must have rows carrying QIDs, `:none` must have none.
2. an `entry/3` clause in `lib/devils_dictionary/artworks/corpus/seeder.ex`
   mapping one row onto a `DevilsDictionary.SourceIdentity.Entry`

Only someone who has read the source's own rows can write the second, so the task
prints them rather than guessing. Until both exist, `Manifest.new/3` raises on
that kind — which is the failure you want, rather than a manifest nothing can
seed.

Compile before anything else:

```bash
mix compile
```

---

## 3a. The kit, before you write a helper

Before you write `presence/1`, a user-agent line, an offset reader or — above
all — a word-boundary pattern, look in
`DevilsDictionary.Discovery.Provider.Helpers`. It has them, the generator
already imported the ones your flags imply, and the README's
[*The kit a provider imports*](README.md#the-kit-a-provider-imports) lists the
rest.

The one that is not negotiable is the **attestation gate**. If your provider's
evidence is that a work uses the word, the question is
`Helpers.whole_word?(text, term)` and never a `String.contains?/2`, a `~r/\b/`
of your own, or the source's own claim that it matched. That rule existed as
three byte-identical private copies until #144 Phase 1, two of them pointing at
the third as their authority, and `test/devils_dictionary/discovery/provider/helpers_test.exs`
now asserts the three providers agree line for line because they ask one
function.

If you find yourself writing something the kit nearly has, say so in the PR
rather than copying: a fourth copy is how the first three happened.

---

## 4. The stub, and then the real one

The scaffold parses a **scaffolded envelope**, not the real API's:

```elixir
# GET
%{"results" => [%{"id" => _, "title" => _, "year" => _, "url" => _}], "next" => cursor}

# GraphQL
%{"data" => %{"search" => %{"nodes" => [...], "pageInfo" => %{"endCursor" => _, "hasNextPage" => _}}}}
```

It passes conformance as generated — which proves the wiring and nothing about
the source. (It had **not** passed since #116 M6 landed the evidence check: the
scaffold wrote a `:query` reason onto whatever shelf you asked for, and five of
the six rows refuse one. The generator now writes a reason of a class its row
admits, gates an attestation shelf through the kit's `whole_word?/2`, and
carries the credit an `attribution: :required` row demands. Fixed in #144
Phase 1; this paragraph was stale for three phases.)

Making it true of the real source is three edits in the provider and one in the
fixture, and they move together:

1. `request_options/1` — the real URL, parameters and headers
2. `parse/1` — the real response shape
3. `item/2` — the real external id, the real `preview_metadata`, and the real
   `match_details`, which is the identifier the match was made on:
   `"tags"` for QID identities, `"depicts"` for a live depiction, `"keywords"`
   for keyword ids, `"lines"` for a text attestation — **declared** by two
   further keys the shared reason builder reads (#144 Phase 0):

   | key | values | what it does |
   |---|---|---|
   | `"kind"` | one of `MatchReason.kinds/0` | names the builder that reads your reason shape |
   | `"evidence"` | `"identity"`, `"attestation"`, `"query"` | the class, checked against your content type's row |

   Conformance asserts both, and asserts that the class you declared is the
   class the builder actually produced from your map. A reason shape none of
   the kinds reads is not a silent `:query` any more; it is a red suite, and
   the fix is a kind and a clause in `MatchReason` — named, shared and
   reviewed, which is the only kind of shared edit this checklist wants.
4. the fixture's `respond/1` — the same shape, from a real captured response

The fixture is not a second implementation of the provider. `stub/2` returns the
external ids the responses it installed will yield, per page, and the suite
asserts the pipeline delivered those and no others. Getting that list wrong makes
the suite fail, which is the point.

A fixture may also supply `covered_target/1` evidence (the Met's writes a
`refers_to` claim) and `uncovered_target/1` (a page the provider declines).

---

## 5. Conformance

```bash
mix test test/devils_dictionary/discovery/conformance/demo_conformance_test.exs
```

Twenty-three cases for a pipeline provider: the contract, admission, budget,
throttling, positive and negative cache, pagination, cleanup, identity, and the
render through `Culture.section`. Your fixture supplies three scenarios —
`:results`, `:empty`, `:paged`. The fourth, `:throttled`, is the kit's and costs
you nothing: it puts one `429` with a `Retry-After` in front of your `:results`
stub and asserts one deferral, one provider-wide backoff on your source row, the
refused request in the ledger, and then one success on the same run. Then the
whole set plus the architecture test:

```bash
mix test test/devils_dictionary/discovery/conformance test/devils_dictionary/artworks/corpus/conformance test/devils_dictionary/discovery/conformance_coverage_test.exs
```

The architecture test fails if a registered provider has no fixture, if a fixture
is never run by a suite, or if a committed corpus manifest has no suite. That is
how this checklist stays a checklist.

For a corpus, add its suite by hand — one line naming the committed file, at
`test/devils_dictionary/artworks/corpus/conformance/<slug>_corpus_conformance_test.exs`,
which is the path `mix dd.provider.new` prints and the ledger it writes records:

```elixir
defmodule DevilsDictionary.Artworks.Corpus.Conformance.MyCorpusTest do
  use DevilsDictionary.Artworks.Corpus.Conformance,
    manifest: "priv/artworks/manifests/my-corpus-v1.json"
end
```

### The registry is checked at boot

`DevilsDictionary.Discovery.Providers.validate!/0` runs from
`Application.start/2`, before the supervisor, so a bad declaration is a node
that refuses to start rather than a `KeyError` on the first page that reaches
you (#144 Phase 0). It checks, per registered module: the five registration
callbacks; a `source_attrs/0` the catalog can seed (slug, name, attribution,
tier, and a `logo` under `priv/static/images/sources/` for the badge — or none,
and the badge is a monogram; see `docs/discovery/source-marks.md`); a `capabilities/0` with the six documented keys at the documented types,
at least one operation and one content type, every content type one
`ContentTypes` can present; pacing keys that are non-negative integers **where
declared** (absent is legal and means unpaced); and, for a module claiming
`background: true, transport: :server`, every callback in
`Providers.pipeline_callbacks/0` — which includes `validate_mapping/2`, because
the pipeline calls it on every render as well as mid-run. It also checks that
every `:source_policies` key names a registered slug, so a renamed provider
cannot leave a dead override behind.

If your provider does not boot, read the message: it collects every complaint
rather than stopping at the first.

### Registering a provider should turn no test red

`:discovery_providers` is read by the source catalog, the home page's stats line
and several reader tests, so a new entry is not invisible — but it is not
supposed to cost you anything either. The four files that used to count
providers now assert **membership and per-provider runs** instead of totals:

| File | What it asserts now |
|---|---|
| `test/devils_dictionary/discovery/providers_test.exs` | the shipped modules are *in* the registry, and each pipeline provider is scheduled for its own content type, transport and pagination |
| `test/devils_dictionary_web/live/home_live_test.exs` | the stats line counts the source rows the fixture seeded, whatever that number is |
| `test/devils_dictionary_web/live/culture_discovery_live_test.exs` | each test registers the one provider it is about, so `Repo.one!(Run)` means *that provider's run* |
| `test/devils_dictionary_web/live/film_identity_flow_test.exs` | the same, for the film flow |

It was eleven red tests when PoetryDB registered in Phase 2, and the fix is
`#109`'s Phase 1c. Measured after it: scaffolding `demo` into the real config and
running the full suite gives **1,244 tests, 1 failure** — the environmental
manifest test and nothing else.

So if registering your provider *does* redden something, do not update the test
to match your provider. Read it: either it is counting again, which is a finding
against this checklist, or your provider is doing something the others do not.

```bash
mix precommit
```

---

## 6. The browser proof

Only after conformance is green. A browser check before that measures a provider
you have not finished writing.

**One dev server per database.** Two Oban nodes on one database steal each
other's jobs, and the one that wins runs *its* code. A Phase 1a session measured
the Met's pacing at 1.17 s instead of 3 s because the main checkout's server on
port 4007 executed the branch's queued run with `main`'s code. Check the port
first:

```bash
lsof -nP -iTCP:4007 -sTCP:LISTEN
```

If something is listening, find out **which database it is on** before you do
anything about the port — the hazard is a second node on one database, and a
different port does not prevent that, it guarantees it:

```bash
lsof -a -p <pid> -d cwd          # which checkout it is

# and which database that process is actually on — its pool's client ports,
# looked up in pg_stat_activity
ports=$(lsof -a -p <pid> -iTCP -sTCP:ESTABLISHED -nP |
  awk 'NR>1 {split($9,a,"->"); split(a[1],b,":"); print b[2]}' | paste -sd, -)
psql -tAc "select distinct datname from pg_stat_activity where client_port in ($ports)"
```

Ask the connection, not the configuration. A per-database connection count
answers "which databases are busy", which is not the question: with two
databases in the list you still cannot say which one *that* server is on. And
the checkout's `config/dev.exs` is not the answer either — `DD_DATABASE` or a
runtime `DATABASE_URL` in the environment that server was started with beats
it, and you are not in that shell. Its own sockets cannot be wrong.

If the pool connects over a unix socket rather than TCP there are no client
ports to match; then read the environment the process was started with
(`ps -E -p <pid>` on macOS) before falling back to the checkout's config.

- **Same database as yours** → that server has to stop. Another port does not
  help: both nodes poll the same `oban_jobs` table, and your run will be
  executed by whichever code the other checkout compiled. Ask the owner, stop
  it, run one node.
- **A different database** → use another port and leave it alone.

```bash
mix compile
PORT=4017 mix phx.server
```

The same rule one layer down applies to tests: **one test run per test
database**. Four BEAM VMs on `devils_dictionary_test` produced 41 phantom
failures during the Phase 1b audit. Take your own with `MIX_TEST_PARTITION`, as
§0 says.

And if you clear a provider's cache mid-session to force a re-fetch, delete the
**result**, not the run: `discovery_request_attempts.run_id` is `ON DELETE
CASCADE`, so deleting a run takes its ledger rows with it, and the count you
report afterwards is short by exactly the requests you are trying to account
for (four rows, #116 Phase 2).

`mix compile` to completion **before** `mix phx.server`, every time. `phx.server`
compiles lazily, and an Oban worker whose module is not loaded yet is a job Oban
discards — *module is not a worker* — so discovery silently does nothing on the
first page you open.

**A changed `source_attrs/0` does not reach a row that already exists.**
`Discovery.ensure_source/1` inserts `on_conflict: :nothing`, and it is the only
writer of a provider's `sources` row — `Sources.Catalog.seed!/0` seeds the six
MVP-0 sources and not the providers — so a tier, a name or an attribution you
changed is still the old one in the database you are about to browse, and the
shelf you measure is ordered by the old tier (Openverse, #116 Phase 3). Check
the row and update it by hand before the proof, and say in the PR body that the
row changed, because there is no deployment step in this repository that will
do it for you. Query the database the server you are about to browse is on —
`devils_dictionary_v2` unless `DD_DATABASE` says otherwise:

```bash
psql -d "${DD_DATABASE:-devils_dictionary_v2}" -c "select slug, tier, name from sources where slug = '<slug>'"
```

Then open two or three word pages that exercise the provider, at **1280** and at
**375** CSS pixels, and check:

- the shelf appears under the right heading, with the provider named in the
  byline
- every item carries a reason naming an **identifier**, not just a term
- a page the provider declines shows no shelf for it at all, and spends no run.
  **A provider that declines nothing has no subject here** — a text provider
  matching by attestation covers every word, and the default `covers?/1` of
  `true` is right for it. Do not tick this box; verify the nearest true thing
  and say that is what you did: open a word the source has no result for and
  check that the shelf is empty, that the run is recorded `no_results`, that it
  spent **one** request, and that reloading the page spends none because the
  negative cache answered.
- `document.documentElement.scrollWidth === 375` at 375 — no horizontal page
  scroll

Headless Chrome's `--window-size` sets the window and not the layout viewport, so
drive the 375 px check over CDP rather than trusting the CLI flag.

Save the screenshots into `docs/discovery/` with the issue, the page, the width
and the date in the filename, as the existing ones do:

```
docs/discovery/issue-109-phase1a-soldier-1280-2026-09-17.jpg
docs/discovery/issue-109-phase1a-soldier-375-2026-09-17.jpg
```

Record every live request in the ledger as you go. `discovery_request_attempts`
is the record of what was actually spent, per source.

---

## 7. The pull request

```bash
mix precommit
git switch -c codex/<issue>-<slug>
git add -A
git commit
git push -u origin HEAD
gh pr create --base main
```

**Under 150 files.** CodeRabbit skips a larger diff silently, so a 200-file PR is
an unreviewed PR that looks reviewed. Check before you open it:

```bash
git diff --name-only main...HEAD | wc -l
```

If a corpus manifest pushes it over, that is a signal to land the manifest in its
own PR.

---

## 8. The report

Comment on the issue with:

- the **conformance output**, pasted, not described
- the **ledger**: requests spent, against the ceiling
- the **browser proof**: the screenshots and what they show, including the 375 px
  measurement
- **every place the code disagreed with the brief**, and what you did about it.
  This is the most valuable part of a report and the easiest to leave out. The
  code wins; say so and say why.
- **anything left out**, named as left out. A skipped step described as done is
  worse than a skipped step.

Report failures as failures, with their output. `mix precommit` with one
environmental failure is *1,1xx tests, 1 failure* and the name of the failing
file — not "green".

---

## Adding a source to an existing shelf

The case where the content type already exists — a second image source, a
second GIF source once K10 opens, a second quote source once #65 lands. It is
the same checklist as above with less to decide, and three obligations the
row's own columns state (README, [*Many sources, one shelf*](README.md#many-sources-one-shelf)).
Nothing in shared code changes; if you find yourself editing `Culture`,
`ContentTypes` or `Shelf`, stop and say why in the report.

1. **Declare the type and nothing else.** `content_types: [:image]` in
   `capabilities/0`; the shelf, its heading, its card and its order already
   exist. Do not add a heading, a badge colour, a section or a tab: a shelf
   never shows one provider's items in their own box.
2. **Your tier is your place in the turns.** `Shelf.interleave/3` orders
   sources by `tier` from your `source_attrs/0` and then by slug. Declare the
   tier the source deserves, not the one that puts you first.
3. **Name your identity, and the upstream one.** `identifiers` on every item:
   your own `{namespace, external_id}`, and, if you are an aggregator, the
   namespace and id of the file you aggregate — Openverse's Commons title,
   Openverse's Flickr id — so `Shelf.dedup/2` folds your copy into the
   original's without either provider knowing about the other. Put the
   **full-size** media URL in `image_url`; it is the join key of last resort,
   compared canonically (host and path only). The thumbnail is yours alone and
   is never compared.
4. **Read the row's `attribution`.** On a `:required` shelf every item carries
   `license`, `license_url`, `creator`, `creator_url`, `attribution` (the line,
   ready to show) and `source_url` in `preview_metadata`; the renderer shows
   the line beneath the thumbnail, always, and conformance fails the first
   item without one. On a `:credited` shelf, write `credit_line` when the
   source has one. On a `:none` shelf, write nothing per item. Every one of
   those URLs reaches an `href` straight out of your response, so the renderer
   allows only an **absolute `http(s)` URL with a host** (`Culture`'s
   `external_href/1`, #116 Phase 3) — anything else, a relative path or a
   `javascript:` scheme an upstream record carried, is silently not a link,
   so write absolute URLs or none.
5. **Read the row's `evidence`, and declare yours.** Your reasons must be of a
   class the row admits, and conformance asserts each one. An identity-bearing
   source writes `"tags"` or `"depicts"`; a text source writes `"lines"` (with
   a `"locator"` when the source has a better one than a line number); a
   stock-photo search on the `:image` shelf writes no reason shape at all and
   is described as the search result it is — the only shelf where that is
   allowed. Whichever it is, say so in `match_details["kind"]` and
   `match_details["evidence"]`, because the row is checked against your
   declaration and not against a guess at your map's shape. A search result on
   any other shelf is a red suite, not a product decision to make in a
   provider.
6. **Conformance, then the browser.** Your own suite (§5), the whole set, and
   the multi-source check, which runs on two stubs and does not need you.
   Then open a page where the shelf already has another source and check the
   three things a single-source proof cannot: the items take turns, a file both
   sources hold appears once, and the credit line is readable on every card
   without a pointer, at 375 px too.

---

## Quick reference

| Thing | Where |
|---|---|
| The provider contract | `lib/devils_dictionary/discovery/provider.ex` |
| The registry | `config :devils_dictionary, :discovery_providers` in `config/config.exs` |
| The pipeline | `lib/devils_dictionary/discovery.ex` |
| Budget, pacing, retries | `lib/devils_dictionary/discovery/budget.ex`, `transport.ex` |
| Freshness and quota policy | `lib/devils_dictionary/discovery/policy.ex` |
| The content-type table | `lib/devils_dictionary/discovery/content_types.ex` |
| The match reason | `lib/devils_dictionary/discovery/match_reason.ex` |
| Order and duplicates across sources on one shelf | `lib/devils_dictionary/discovery/shelf.ex` |
| The multi-source shelf check | `test/devils_dictionary/discovery/conformance/multi_source_conformance_test.exs`, stubs in `test/support/discovery/multi_source/` |
| The one reader surface | `lib/devils_dictionary_web/components/culture.ex` |
| The shared sense-evidence read (`covers?/1`) | `lib/devils_dictionary/discovery/page_evidence.ex` |
| Corpus manifests | `lib/devils_dictionary/artworks/corpus/manifest.ex`, `priv/artworks/manifests/` |
| Corpus seeding | `lib/devils_dictionary/artworks/corpus/seeder.ex` |
| Conformance | `test/support/discovery/conformance.ex`, `test/support/artworks/corpus_conformance.ex` |
| The architecture test | `test/devils_dictionary/discovery/conformance_coverage_test.exs` |
| The generator | `lib/mix/tasks/dd.provider.new.ex` |
| Worked examples | `lib/devils_dictionary/discovery/providers/cine_graph.ex`, `met.ex`, `test/support/fake_offset_discovery_provider.ex` |
