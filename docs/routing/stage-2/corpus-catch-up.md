# Corpus catch-up — a proposal for the owner

**Status:** a proposal, 27 September 2026, for [routing issue #194](https://github.com/razrfly/dictionary/issues/194). **Nothing has been applied.** The development corpus (`devils_dictionary_v2`) and the accepted recovery baseline are unchanged. Everything below was measured on isolated copies in the scratch cluster ([recovery repair report](recovery-repair.md)).

## Why a decision is needed

Recovery is a restore followed by a re-projection from the copy's own source records. On a copy of the development corpus, today's code now re-projects every provider to completion:

- identities are kept: no object minted or removed, no object id or external identifier value changed;
- routing history and every resolution are kept;
- curation approvals are kept, and the published composition stands on the same content revisions.

The result still differs from the corpus. The corpus was materialized by older code, from 5 September onwards, and several materializers have changed since. Re-materializing unchanged records with today's code writes rows and fields the corpus never had. So a restored copy cannot yet re-project to equality with its source. The recovery exit — "only explicitly permitted bookkeeping differs against the accepted baseline" — cannot be met until either the corpus catches up or the owner decides otherwise.

Widening the bookkeeping exclusions to hide these differences is not an option. They are real content.

## What catching up changes — measured, complete

Measured row by row across every table the projected verification reported as different. The only columns left out are the projection's bookkeeping (`updated_at`, `materialized_at`, `last_seen_run_id`), exactly as `mix dd.routing.verify --projected` leaves them out. **Nothing is removed from any table.** Every other table is exact: `objects`, `lexemes`, senses, content, all six routing tables and all thirteen curation tables.

| Table | Before | After | Added | Changed | What changes |
|---|---:|---:|---:|---:|---|
| `entities` | 100,795 | 100,795 | 0 | 8,973 | metadata on 8,971; kind on 2,083 |
| `person_details` | 213 | 6,878 | 6,665 | 0 | details for existing people |
| `work_details` | 7,690 | 9,771 | 2,081 | 0 | details for entities that become works |
| `external_identifiers` | 104,576 | 104,589 | 13 | 8,770 | 13 new identifiers; 8,770 pinned to their record |
| `assertions` | 3,901,280 | 3,902,230 | 950 | 0 | Wikidata `instance_of` (949) and `subclass_of` (1) |
| `assertion_revisions` | 4,373,560 | 4,376,966 | 3,406 | 2,456 | 950 first revisions; one new revision each for 2,456 existing Wiktionary edges, superseding the old one |
| `source_assertion_outputs` | 3,823,923 | 3,824,873 | 950 | 0 | ownership of the 950 new assertions |
| `source_materialized_outputs` | 2,106,046 | 2,115,016 | 8,970 | 0 | `source_identity:wikidata:…` outputs |
| `pending_relations` | 163,537 | 163,537 | 0 | 388 | a `label` on waiting Wiktionary edges |
| `actors` | 18 | 19 | 1 | 0 | "wikidata (provider relationships)" |

Every assertion still has exactly one current revision. A superseded revision stays, `active`, as history.

### By cause

**1. Wikidata source identity (from 12 September).** The corpus's Wikidata entities predate the source-identity layer.
- 8,970 entities gain `metadata.source_identity_evidence`, and each gains a `source_identity:wikidata:Q…` materialized output.
- 8,770 Wikidata identifiers are pinned to the source-record revision that attests them. Each was unpinned (`null`). No value, object or status changes.

**2. Sharper kinds and detail rows.**
- 2,081 entities go from `concept` to `work`, each with a new `work_details` row: films, albums and other works the original build could only call concepts.
- 2 go from `concept` to `event`.
- 6,665 existing people gain a `person_details` row.
- 949 `instance_of` edges and 1 `subclass_of` edge are asserted from Wikidata.

**3. Creator identities projected for the first time (#164, from 23 September).** The creator-identity flow minted 201 people and organizations from Wikidata records that no materializer had ever read.
- Materializing those records fills the entities' display metadata: aliases on 71, Commons category on 75, Wikipedia title on 87, an image on 73, WordNet ids on 26, and a projection origin on all 201.
- It adds 13 Artsy artist identifiers (`artsy_artist_slug`, from P2042).
- It adds the actor that records provider relationships.

  The mint's own output on each record is kept. The first measurement found that re-materialization retired all 201, leaving one organization (DK) with no live output. That was a defect, now fixed (see the report).

**4. Wiktionary edge provenance.** 2,456 existing Wiktionary relation assertions gain exactly one new revision each. Subject, predicate and object are unchanged in every one.
- **Labels (#181, from 24 September).** "Every source edge keeps its label", such as a Thesaurus section's `instances`. 2,455 claims gain it. So do 388 waiting pending edges.
- **One attestation speaks for a claim (this repair).** Several records can attest one edge. Wiktionary's `cat/noun/1`, `/2` and `/3` all make *calico cat* a hyponym of *cat*, one citing the sense and another the Thesaurus page. The resolver used to take whichever attestation its chunk met first, so each full re-projection revised such a claim twice and ended where it started.
  - It now chooses by content: the first attesting record by external id, then the stated part of speech, the metadata and the method.
  - That is what the build kept for all but **one** claim: *down* → *downlike* (`derived`). Its provenance goes from `{}` to its first record's `{"sense": "Terms derived from the adjective, adverb, preposition, noun, or verb down"}`.
  - The attesting records are unchanged: each still owns the claim.

**5. Wikipedia images on 23 artworks.** All were set by the original build on 9 September.
- 13 differ only in attribution text (spaces become underscores) and 4 only in URL escaping.
- **6 now show a different image of the same work.** They are *Mona Lisa*, *Primavera*, *La maja desnuda*, *Springtime*, *The Dog* and *The Goldfinch*. For example, the *Mona Lisa*'s C2RMF natural-colour scan becomes the C2RMF retouched one.

No kind, identifier, route or approval depends on any of these images.

## It converges

On copies, the caught-up state is a fixed point of today's code. It was restored twice from a frozen snapshot and fully re-projected each time: replay, then `materialize --all --resolve` for all six providers. Every provider was identical under M2, `pending_relations` included, and exited 0. `mix dd.routing.verify --projected` against the caught-up baseline passed. Normal routing and curation operations passed on the same projected copies. See the [report](recovery-repair.md#stability).

## Options

**A. Catch the corpus up (recommended).** Apply the same re-projection to `devils_dictionary_v2`, deliberately, as a reviewed migration:
1. Quiesce the source and prove the window write-free. Snapshot it with `mix dd.snapshot`: that dump is the rollback point.
2. Restore the dump into a scratch copy and re-project the copy as the rehearsal did. Measure its delta against the dump. It must match this proposal, less anything the source gained after 13:29 UTC on 27 September. Any other difference is explained before going on.
3. Run `mix dd.materialize --source S --all --resolve` on the source for each of the six providers, in the same order, with `DD_NO_OBAN=1`. Replay is not needed: the records are already there.
4. Verify the source against that copy with `mix dd.routing.verify --projected`. Both were projected from the same snapshot, so they must agree on everything but bookkeeping. The rehearsal's own copies carry marked routing and curation fixtures, so they cannot serve as this reference.
5. The caught-up source becomes the accepted baseline. Snapshot it; from then on, a recovery re-projects to it exactly, as the stability runs show.

Reversal: restore the step-1 snapshot. The superseded assertion revisions stay as history in any case.

**B. Make today's materializers reproduce the old corpus.** Not recommended. It would freeze behaviour that later issues deliberately changed: source identity, kinds, creator identity and edge labels.

**C. Leave the corpus and accept these differences as permitted.** Not open. The audit forbids broadening the permitted differences beyond bookkeeping.

## Decisions for the owner

1. **Approve option A for `devils_dictionary_v2`**, or choose otherwise.
2. **The 6 artwork images.** Accept Wikipedia's current images, or hold them back. Holding them back needs a code change: an image the original build chose would have to outrank the page's current one.
3. **When and by whom.** The source must be quiet during the catch-up. At the time of measurement:
   - the development server on port 4007 was stopped at a terminal prompt;
   - another session's preview on port 4017 held connections to the source;
   - the source carried two migrations from an unmerged branch ([#195](https://github.com/razrfly/dictionary/issues/195), applied at 13:11 UTC). They added four empty tables that nothing in this proposal touches.

Nothing here is applied until the owner decides.
