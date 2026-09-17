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
else is a real failure.

---

## 1. A bounded probe, with a ceiling and a running ledger

**Ceiling: 200 requests.** Decide it before you start and stop at it. A probe
answers questions the documentation cannot:

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
| **content type** | `film`, `artwork`, `text`, `gif` | Which shelf it lands on. It must already be in `DevilsDictionary.Discovery.ContentTypes`; adding a fifth is an entry in that table and nothing else. |
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
refused with the list of valid values. An existing file is never overwritten.

`--archetype corpus` writes `lib/devils_dictionary/artworks/corpus/<slug>.ex` and
then tells you about **two edits it cannot make**, both pattern matches in shared
modules:

1. the kind in `@kinds` in `lib/devils_dictionary/artworks/corpus/manifest.ex`
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

## 4. The stub, and then the real one

The scaffold parses a **scaffolded envelope**, not the real API's:

```elixir
# GET
%{"results" => [%{"id" => _, "title" => _, "year" => _, "url" => _}], "next" => cursor}

# GraphQL
%{"data" => %{"search" => %{"nodes" => [...], "pageInfo" => %{"endCursor" => _, "hasNextPage" => _}}}}
```

It passes conformance as generated, which proves the wiring and nothing about the
source. Making it true is three edits in the provider and one in the fixture, and
they move together:

1. `request_options/1` — the real URL, parameters and headers
2. `parse/1` — the real response shape
3. `item/2` — the real external id, the real `preview_metadata`, and the real
   `match_details`, which is the identifier the match was made on:
   `"tags"` for QID identities, `"keywords"` for keyword ids, `"lines"` for a
   text attestation
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

Nineteen cases for a pipeline provider: the contract, admission, budget, positive
and negative cache, pagination, cleanup, identity, and the render through
`Culture.section`. Then the whole set plus the architecture test:

```bash
mix test test/devils_dictionary/discovery/conformance test/devils_dictionary/artworks/corpus/conformance test/devils_dictionary/discovery/conformance_coverage_test.exs
```

The architecture test fails if a registered provider has no fixture, if a fixture
is never run by a suite, or if a committed corpus manifest has no suite. That is
how this checklist stays a checklist.

For a corpus, add its suite by hand — one line naming the committed file:

```elixir
defmodule DevilsDictionary.Artworks.Corpus.Conformance.MyCorpusTest do
  use DevilsDictionary.Artworks.Corpus.Conformance,
    manifest: "priv/artworks/manifests/my-corpus-v1.json"
end
```

### Registering a provider changes tests that count providers

`:discovery_providers` is read by the source catalog, the home page's stats line
and several reader tests, so a fifth entry is not invisible. Scaffolding a
provider into the real config and running the full suite turns roughly a dozen
existing tests red — the registry assertion in
`test/devils_dictionary/discovery/providers_test.exs`, the source count in
`test/devils_dictionary_web/live/home_live_test.exs`, and the
`Repo.one!(Run)` assertions in
`test/devils_dictionary_web/live/culture_discovery_live_test.exs` that assume one
server provider makes one run. Those tests are the ones to update; none of them
is a defect in your provider. Run the full suite and look at every failure before
deciding which are yours:

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

If something is listening, use another port rather than pointing a second node at
`devils_dictionary_v2`:

```bash
mix compile
PORT=4017 mix phx.server
```

`mix compile` to completion **before** `mix phx.server`, every time. `phx.server`
compiles lazily, and an Oban worker whose module is not loaded yet is a job Oban
discards — *module is not a worker* — so discovery silently does nothing on the
first page you open.

Then open two or three word pages that exercise the provider, at **1280** and at
**375** CSS pixels, and check:

- the shelf appears under the right heading, with the provider named in the
  byline
- every item carries a reason naming an **identifier**, not just a term
- a page the provider declines shows no shelf for it at all, and spends no run
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
| The one reader surface | `lib/devils_dictionary_web/components/culture.ex` |
| Corpus manifests | `lib/devils_dictionary/artworks/corpus/manifest.ex`, `priv/artworks/manifests/` |
| Corpus seeding | `lib/devils_dictionary/artworks/corpus/seeder.ex` |
| Conformance | `test/support/discovery/conformance.ex`, `test/support/artworks/corpus_conformance.ex` |
| The architecture test | `test/devils_dictionary/discovery/conformance_coverage_test.exs` |
| The generator | `lib/mix/tasks/dd.provider.new.ex` |
| Worked examples | `lib/devils_dictionary/discovery/providers/cine_graph.ex`, `met.ex`, `test/support/fake_offset_discovery_provider.ex` |
