# Urban Dictionary — one browser-fetched 📱 definition, never stored

Issue #136, split out of #134 Finding 3. Shipped on `codex/136-urban-dictionary`.

Every eligible word page carries one 📱 *Crowd* card. The reader's own browser
asks `api.urbandictionary.com` for it; this server never does. Nothing that
comes back is written to a database, to an export, or to browser storage, and a
card that cannot be filled removes itself from the page rather than apologising.

---

## 1. The terms, and why permission comes first

Read at `https://urbandictionary.help/tos/` on 2026-09-21:

> "Access to the Urban Dictionary API is available only with the express
> permission of Urban Dictionary and is governed by the Urban Dictionary API
> Terms of Service."

The only automation clause on that page forbids **submitting** content by bot.
Nothing addresses reading. `robots.txt` on the site disallows nothing at all.
User-submitted content is licensed by its authors *to Urban Dictionary* and is
sublicensable — so it is theirs to grant and not ours to assume.

That makes the order of work fixed, and its first step the owner's:

1. **The owner emails Urban Dictionary** asking for API permission, describing
   exactly what ships here. The session records the date; it does not send the
   email.
2. **This PR ships the browser-only stopgap** #134 Phase 3 describes.
3. **If they say no**, `active: false` on the source row turns the card off
   everywhere with no deploy, and the row survives as a link-out. If they say
   yes, their API terms replace this document's assumptions and a follow-up
   issue records what changed.

### The date

`config["permission_requested_on"]` on the source row is **`"pending"`** as this
ships. The owner confirmed on 2026-09-21 that they would handle the email and
gave no date, so no date was invented. When it goes, change one line —
`permission_requested_on:` in the `:urban_dictionary` stanza of
`config/config.exs` — and re-seed, or set it directly on the row; nothing else
reads it. `permission_status` is `"requested"`.

### What the email promises, and what the code therefore enforces

| Promise | Enforced by |
|---|---|
| One definition per word page | the hook takes the **first** matching entry and renders nothing else |
| Shown on demand | no job, no task, no crawl; a request happens when a reader opens a page |
| Fetched client-side | `phx-hook`, `globalThis.fetch`; there is no Elixir code path that can reach the endpoint |
| Attributed by author and date | the byline and the plaque, both naming the author and `written_on` |
| Linked to its permalink | *Read on Urban Dictionary*, validated to be `https` on `www.urbandictionary.com` |
| Never written to a database or browser storage | no `source_records`, no `senses`, no `localStorage`/`sessionStorage`; asserted by tests on both sides |
| Never exported | no record exists to export; `mix dd.export.replay` gains no record (see §7) |
| Rate-limited client-side | an in-memory budget of 60/hour and a `Retry-After` cool-down, no retries |
| Removable on request | `active: false` on the row, no deploy |

---

## 2. The endpoint, as measured on 2026-09-21

`GET https://api.urbandictionary.com/v0/define?term=<word>`

| Fact | Measured |
|---|---|
| Auth | none |
| CORS | `access-control-allow-origin: *` — a browser can call it directly |
| Body | `{"list": [ … ]}`, up to 10 entries |
| Per entry | `defid`, `word`, `definition`, `example`, `author`, `written_on` (ISO 8601), `permalink`, `thumbs_up`, `thumbs_down`, `current_vote`, `udimg_url`, `play_sound_url` |
| Unknown term | `{"list": []}` — *but see §3* |
| Rate limit | unpublished; nothing measured beyond a handful of requests |

### Votes: the finding that decides the ranking

**`thumbs_up` and `thumbs_down` are `0` on every entry.** Measured on
`bestiality`, `rizz` and `nepotism` in #134, and again here on `cromulent`,
`logomachy` and `rizz`: every entry of every response, zero and zero. The site
shows votes; this endpoint does not return them.

So the card **does not rank by votes and does not display them**. The list order
is Urban Dictionary's own ranking, and the decision is to take the **first
entry** — the one the site itself puts first — rather than invent a second
ranking out of the only other field available, the date. A test asserts the
zeroes against the captured sample, so the day the endpoint starts returning
real votes, that test fails and this decision gets re-taken deliberately.

---

## 3. The finding that is not in the issue: `/v0/define` fuzzy-matches

The issue records that an unknown term answers `{"list": []}`. That is true only
of a term with no near neighbour. Measured 2026-09-21:

```
term=logomachy  → 200, 2 entries, for "Logomashup" and "logomancy"
term=cromulent  → 200, 10 entries, 7 of them "Cromulent"/"cromulent",
                  the other 3 "Cromulent Fuckcrustable", "Corpulent",
                  "corpulent brony"
term=qqzzxwvpluffnarg → 200, {"list": []}
```

A card that trusted the status code would put a definition of *another word*
under this word's headword — `logomachy` would be defined as a portmanteau, and
`cromulent`'s plaque would say *one of 10 entries* when the site holds seven.

So the hook keeps only entries whose own `word` slugs to the same slug as the
term, and the card is absent when none does. This is what makes **`logomachy`
the honest empty** the acceptance asks for, and it is why the plaque's *N*
counts matching entries rather than `list.length`.

The slug used for that comparison is also the slug the `[bracketed]`
cross-links point at — see §5.

---

## 4. What ships

### The source row

Slug `urban-dictionary`, name *Urban Dictionary*, `tier: :plebs`,
`kind: :dictionary`, `access: :api`, `era_year: 1999`, licence
*Urban Dictionary Terms of Service; API access by permission*,
`license_url: https://urbandictionary.help/tos/`, `active: true`, and a `config`
that states the posture in the database rather than only here:

```elixir
%{
  "transport" => "browser only",
  "ingestion" => "none; nothing is stored",
  "permission_requested_on" => "pending",
  "permission_status" => "requested"
}
```

### Where the module lives, and why not the other two registries

`DevilsDictionary.Sources.UrbanDictionary`, registered in
`DevilsDictionary.Sources.OnDemand` — a **third** registry, added here.

- Not `Sources.Catalog.sources/0`: scorecard **A1** asks every catalog source
  for a finished absorb *and* a snapshot pin. This source will never have
  either, so registering it there turns A1 red on the day it ships and keeps it
  red for a reason that is about bookkeeping rather than about the app.
- Not `:discovery_providers`: the conformance suite asks every registered
  provider for a fixture and a **presentable content type**, and a definition is
  not a shelf. There is no `Discovery.ContentTypes` row for it and there should
  not be one.

`OnDemand.seed!/0` writes the row with the providers' `on_conflict: :nothing,
conflict_target: [:slug]` upsert, called from `Catalog.seed!/0`. Deliberately
*not* `Catalog.upsert!/3`, which refreshes `config` on every seed: `active:
false` is a kill switch and a re-seed must not undo it. There is a test for
that.

**A second on-demand source** goes beside this one: a module with
`source_attrs/0`, `enabled?/0` and `browser_config/1`, added to `@sources` in
`lib/devils_dictionary/sources/on_demand.ex`, with a `config :devils_dictionary,
:<slug>` stanza, a `runtime.exs` switch, a card component and a hook. What it
must not grow is a `retrieve/4` — the moment a server fetches it, it is a
discovery provider or an absorb adapter and belongs in the registry that grades
it.

### The card

`DevilsDictionaryWeb.CrowdCard.urban_dictionary/1` renders the **shell**: the
real 📱 header from `Word.source_card` (same glyph, same `tier_class(:plebs)`,
same solid left border — *not* the demo's dashed sample chrome), a ↗ link out, a
status line, an empty body and the plaque. It carries `phx-hook="UrbanDictionary"`,
`phx-update="ignore"`, `data-term`, `data-endpoint` and `data-define-path`, and
nothing secret, because there is nothing secret: the endpoint is keyless.

`assets/js/urban_dictionary.mjs` fills it. Strict envelope validation, the
word-match guard of §3, bracket links, the byline, the permalink and the plaque.
Any failure — network, timeout, non-200, a changed envelope, an empty list, a
fuzzy match — calls `this.el.remove()`. **The states are *card* and *absent*,
never an empty card and never an error message**: this is an extra, and a crowd
definition the reader did not ask for is not worth a complaint.

The plaque, always visible and server-rendered so it cannot vanish with the
script:

> Crowd-sourced and unreviewed. One of *N* entries on Urban Dictionary, by
> *&lt;author&gt;*, *&lt;date&gt;*. Fetched by your browser; nothing is stored here.

### Where it sits

In `WordLive`: one assign (`:urban_dictionary`, from `browser_config/1`) and one
template line, after the real cards and before `Culture.section` — exactly where
the demo's 📱 sample sat from U3 until this replaced it.

The source line (*Defined here by N sources*) counts server-known cards and does
not know about this one. That is left alone on purpose: it is a claim about what
has been **absorbed**, and nothing here is.

### The kill switches

Two, and either alone is enough, because `browser_config/1` returns `nil` unless
both pass:

| Switch | Where | Needs a deploy? |
|---|---|---|
| `URBAN_DICTIONARY_ENABLED=false` | environment, read in `config/runtime.exs`; default **true** | yes |
| `active: false` | the `sources` row | no |

`nil` means **no shell is rendered at all** — not a hidden one, not an empty
one. A LiveView test asserts each switch removes the element, the hook, the
endpoint string and the plaque from the HTML.

There is a third, incidental one: `?demo=1` has no discovery target, so the card
does not appear in demo mode either. A mode that invents data is the wrong place
to make a live request on the reader's behalf.

---

## 5. The bracket links, and the two slug rules

`[bracketed]` words in `definition` and `example` are Urban Dictionary's own
cross-link syntax — `[Sexual intercourse] between a [human] and …`. The card
renders each as a link to **our** `/define/<slug>`, which is the one thing this
card can do that the site cannot.

The slug has to be the one our own URLs use, which is
`DevilsDictionary.Registry.Lexeme.slug/1` — `Slug.slugify/1` with the downcased
lemma as its fallback. Minting it in the browser means a second implementation
of that rule, which is the kind of thing that agrees on the day it is written.

So both are asserted against one file, `assets/js/slug_cases.json`, and neither
test knows the expected values — it reads them:

- `test/devils_dictionary/sources/urban_dictionary_slug_test.exs` (Elixir)
- `assets/js/urban_dictionary.test.mjs` (`node --test`)

35 cases, covering what a bracket actually holds: phrases, Latin-1 accents,
apostrophes (dropped, not separated — `don't` is `dont`), punctuation that
separates, the common Latin ligatures, and a lemma with no slug at all (`++`).
**The bound:** a codepoint outside that range — CJK, Cyrillic — is transliterated
by the `slugify` package's own data table, which is not reproduced in JS. Such a
link lands on the miss page, which shows suggestions, rather than on a wrong
word.

---

## 6. Nothing is stored

| Store | Gains |
|---|---|
| `source_records` | nothing — asserted by a test after a page render |
| `senses`, `entries` | nothing — there is no materializer and no adapter |
| `discovery_request_attempts` | nothing — asserted by a test, and verified in the browser proof |
| `oban_jobs` | nothing — no worker, no cron line, no mix task |
| `localStorage` / `sessionStorage` / IndexedDB / cookies / Cache API | nothing — a test greps the hook's source, comments stripped, and fails on the mention of any of them |
| `priv/replay` | no **record** — see below |

One fixture is captured from the live site and no more:
`assets/js/urban_dictionary.sample.json`, the `term=cromulent` response of
2026-09-21, used as the JS test's sample. The signed, expiring `play_sound_url`
audio links were dropped from it: they carry an `Expires` parameter and a
signature and have no place in a repository.

### `mix dd.export.replay`: one honest caveat

With no `--source`, the task iterates `Sources.list_sources/0` and writes one
file per **row**. A new row therefore adds one entry to `priv/replay/MANIFEST.json`
and one 20-byte empty `urban-dictionary.jsonl.gz` — exactly as the nine existing
zero-record provider rows (`giphy`, `met`, `cinegraph`, `artsy`, `poetrydb`,
`commons`, `open-library`, `openverse`, `unsplash`, `pexels`) already do.

**No record is exported, because no record exists.** The archive's content is
unchanged. This is stated rather than hidden: it is a file-count change, not a
data change, and skipping zero-record sources would change the output for the
ten rows that already behave this way.

---

## 7. Verification

```bash
node --test assets/js/urban_dictionary.test.mjs
mix assets.build
MIX_TEST_PARTITION=p136 mix precommit
```

Browser proof at 1280 px and 375 px, in `docs/discovery/issue-136-*.jpg`:
`/define/bestiality` (the #134 test word, and a word whose top entry is a
definition of a sex act — the plaque is this phase's answer to that, per §8),
`/define/rizz` (a word where the crowd definition is the only modern one) and
`/define/logomachy` (no entry, §3 — the section is absent).

---

## 8. Not in this phase

A mature-content blur or gate (#134 open question 3). The plaque is this phase's
answer: the card says on its face that it is crowd-sourced and unreviewed, above
the fold, always. A page-level mature flag — from Wiktionary's labels or Urban
Dictionary's own — is a design question the owner has not settled, and guessing
at it in a stopgap that may be switched off next week is the wrong order.

Also out: scraping the site, any server-side fetch, Reddit / Hacker News /
Mastodon (#67), ranking by votes (§2 — the API returns none), and the News shelf
(#135, running beside this one).
