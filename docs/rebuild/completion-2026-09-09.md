# Issue #74: completion verification, 9 September 2026

This pass implements the gaps found by independent review. It does not migrate the original database. The original `devils_dictionary_dev` remains intact; `devils_dictionary_v2` is the working corpus, and `devils_dictionary_74_verify` is an independent clean rebuild.

## Changes

- Public connection detail and historical revision URLs obey the same rejection/withdrawal policy as both endpoint lists. An old active revision cannot bypass a rejected current revision.
- The authenticated composer searches words, entities, source-specific senses and published content. It persists optional context, rationale, a selected evidence revision and its locator atomically. A locator without a citation fails without creating a claim.
- The reviewer form records an accountable actor, decision, reason and the exact endpoint revisions displayed. It rejects stale assertion/context snapshots. Reviewer permission is read from the database for each decision, including on an already-open LiveView after revocation. Self-registration cannot grant that role.
- Authored definitions link to their actual person identity. The connected acceptance test clicks that link rather than opening the author's URL independently.
- Lexical identity deduplication no longer discards other records’ forms and pronunciations. Pronunciations have a canonical set representation. Identical source snapshots reuse their existing sense identities without introducing false ambiguity; changed positional sources still go through meaning reconciliation.
- The full Wiktionary index retains every etymology observation before deduplicating word identities. Parallel parsing yields results in source order; forms and topical categories are combined, and an attested headword takes precedence over an inflection-only flag. Etymology display selects a stable source-native key, with same-owner corrections supported. Source-key tie breaks use bytewise collation explicitly, independent of the database locale.
- M2 now compares semantic fingerprints of the entire derived state and revision histories around each source replay. Matching counts alone cannot pass. Bookkeeping timestamps and run IDs are excluded; content, lifecycle, relationships and evidence remain covered.
- `mix dd.verify.rebuild` compares independent new-schema databases using source/lexical identities rather than numeric primary keys. It includes exact text, typed entity details, names/forms, identifiers, relationships, source attestations and scope reasons. It preserves multiplicity and fails on changed text even when counts match. This is complementary to same-database M2, which also checks history churn.
- Resolver ties use the bytewise lexical key, not allocation order. The full comparison isolated one Johnson `gainst → against` claim that otherwise chose a different part of speech in each database. A regression creates the candidates in opposite orders; the existing source-POS/case/POS-priority policy remains explicit and heuristic when the source omits POS.
- Definition-to-word lookup uses separate bounded word and sense queries. The former outer join scanned the full lexicon and could omit a direct word target when its sense was requested too. Relationship pagination has current-row endpoint/id indexes matching its cursor order.
- P1 measures complete high-degree word **and entity** page builders. P2 selects high-degree subjects in both directions. Each subject is warmed three times before five measured rounds; results identify the population and remain warm-cache measurements.
- A source reverting from A to B and back to A cites the current content hash’s observation, not the largest revision ID.
- Replay preserves archived source observation dates; replaying is not a fresh API fetch.
- A reset cannot use `--force` to bypass a mismatch between the named and configured database. Rebuild stops on the first failed stage, including bad input checksums.

## Conflicting source observations

The first full semantic M2 run found four Wikipedia articles whose different lookup probes contained different extracts. Replaying those records alternated the selected text and created eight extra revisions. It also found that Wikipedia and Wikidata overwrote shared display metadata according to import order.

The fix explicitly selects a representative observation: full Wikipedia article metadata precedes Wikidata display hints, which precede disambiguation candidates. The source's external record key breaks ties deterministically. This is a display selection rule, **not a claim about which conflicting observation is newest or truest**. Per-field projection owners are retained. Corrections from the selected owner still update the display; missing fields from that owner are removed. All underlying source observations remain archived and attributable.

Entity merging retains every observation within a batch, including fields absent from the preferred probe. It writes one observation per entity per SQL round so the same field-ownership rules apply within and across batch boundaries. A regression reproduces a missing thumbnail under a combined batch and checks separate-batch replay.

Published content likewise chooses a stable external record key among supporting observations rather than alternating across batches. M1 re-derives the expected selected publication from the archived record, verifies its exact current text, and separately reports alternate observations. A corruption test proves this is not an exemption from content validation.

## Reviewer setup

Reviewer is a privileged account flag, not a registration/profile field. In a trusted IEx session against the intended database:

```elixir
user = DevilsDictionary.Repo.get_by!(DevilsDictionary.Accounts.User, email: "reviewer@example.com")
user |> Ecto.Changeset.change(reviewer: true) |> DevilsDictionary.Repo.update!()
```

Use `reviewer: false` to revoke it. A fresh event rechecks that permission.

## Reproduction

Use a separately named database for verification. Never reset the original `devils_dictionary_dev`. This completion pass also recreated the explicitly disposable v2 corpus after fixing import defects, instead of transforming its old rows. Inputs must already be present and pass the checked-in manifest verification.

```sh
DD_DATABASE=devils_dictionary_74_verify mix dd.reset --database devils_dictionary_74_verify
DD_DATABASE=devils_dictionary_74_verify mix dd.rebuild
DD_DATABASE=devils_dictionary_74_verify mix dd.rebuild --scope emotions --from scope
DD_DATABASE=devils_dictionary_74_verify mix dd.rebuild --scope culture --from scope
DD_DATABASE=devils_dictionary_74_verify mix dd.verify.rebuild --baseline devils_dictionary_v2 --output /tmp/rebuild-comparison.json
mix dd.materialize --all
mix dd.resolve
mix dd.score --scope animals
mix dd.score --scope emotions
mix dd.score --scope culture
mix dd.health
mix precommit
```

Materialization re-emits lexical relation candidates into the staging queue. Run `mix dd.resolve` afterward, as the full rebuild pipeline does, before grading resolved/unresolved coverage. The independent semantic comparison is taken after this resolution step.

The baseline and rebuilt database must have the same scopes materialized and no concurrent corpus writes during comparison. Numeric object IDs may differ. Operational counters and acquisition timestamps are not semantic equivalence requirements. This comparator is for two clean **new-model** corpora; it does not claim equivalence to the retired MVP-0 schema.

## Scope boundaries

This closes an encyclopedia foundation, not public-deployment readiness. ConceptNet production ingestion, Artsy integration and broader operational hardening remain in #72/downstream work. The model's extension fixtures establish representability; they are not claims that those integrations are live. Source coverage gaps and heuristic links remain explicitly reported rather than promoted to certain facts.

## Verification results

The final `mix precommit` run passed **721 tests with zero failures**. The new index regression exercises real commits and multiple etymology records for one lexeme; the batch regression also proves deterministic etymology selection and selected-source corrections.

The current branch is ready for code review, but the completion gate remains open. Final evidence records an exact independent rebuild comparison (`identical: true`), semantic replay equality for all six sources, and passing scorecards: animals **44/44**, emotions **43/43**, culture **42/42**, each with zero pending rows. Warm-cache animals measurements are P1 **44.191 ms** p95, P2 **0.418 ms** p95, and X2 **69 ms** p95. O2 reports cumulative recorded runs, not a fresh API acquisition benchmark. Culture's empty linkability population is reported as not applicable, not counted as a pass.

Remaining acceptance work: complete the authenticated contribution/review browser workflow, confirm final CLI/browser health agreement, reconcile the provenance-stamp diagnostic below, and clean up the disposable verification database. Browser login now succeeds after correcting authentication form buttons to submit; the regression is included in the 721 tests. Desktop/mobile read-page screenshots are recorded. Earlier failed comparisons remain diagnostic evidence, not successful validation.

The final corpus contains 1,541,668 lexemes, 250,305 source-specific senses, 92,952 entities and 108,475 content items, with 1,491,146 assertions and 900,843 forms. The latest integrity diagnostic found no missing current revisions, unstamped object outputs or missing source snapshots, but reports **117,363 claim outputs with a null last_seen_run_id**. This differs from the earlier zero-count observation and still needs reconciliation; passing scorecards do not resolve that discrepancy. Assertion storage, including the new pagination indexes, is 950,362,112 bytes versus the original relation table’s 765,050,880 bytes: **1.24×**, below the 2× budget. The original database remains intact.
