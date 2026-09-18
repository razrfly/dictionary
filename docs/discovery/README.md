# Cultural discovery

How a word page comes to show a film, an artwork, a text or a GIF — what the
shared pipeline does, what a provider is responsible for, and the rules that are
not negotiable because they are what keep this a dictionary rather than a search
results page.

This describes the code at the commit you are reading. Where a design document
and this page disagree, the code wins and this page says what the code does.
[`adding-a-provider.md`](adding-a-provider.md) is the checklist; this is the
model behind it.

---

## The one rule

**Association is identity, never text.**

A provider's own search is a text search, and text is not evidence. The Met's
`q=war` returns a uniform, a Greek oil flask and a photograph album, and nothing
in that ranking says which of them is *about* war. So a search is used for one
thing — generating candidates — and the decision to keep a candidate is made by
comparing an **identifier** the provider publishes against an **identifier the
encyclopedia already asserts**:

| Provider | Its identifier | The encyclopedia's | How they meet |
|---|---|---|---|
| CineGraph | a TMDb keyword id | the lemma | exact keyword match on the word |
| The Met | a Wikidata QID on a subject tag | a QID a sense `refers_to` | equal, or reached in ≤2 `P31`/`P279` steps |
| Wikimedia Commons | a `P180` *depicts* QID in the file's own structured data | a QID a sense `refers_to` | equal QID; the search proposes, the hydrated statements dispose |
| The committed corpora | a `P180` depiction or a Met tag QID | the same `refers_to` | equal QID |
| Artsy (retired client) | a gene id | a gene recipe on a sense | equal gene, read from the committed pilot only |

A **text** provider is the exception that proves it: a text has no identity claim
to make about a word, so its evidence is **attestation** — this work *uses* this
word, at this locator. It is shown as *uses “war” at line 4* and never as *about
war*. The identity that a text does carry is its author's, through a QID
crosswalk in its manifest where one exists.

Nothing in the pipeline enforces this. It is enforced by review, by the shape of
`DevilsDictionary.Discovery.MatchReason`, and by the fact that a reason with no
identifier in it renders as *the provider returned this result for “war”*, which
is embarrassing enough to be a prompt.

---

## Two archetypes, and no third

### A discovery provider

Answers a page **live**, through the shared pipeline, by implementing
`DevilsDictionary.Discovery.Provider`. It is registered in
`config :devils_dictionary, :discovery_providers`, and that list plus the module
is the whole of its registration — the source catalog, `mix dd.discovery`, the
runtime freshness overrides and the word page all read the registry and none of
them names a provider.

### A corpus

A committed, checksummed **selection** in `priv/artworks/manifests/`, built once
and seeded onto the registry by `DevilsDictionary.Artworks.Corpus.Seeder`. It
makes no provider call at seed time and none at read time. The reason it is a
file rather than a query: the #99 P0 probe measured the Met's own search totals
as parameter-order-sensitive — the same highlight query answered 2,310, 2,299 and
62 depending on the order the parameters were written in — so a corpus that
re-ran its own search would be a different corpus every time it was seeded and
nobody could say which objects a page had been showing.

A source may be **both**. The Met is: a discovery provider over its live search,
and `met-highlights-v1` as a corpus. Anything that is neither is a defect to fold
in, not a third shape to keep.

The reader does not distinguish them beyond one thing: a corpus item carries
`archetype: :corpus`, which sorts it after every live result on its shelf and
makes its note say *held locally* rather than *searched for on this visit*. It
was not asked for on this visit, and a shelf that opened with the catalog would
bury the answer the page actually went and got.

---

## The pipeline, stage by stage

Everything below happens in `DevilsDictionary.Discovery` unless another module is
named. A definition never waits for any of it.

### 1. The target is the page's lexeme set

`target_for_page/3` builds the target from the rendered word page:

```elixir
%{
  object_id: 147_197,           # the lexeme the page opens on
  lexeme_ids: [55_026, 147_197, ...],  # every lexeme at this address
  term: "war",
  language: "en",
  relevance: "term_unverified"  # "term" when the page is one lexeme
}
```

`object_id` still names **one** lexeme, because `discovery_mappings.target_object_id`
is a registry identity and a set is not one — but it is the lexeme the page opens
on (its first, already ranked noun before verb by `WordPage`), not the lowest
object id. `/define/war` is seven lexemes sharing one address and the lowest id
is a prefix; the noun is what the page is about.

`lexeme_ids` is the whole page, read by `DevilsDictionary.Lexicon.page_scope/1`
— a query anchored on a **lexeme id**, matching every lexeme with the same
language and the same lemma or slug. It is anchored on an id and not on the
string a reader typed, so `/define/war` and `/words/147197/war` resolve to the
same set. `Discovery.page_lexeme_ids/1` is the shared accessor: a target from a
page carries the set already; one rebuilt from a mapping pays one query for it.

Evidence is read from the whole set. A QID hangs off a sense of the noun, and
scoping the evidence to one lexeme would put no artwork on `/define/war` at all
while the encyclopedia plainly says what *war* means. The shelf still says
*Relevance to this particular meaning is unverified*; narrowing a match to one
sense is the assessor's job (#101), not this pipeline's.

### 2. Coverage — the provider declines before anything is spent

`covers?/1` is optional and its default is `true`: a keyword search can be run
for any word, so CineGraph never declines. The Met can and does — its match key
is a QID the target's senses already refer to, and for a target with no such link
there is no query to make and no result that could pass the identity gate. About
99% of pages are in that state. Wikimedia Commons declines on exactly the same
question, and since Phase 3a both read it through
`DevilsDictionary.Discovery.PageEvidence` rather than each holding its own copy
of the query.

Declining is how a run whose only possible outcome is empty is never admitted,
and how a page avoids showing a shelf that was never going to hold anything. The
word page asks it too, on the first disconnected render, before any run exists.

It must be answerable as an **existence** question. The Met's and Commons's is
`PageEvidence.any?/1`, a `Repo.exists?` — it must not pay for the ordering, the
dedup and the labels that only a mapping about to be built has any use for.

### 3. The mapping — a versioned recipe

`ensure_automatic_mapping/3` asks the provider for `automatic_mapping/1`, which
returns `{operation, parameters}`. The parameters are the recipe, frozen: the
term, the language, the relevance, and whatever evidence the provider matched on.

A mapping is **immutable and versioned**. `create_mapping_version/2` takes an
advisory lock on the mapping key, disables the previous version and inserts the
next one, so a recipe never changes under a run that is already using it.

`mapping_identity/1` is the optional callback that makes this true of evidence as
well as of parameters. A provider whose recipe freezes data that can move
underneath it returns a short digest of that data; it is appended to the mapping
key, so evidence moving produces a **new mapping version** rather than a reused
row still carrying the old parameters, and it is recomputed before a run
publishes, so a run cannot outlive the claim that justified it. The Met needs
this: a `refers_to` claim can be withdrawn or replaced while coverage stays
non-empty, and without the fingerprint a mapping created for QID A would keep
querying A after the encyclopedia had moved to B.

### 4. Admission — one run, coordinated in the database

`admit/5` decides, under two advisory locks (one per source, one per
mapping-and-position), in this order:

| Condition | Answer |
|---|---|
| the provider is disabled or its source is inactive | `{:deferred, :provider_disabled}` |
| the source is in provider-wide backoff | `{:deferred, :provider_backoff}` |
| this position failed recently | `{:deferred, :backoff}` |
| a refresh inside the cooldown | `{:cached, run}` |
| a fresh cached run for this position (persistent providers) | `{:cached, run}` |
| an identical request already pending or running | `{:queued, run}` |
| the source's queue is at its cap | `{:deferred, :queue_full}` |
| otherwise | insert the run, enqueue `RunWorker`, `{:queued, run}` |

Two visits to the same page do not make two runs. Two nodes do not either — the
coordination is a row and a lock, not a process.

### 5. Execution — the provider does I/O, and only here

`execute_run/1` takes an execution lease, re-checks that the mapping is still
enabled, that the adapter version has not moved and that the parameters still
validate, and then calls:

```elixir
provider.retrieve(operation, mapping_parameters, request_parameters, request_fun)
```

`request_fun` is the **only** way a provider reaches the network. It is
`DevilsDictionary.Discovery.Transport.request/4` bound to this run, and it is
what makes the budget, the pacing and the retries impossible to bypass: a
provider that called `Req` directly would be outside all three.

A provider returns one of:

- `{:ok, %{request_parameters:, items:, next_cursor:, completion_reason:}}`
- `{:error, code}` — a string the run records
- `{:deferred, code, seconds, request_parameters}` — try again later

`completion_reason` is `:results` or `:no_results` (or a provider's own reason,
such as CineGraph's `:no_exact_keyword`). An empty answer is a **negative cache**,
not a failure.

### 6. The transport — budget, pacing, retries

`Transport.request/4` calls `Budget.claim/3` before every single outbound
request. The claim is a `discovery_request_attempts` row inserted under the
source's advisory lock, so it survives the transaction and is visible to the next
claimant on any node. It refuses in three ways:

- the source is in provider-wide backoff → deferred
- this stage has used its `max_retries + 1` attempts → `retry_budget_exhausted`
- the rolling window is full → deferred with the seconds until the oldest attempt
  ages out, and the run's `error_code` becomes `request_budget`

The budget is policy, per source, validated by `DevilsDictionary.Discovery.Policy`:

| key | default (`config/config.exs`) | Met's override |
|---|---|---|
| `request_budget_limit` | 30 | 1,000 |
| `request_budget_window_seconds` | 60 | 3,600 |
| `positive_refresh_seconds` | 30 days | — |
| `empty_refresh_seconds` | 24 hours | — |

**Pacing is a capability, not a `Process.sleep/1`.** Two optional keys in
`capabilities/0` are read by the transport:

- `request_interval_ms` — the sustained gap between this provider's *successful*
  requests. `Budget.claim/3` places every attempt in a slot at least that far
  after the provider's latest one, **across every run on every node**, and the
  transport sleeps until its slot. A page that costs `1 + n` requests holds the
  rate however many stages it runs, and two concurrent runs share the rate
  instead of doubling it. The Met's is 3,000 — measured, and the difference
  between 44% of 2,600 requests refused at 1 req/s and none at 3 s/request.
- `min_retry_interval_ms` — the shortest gap after a *failure*. The transport
  waits the longer of this and the shared `:retry_delay_ms`, so a provider that
  answers a burst with a throttle does not retry straight back into it.

A status code is a provider's dialect, not a fact. The default retryable set is
`429` and any `5xx`; `retryable_status?/1` widens it. The Met's `403` is a volume
throttle arriving with no `Retry-After`, and treating it as an authentication
verdict would be both wrong and unrecoverable. A `Retry-After` header — delta
seconds or IMF-fixdate — is honoured at its full length and written to the
source, not to the run, so every run on that provider waits.

A status code is not the only place a throttle hides. MediaWiki-style APIs
answer an overloaded replica with **HTTP 200** and put the complaint in the
body — a `maxlag` error carrying its own `Retry-After` header beside a status
that says everything is fine. A provider on such an API has to read its own
envelope for the error before it reads it for results, and return
`{:deferred, code, seconds, request_parameters}`; a transport that only watches
status codes will retry straight back into the lag it was asked to wait out.

### 7. Persistence — cache first, identity only if earned

`persist_results/3` writes, for every item:

1. a **source record** — the disposable cache row, with the provider's own
   payload
2. a **discovery result** — the normalized item, its `match_details`, its
   `preview_metadata`, its position and its resolution state

Then, and only if the provider exports `identity_record/1`
(`DevilsDictionary.SourceIdentity.Adapter`), the item is resolved to a durable
registry identity through `SourceIdentity.resolve/1`. A provider without that
callback gets `resolution_state: :insufficient_evidence` and no `object_id`, and
its results are pure cache. That is a legitimate place to stop.

**A discovery appearance is never a claim.** No `illustrates` assertion is
written, ever. A keyword-matched film is not curated evidence that the film is
about the word; it is a provider result, shown as one. The path from a result to
a claim runs through a contributor at `/connect` and a reviewer, and it is
deliberately not automatic. Durable identity (an object in the registry) and
editorial relevance (a reviewed claim) are different questions with different
lifecycles — withdrawing a result does not touch the object it resolved to, and
retiring an identity does not withdraw a claim.

### 8. Cleanup

`cleanup/0` runs every fifteen minutes from `Oban.Plugins.Cron` via
`DevilsDictionary.Discovery.CleanupWorker`. It does two things:

- **recovers abandoned runs** — a run whose execution lease has expired goes back
  to `:pending` and is re-enqueued. A worker that died mid-run does not strand a
  page on *still looking*.
- **deletes one bounded batch of disposable cache** — runs older than
  `retention_seconds`, or beyond `retained_attempts_per_position` for their
  position, **except** the runs currently on display. The page's answer is never
  the thing that gets collected.

### 9. The reader

`Discovery.state/2` answers per provider, and never makes a request. The word
page merges those states with the catalog's shelf and hands the map to
`DevilsDictionaryWeb.Culture.section/1`.

**A pipeline provider ships zero components.** One shelf per content type, in
the table's order, live results before corpus items, then one item from each
source in turn, one item per identity, each item carrying the reason it is
there and the credit its shelf requires. Nothing in `Culture` knows which
providers exist; how several sources become one rail is
[*Many sources, one shelf*](#many-sources-one-shelf) below.

GIPHY is the one exception, and it is a transport exception rather than a
licence to add chrome: its requests are made by the reader's own browser, so it
has no pipeline state to render and it still draws through
`DevilsDictionaryWeb.GiphyShelf.section/1` beneath the shared section. K10 of
`#109` says the kit renders its shelf through K2's chrome; the shipped code does
not, because a browser-transport provider has no `Discovery.state/2` items for
`Culture.section` to draw. Folding it in means giving it a server transport
first, which is parked until written caching approval exists.

---

## The content-type table

`DevilsDictionary.Discovery.ContentTypes` is data, not code. Adding a content
type is an entry here and nothing else — not a new branch in `Culture` or
`WordLive`.

| type | heading | badge | image slot | thumbnail keys, in order | attribution | evidence admitted |
|---|---|---|---|---|---|---|
| `:film` | Films | Film | `aspect-[2/3]` | `poster_url`, `still_url`, `image_url`, `media_url` | `:none` | identity |
| `:artwork` | Artworks | Artwork | `aspect-square` | `image_url`, `thumbnail_url` | `:credited` | identity |
| `:image` | Images | Image | `aspect-square` | `thumbnail_url`, `image_url` | `:required` | identity, query |
| `:text` | Texts | Text | **none** | — | `:none` | attestation |
| `:gif` | GIFs | — | `aspect-square` | `media_url`, `image_url` | `:none` | query |

Shelf order is film · artwork · image · text · gif, and it is the order of
`ContentTypes.known/0` rather than insertion order. `:image` arrived with
Wikimedia Commons (#109 Phase 3a): a photograph of a soldier is a visual work
but it is not an artwork, and a shelf headed *Artworks* over a US Army
photograph was the page misnaming what it shows. The row was the whole of the
change. It is headed *Images* and not *Photos* — #116's M4 said *Photos*, and
Phase 1 settled it the other way: Commons's `image/*` files are photographs but
also engravings, maps, posters and diagrams, and *Photos* over a 1916
recruiting poster would be the misnaming the row was added to end.

A type with no `aspect` has **no image slot at all**, so a text result renders as
a title and its source rather than an empty poster frame. That is the whole
reason the table has an aspect column.

The last two columns are #116's, and every row carries both — the module
raises at compile time if one does not:

- **`attribution`** is what a card owes the item's maker, read by the
  renderer. `:required` means every item carries a credit and the card shows it
  beneath the thumbnail, always visible, in place of the creator line (a
  required credit names the creator by construction). `:credited` means the
  card shows a credit line when the item carries one, beside the creator line.
  `:none` means the shelf byline is the whole credit. The line is
  `preview_metadata["attribution"]` when the provider wrote one and
  `"credit_line"` otherwise; the conformance suite asserts it is rendered for
  every item on a `:required` shelf.
- **`evidence`** is the classes of match reason a row admits, from
  `MatchReason.evidence/1`: `:identity` (a tag, depiction, gene or keyword —
  an identifier the encyclopedia already asserts), `:attestation` (the work
  uses the word, at a locator) or `:query` (a text search's own ranking).
  The conformance suite asserts every result a provider delivers against its
  shelf's row, and the renderer reads it to describe an admitted `:query`
  reason as *Search result for “war”, ranked by the provider and not matched
  on an identifier* — and, on any shelf that does not admit one, to leave the
  prompt-shaped sentence alone.

---

## Many sources, one shelf

A reader looking up *war* sees **one** row of images, not a row from Commons
and then a row from whatever joins it. This is what the code does to make that
true for every content type that takes more than one source (#116, Phase 1),
written from the code at this commit. Nothing here is a provider's business: a
provider declares a type, writes its items honestly, and the shelf does the
rest.

### A shelf is a content type; a source is a row on it

K2, restated so nobody reopens it. The reader never shows a shelf per provider.
Adding a source to an existing shelf is a provider through the kit declaring
the type ([*Adding a source to an existing shelf*](adding-a-provider.md#adding-a-source-to-an-existing-shelf));
adding a *type* is a row in `ContentTypes` and nothing else. A **content type**
is a shelf; a **work kind** (`work_details.work_kind`) is a registry identity;
they are many-to-one, and a corpus declares the second where a provider
declares the first.

| type | sources now — live | sources now — corpora | next | reaches a page by |
|---|---|---|---|---|
| `:film` | CineGraph | — | none: single-source by decision, CineGraph aggregates on its side | identity |
| `:artwork` | The Met | `met-highlights-v1`, `wikidata-famous-v1`, the Artsy pilot | AIC, Cleveland via corpora (#100) | identity |
| `:image` | Wikimedia Commons | — | Openverse (#116 Phase 2), Unsplash and Pexels (Phase 3) | identity, or a labelled search |
| `:text` | PoetryDB, Open Library | `poetrydb-v1`, `open-library-v1` — **identity only, by decision; neither reaches a page** | Chronicling America as a corpus, Gutenberg | attestation, live only |
| `:gif` | GIPHY, browser-only, outside this chrome | — | Tenor, after K10 | a labelled search |
| `:quote` | — | — | Wikiquote, Gutenberg extraction, after #65 | identity (`(author_id, body hash)`) |

The `:text` decision is #109's second residual, settled here: the two text
corpora are seeded `evidence: :none` and stay that way. Serving attestation
from held text would mean storing the lines or snippets that attest the word,
which is a retention decision — Open Library's snippets come from the Internet
Archive's full-text search and are not ours to hold, and the same argument
that keeps image bytes out (D14) keeps them out. The live text providers
already answer attestation on a visit and resolve to the **same** registry
identity as the corpus rows (`olid`, `poetrydb_poem`), so a corpus's job on the
Texts shelf is nil and its job on the entity page is identity and display
facts. A text corpus that wants to reach a page needs its own retention
decision, recorded in its manifest kind, not a quiet change to `:none`.

### Order: archetype, then turns across sources, then position

`DevilsDictionaryWeb.Culture.shelves/1` hands every state's items on one shelf
to `DevilsDictionary.Discovery.Shelf.compose/4`. Live before corpus stays (K2).
Within each archetype the shelf takes item 1 from every contributing source,
then item 2, and so on; sources are ordered by **tier** (aristocracy → middle →
plebs, from the source row, carried on the state as `tier`) and then by slug;
within a source, the order the source gave. No relevance ranking across sources
(#101's), no trust weighting beyond tier.

A live state is one source. The catalog state is several — `Artworks.shelf_items/2`
stamps each item with its corpus's `source_slug` and `source_tier` — so the
corpus group takes turns between the Met and Wikidata instead of treating
"the catalog" as one source. `Artworks` still interleaves its own candidates
before the twelve-slot limit, through the same `Shelf.interleave/3`, so that
both corpora get slots; the list it used to keep for the order of the turns
(Wikidata, then the Met) is gone, and because both corpora are middle-tier the
Met's slug now leads. That is the one visible change on `/define/soldier` and
`/define/ox`, and Phase 1's browser proof records it.

### Duplicates: identity first, then media

`Shelf.dedup/2` keeps one item per identity, first wins, computed at read time
and never by rewriting a provider's persisted results. `Shelf.keys/1` says what
makes two items one thing:

- the registry object they resolved to (`object_id`);
- every `{namespace, external_id}` in the item's `identifiers` — the ones the
  provider proposed, read back onto a persisted `Result` from its source
  record's current revision as a virtual field — and the item's own
  `external_namespace`/`external_id`, so an aggregator that names the Commons
  file it came from joins the Commons item without Commons knowing;
- the **canonical** full-size media URL (`image_url`, then `media_url`): host
  and path, lower-cased host, no scheme, port, query or trailing slash. Never
  the thumbnail, which is each provider's own derivative.

The composition sorts by archetype, tier and slug **before** dedup, so the
better-tiered source's copy of a duplicate is the one that survives, and takes
turns afterwards among what is left. A dropped duplicate's keys join the kept
item's, so a third item sharing only the dropped one's other key collapses too.
`Artworks.per_work/2` — one candidate per work before the limit — is a caller
of the same function keyed on the object. Perceptual-hash dedup is out of scope
until a ledger shows it is needed.

### Licence and attribution are item fields with fixed names

Every item on a shelf whose row requires attribution carries, in
`preview_metadata`: `license` (a short form — `CC-BY-4.0`, `CC0-1.0`,
`Unsplash`), `license_url`, `creator`, `creator_url`, `attribution` (a
ready-made line the renderer shows verbatim), and `source_url` (the landing
page). Commons, which predates the rule, carries `license`, `license_url`,
`author` and a `credit_line`, which is what the renderer falls back to; its
`artist` line doubles as the credit and the `:required` rule shows one line,
not two. The renderer shows the line beneath the thumbnail, always visible,
never on hover; the table's `attribution` column says which shelves show it.

### Hotlink only, no bytes

Unchanged by Phase 1 and stated here because the next sources are gated on it
(D14). The pipeline persists URLs and metadata, never image bytes; the card is
an `<img>` with the provider's own URL and `referrerpolicy="no-referrer"`; there
is no proxy and no re-hosting. A source whose terms require download and forbid
hotlinking (Pixabay) is not a candidate; a source whose terms forbid persisting
URLs at all (GIPHY) stays outside this chrome.

### The multi-source check

`test/devils_dictionary/discovery/conformance/multi_source_conformance_test.exs`
is the check none of the single-provider suites can be: two stub providers
(`DevilsDictionary.Discovery.MultiSource.Middle` and `.Plebs`, written by one
macro, differing in tier, slug and the class of reason they write) declare
`:image`, each answers eight items with one shared upstream identity and one
shared media URL spelled two ways, and the shelf read back through
`Discovery.states/1` and `Culture.section/1` is one rail of **fourteen**,
interleaved by tier before slug, each provider credited once, the attribution
line present on every item, the search stub's reason described as a search
result and the identity stub's naming its QID. The single-provider suite
asserts the two table columns for every registered provider: a `:required`
shelf renders every item's credit, and every reason is of a class the row
admits.

---

## The match reason

`DevilsDictionary.Discovery.MatchReason` is one struct and one renderer. Before
it there were three, all now gone: a private helper in
`DevilsDictionaryWeb.Culture` branched on whether a persisted result's
`match_details` held Met tags, CineGraph keywords or neither;
`DevilsDictionary.Artworks.suggestions/2` composed a sentence into
`match_reason.detail`; and the tall artwork card prefixed that sentence with a
word of its own.

```elixir
%MatchReason{
  kind:       :keyword | :tag | :depiction | :gene | :attestation | :query,
  identifier: "Q198",          # the provider's own identity for it
  term:       "War",           # the text that carried the identifier
  relation:   :exact | :broader | :related | :attests,
  scope:      :sense | :lexeme,
  locator:    "tag Q198",      # carried into /connect
  note:       nil,
  reached:    "War"            # what a non-exact relation arrived at
}
```

`reached` is an eighth field K3 of #109 does not list, and the shelf cannot be
built without it. The Met's two-step broader walk says *Related to “War” through
the tag “American Civil War” (Q8676)*, in which `Q8676` is the **tag**'s QID and
“War” is the concept the walk **reached**. Neither `term` nor `note` can hold
both without one of them meaning two different things.

`describe/1` names the identifier wherever there is one, because an identifier is
what separates a reason from an impression: *tagged “Soldiers”* is what a reader
thinks and *tagged “Soldiers” (Q4991371)* is a fact anyone can go and check.

`from_result/2` reads a live provider's `match_details` — `"tags"`, `"depicts"`,
`"keywords"`, `"lines"` — and falls back to a `:query` reason when the provider
named none. A line map may name its own `"locator"` (*page 12*, *stanza 2*);
the `"number"` form (*line 4*) is the fallback, and a line with neither attests
without a locator. `evidence/1` folds the kinds into the three classes the
content-type table admits, and `describe/2` takes the admitted classes so a
search result is called one only where the row allows it.
`from_candidate/1` reads a corpus candidate. Both end as the same struct and the
same sentence.

---

## Composition: what discovery is, next to the rest of the encyclopedia

This section folds in [#96](https://github.com/razrfly/dictionary/issues/96),
which closed without its document.

The encyclopedia keeps three things apart, and discovery sits across all three:

**Durable identities** live in the `objects` registry — a lexeme, a sense, an
entity, a work. They are addressable, they survive a source renaming something,
and they are retired rather than deleted. A discovery result may *resolve to* one
of these (`identity_record/1` → `SourceIdentity.resolve/1`), which is how a
CineGraph film becomes a local film entry with backlinks.

**Source material** is what a source said, revisioned and attributed: a sense, a
Johnson entry, a Wikipedia summary — and a discovery result's source record, which
is the same shape and the same table. The difference is retention: a discovery
result is **disposable cache** with a freshness policy and a cleanup worker, and
a Johnson entry is not.

**Reader composition** is what a page chooses to show. `/define/:slug` is a
resolver and `/words/:id/:slug` identifies a lexeme, but both render through
`WordLive`/`WordPage` and both aggregate. The current order — definitions, then
one shelf per content type in the table's order — is the current default, not a
permanent editorial requirement. Per-entry selection of sections, items and
prominence is unresolved design, and the open questions are #96's: what identity
a composition targets, what item granularity is selectable, how defaults and
overrides interact, and who edits and reviews a composition.

What is settled, and what discovery must not blur:

- A provider result is **not** curated evidence of a concept. It is shown with
  the reason it matched and the caveat that relevance to a particular meaning is
  unverified.
- Durable identity is separate from the claim that a work illustrates a meaning.
  #93 gave films the first; only review gives anything the second.
- A corpus candidate carries `review_state: :not_yet_reviewed` and, for a
  contributor, a link into `/connect` preselecting the meaning and the evidence
  revision. The composer link is in the shelf's *About these results* list — the
  only place a contributor now finds it, after the tall candidate cards left the
  word page.

---

## Development, and the rule that costs sessions

**`mix compile` to completion before `mix phx.server`, every time.** `phx.server`
compiles lazily, and an Oban worker whose module is not loaded yet is a job Oban
**discards** — *module is not a worker* — so discovery silently does nothing on
the first page you open. Three sessions have been caught by this.

**One dev server per database.** Two Oban nodes pointed at the same database will
steal each other's jobs, and the one that wins runs *its* code. A Phase 1a
verification session measured the Met pacing at 1.17 s instead of 3 s because the
main checkout's server on port 4007 executed the branch's queued run with `main`'s
code; the proof was in the run's own row, whose `next_cursor` came back in the
pre-#109 format. If port 4007 is taken, the question is not which port to use
next — it is **which database that server is on**. If it is on yours, it has to
stop; another port does not help, because both nodes poll the same `oban_jobs`
table. If it is on a different database, use another port. The development
database is `devils_dictionary_v2`.

**One test run per test database, too.** Every checkout defaults to
`devils_dictionary_test`, so two concurrent `mix test` runs trample each other's
sandboxes: 45 failures scattered across unrelated modules —
`Ecto.StaleEntryError`, `MatchError`, `query_canceled` — where an isolated run
of the same commit has one. `MIX_TEST_PARTITION=<name> mix test` appends the
name to the database and the `test` alias creates it, which is the cheap way to
be sure a failure is yours.

**Tests never reach the network.** Every HTTP call goes through a `Req.Test`
stub; an unstubbed call raises. `config :devils_dictionary, :discovery_req_options`
names the plug for the discovery transport — `{Req.Test, <the provider module>}` —
and `:req_options` names `{Req.Test, DevilsDictionary.Absorb.Clients}`, the stub
the bounded Wikidata adapter registers under, which is what the Met's broader
walk goes through. A Met fixture has to stub both.

Useful tasks:

```bash
mix dd.discovery --definition-source bierce --providers cinegraph --limit 20 --dry-run
mix dd.discovery.check
mix dd.artworks.seed --manifest priv/artworks/manifests/met-highlights-v1.json --dry-run
```

The first two need provider credentials from the ignored `.env`, which a fresh
worktree does not have: `dd.discovery.check` exits with *CINEGRAPH_API_KEY is
missing or blank*, and `dd.discovery --dry-run` still selects its targets and
then reports *0 eligible providers*. Both are the tasks working correctly. The
Met needs no key, so it is the provider a keyless checkout can actually drive.
`dd.artworks.seed --dry-run` needs nothing but the committed manifest.

---

## Conformance

`DevilsDictionary.Discovery.Conformance` is one suite every provider passes, or
the suite is red. It is written against `DevilsDictionary.Discovery` and nothing
else — it never calls a provider's own functions except through the pipeline,
because a provider that only works when called directly is exactly the defect
worth catching.

A provider supplies a **fixture** (`Conformance.Fixture`) with the two things the
shared code cannot invent: a target this provider covers, and this provider's own
`Req.Test` stub. The stub returns the external ids it will produce, per page, and
the suite asserts the pipeline delivered those and no others.

Two profiles, chosen from the provider's own capabilities:

- **full** — `background: true`, `transport: :server`, and the pipeline callbacks
  exported. Admission, budget, positive and negative cache, pagination, cleanup,
  identity and the reader.
- **registry-only** — anything else. Artsy declares `background: false` and GIPHY
  declares `transport: :browser`; neither exports `retrieve/4`, so there is no
  run to drive. The suite checks the contract half and asserts that the pipeline
  gate refuses to schedule them.

`DevilsDictionary.Artworks.Corpus.Conformance` is the corpus half: checksum
verification, refusal of a row edited without its checksum, an idempotent seed to
identical counts, every label inside `entities.preferred_label`'s
`varchar(255)`, and a depicted-QID round trip onto a page whose meaning refers to
it.

`test/devils_dictionary/discovery/conformance_coverage_test.exs` is the
architecture test: every module in `:discovery_providers` has a fixture, every
fixture is run by a suite, every committed corpus manifest has a suite, and every
other JSON file in `priv/artworks/manifests/` is an Artsy import manifest rather
than something nobody checks. Adding a provider without covering it turns the
suite red.

---

## Where things stand

| Source | Archetype | Reader surface | State |
|---|---|---|---|
| CineGraph | discovery (GraphQL POST, cursor, keyword-id match) | `Culture.section` | live-verified, #88 |
| The Met | discovery (GET, offset, tag-QID identity + ≤2-step broader walk) **and** corpus (`met-highlights-v1`, 1,644) | `Culture.section` | #102 2a/2b |
| Wikidata famous paintings | corpus (`wikidata-famous-v1`, 1,575) | `Culture.section` | #102 2b |
| PoetryDB | discovery (GET, offset, attestation) **and** corpus (`poetrydb-v1`, 2,903 poems) | `Culture.section` | #109 Phase 2 and 1c |
| Wikimedia Commons | discovery (GET, MediaWiki `continue` cursor, `P180` depicts-QID identity, per-file licence gate) | `Culture.section`, the `:image` shelf, attribution `:required` | #109 Phase 3a |
| Artsy | registered, registry-only — its 43 artworks and their gene mappings reach a page through the catalog; the private client was retired in #109 Phase 3a | `Culture.section` | #86, K9 of #109 |
| GIPHY | registered, browser-only, transient | its own `GiphyShelf` component, **not** `Culture.section` | parked pending caching approval, K10 |

`priv/artworks/manifests/` also holds four Artsy **import** manifests
(`DevilsDictionary.Artworks.Manifest`, `schema_version` 2, `candidates` keyed on
`qid` + `artsy_artwork_slug`). They share the directory with the two corpus
manifests and are a different format;
`Corpus.Manifest.corpus_manifest?/1` is how the two are told apart.

---

## Further reading

- [`adding-a-provider.md`](adding-a-provider.md) — the checklist, in order
- [`../integrations/`](../integrations/) — one page per source: what was probed,
  what it costs, what was measured
- [`../integrations/source-identity.md`](../integrations/source-identity.md) —
  the durable cross-provider identity contract
- [`../adr/0001-encyclopedia-model.md`](../adr/0001-encyclopedia-model.md) — the
  registry and the assertion contract
- [`../adr/0002-bounded-general-entity-selection.md`](../adr/0002-bounded-general-entity-selection.md)
  — bounded selection
