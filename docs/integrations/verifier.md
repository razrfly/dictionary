# The quotation verifier (#158 build 5)

Build 5 checks a stored quotation against sources that can confirm or contradict
who said it, and writes what it finds as `assertion_evidence` on the claim. This
file is the spike the issue asked for — "the spike decides it with numbers" — and
then the record of what was built.

## Spike, 2026-09-24

Ceiling: **60 requests**. Every request keyless, identifying User-Agent, 300 ms
apart or slower. The five test lines are #158's.

| # | requests | what was asked | what came back | running total |
|---|---|---|---|---|
| S1 | 2 | Wikidata SPARQL: works with `P50` = Voltaire (Q9068) / Kurt Vonnegut (Q49074) **and** a Gutenberg ebook id (`P2034`) | 200 / 200 (4.6 s, 0.6 s). Voltaire **4**: *Zadig* 18972, **Candide 19942**, *The Huron* 4651, *Micromegas* 30123. Vonnegut **2**: *2 B R 0 2 B* 21279, *Tomorrow and Tomorrow and Tomorrow* 30240 | **2 / 60** |
| S2 | 1 | `gutenberg.org/cache/epub/19942/pg19942.txt` | 200, 229,720 bytes, 0.96 s. "we must cultivate our garden" at **line 4121**; after fingerprint normalisation (ADR 0003) the check is a substring test on the whole text | **3 / 60** |
| S3 | 3 | en.wikisource `list=search` for three test lines, exact phrase | "we must cultivate our garden": **1** hit, a 1899 *Popular Science Monthly* page quoting it (Wikisource's own *Candide* is another translation). "I disapprove of what you say": 1, an unrelated 2007 speech. "so it goes": **244**, none relevant | **6 / 60** |
| S4 | 2 | Internet Archive `advancedsearch` `text:"…"` | "we must cultivate our garden": 5, of which one Candide scan **with no creator metadata**; the rest a 1983 book titled after the line, an ERIC report, a mixtape. "so it goes": **946**, noise | **8 / 60** |
| S5 | 1 | Wikiquote *Misquotations*, Parsoid | 200, 347,700 bytes. 150 rows: 48 *Misquoted or misattributed*, 9 *Commonly misquoted*, 93 *Unsourced*. Of the five lines **only "I disapprove…"** (to Evelyn Beatrice Hall) | **9 / 60** |

Also read from build 4a's fixtures, no requests: the authors' **own** pages.
Voltaire's register has "No snowflake in an avalanche" (to Stanisław Jerzy Lec);
Vonnegut's has "Wear sunscreen" (to Mary Schmich). Voltaire's page renders the
*Candide* line as **"Let us cultivate our garden."** under a *1750s* heading —
a different translation from #158's "We must…", and a different fingerprint by
ADR 0003's own test. "So it goes" is not a line on Vonnegut's page: it occurs
**inside** three longer passages cited to *Slaughterhouse-Five* (1969).

## What the numbers decide

**Checkers built** — each reaches its evidence by an identifier, never by
matching a name:

| checker | route | what it can say |
|---|---|---|
| `gutenberg` | the credited author's QID → Wikidata works with `P50` = that QID and a `P2034` ebook id → `pg<id>.txt`, cached as a source record | **supports**: the line is in a text Wikidata says this person wrote, at line *N* |
| `wikiquote` (author page) | the credited author's QID → its `enwikiquote` sitelink → the author's own page, parsed by build 4a's parser | **supports**: the line (or a cited passage containing it) is on the author's page under a cited work or year. **contradicts**: it is in the page's *Misattributed* / *Disputed* / *Unsourced* register |
| `wikiquote` (*Misquotations*) | one page, the same parser, shared by every line | **agrees with a misattribution** already held. Never against a credit: a row names no one by identifier, and its note usually names the true author |

**Not built, by measurement:**

- **Wikisource**: 0 of 3 hits attributable to the credited author; the one
  *Candide* on Wikisource is another translation. A hit would need its page's
  Wikidata item to have `P50` = the author before it could count, and on this
  set nothing would have passed.
- **Internet Archive** full text: items carry no identifiers that tie a text
  to an author; the only *Candide* hit had no creator at all. Counting a hit
  would mean matching a creator *name*, which the one rule forbids.
- **Quote Investigator**: `active: false` until the permission email is
  answered (#158 open question 3). Not called.
- **Google Books**: no key in `.env`. The row exists, inactive; the check is
  written against the key when it arrives, and the acceptance box is
  explicitly "without a Google Books key".

**The run record: a new table, `verification_runs`.** `discovery_request_attempts.run_id`
is `NOT NULL` and references `discovery_runs`, so no request can be budgeted or
ledgered outside a discovery run today; a discovery run needs a mapping and a
word-page target, and a verification's subject is a quotation or an author.
Reusing it would mean a synthetic mapping per author. `import_runs` is an
absorb's, and has no ledger at all. So: `verification_runs` (subject, status,
times, request count, error, refresh clock), and
`discovery_request_attempts.verification_run_id` beside a now-nullable `run_id`,
with a check that exactly one is set — the budget and the operator's counts stay
one ledger.

**Cost shape.** Per author, not per line: the SPARQL answer, the author's page
and each Gutenberg text are one request each and cached as source records for
the refresh window; the *Misquotations* page is one request per window for
everything. A line's marginal cost after its author's first run is **zero
requests**. Voltaire: 1 sitelink + 1 page + 1 SPARQL + 4 texts = 7 requests for
every Voltaire line held.

## The badge rule, as built

From #158's wireframe, over the checks' evidence plus the claims already held:

- **Verified**: at least two independent sources agree (distinct sources with a
  cited claim or a `supports` check), one of them a primary text, and nothing
  contradicts.
- **Plausible**: at least one cited claim and nothing contradicts.
- **Disputed**: something contradicts, and a cited claim exists (the register
  names who did say it, or another source cites it).
- **Apocryphal**: something contradicts, and there is no cited claim at all.

The #65 score is recorded beside it, from #65's own signal table. The badge is
decided by the agreements rather than by #65's thresholds; where they disagree,
that is recorded (see the PR).

## As built

| piece | where |
|---|---|
| the run record | `verification_runs` (migration `20260924005117`), `Quotations.VerificationRun`; `discovery_request_attempts.verification_run_id` beside a nullable `run_id`, exactly one set |
| spending | `Verifier.Fetch.get/4` → `Budget.claim_shared/4` with `{:verification, id}`; a `429`, a `5xx` or a refused claim defers the whole pass, and a `429`/`5xx` sets the source's `discovery_retry_after` (`Budget.defer_source/3`) so the discovery provider on the same host waits too |
| switches | an inactive source is never called; its check is skipped (`Fetch.active?/1`); a source under `discovery_retry_after` defers the pass |
| keeping | `Verifier.Fetch.cached/5`: each answer is a source record under its checker's source — `wikidata` (`enwikiquote-sitelink:Q…`, `gutenberg-works:Q…`), `wikiquote` (`verifier-page:<title>`), `gutenberg` (`pg<id>`, kept ten years) |
| checks | `Verifier.Checks`: `author_page/3`, `misquotations/2` (every row register), `gutenberg_texts/3`; `match_page/3`, `match_texts/2` (fingerprint equality, or containment for lines of three words or more) |
| verdict | `Quotations.Badge.compute/2`: the badge by agreements, the #65 score by its signal table |
| writes | `Verifier.verify_author/2`: evidence on each credit's new `method: "verifier"` revision (only when the findings changed; never over a review), register agreement as `:supports` on a `misattributed_to`, the badge on `content_items.metadata["provenance"]` — the item's, from every claim on the line plus the checks each person's pass left, so passes agree whichever ran last. An exception fails that person's pass (`error_code: "exception"`) and not the batch |
| clock | `Verifier.due/1`, `VerifyWorker` at `:07` and `:37` past each hour; 30 days after a success, a day after a failure, the retry time after a deferral |
| reader | `Result.provenance` (read at display time), the quote card's badge: *Verified* green, *Disputed* amber, *Apocryphal* rose, *Plausible* neutral |
| operator | `/ops/discovery` → *Quotation verifier*: passes by outcome, badges, one row per checker with its budget and why it is off |

Test case, from fixtures (`test/devils_dictionary/quotations/verifier_test.exs`):
"I disapprove…", "No snowflake…" and "Wear sunscreen" **disputed**; "We must
cultivate our garden" **verified** (the fixture provider's citation and
*Candide*, Gutenberg #19942, line 4121); "So it goes" **plausible** (two
sources, no primary text) — without a Google Books key. A first pass for both
authors costs 13 requests (Wikidata 4, Wikiquote 3, Gutenberg 6); a second,
after the clock runs out, costs none and writes nothing.

Spike ledger total: 9 requests for S1–S5, plus 1 for the *Misquotations*
fixture captured with `mix dd.fixtures.capture` (S6): **10 / 60**.
