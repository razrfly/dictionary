# Citation infrastructure (#270)

Delivery A implements [#270 revision 5](https://github.com/razrfly/dictionary/issues/270), following #273's reviewed merge `9bfa2440549fadd5e749dc9218fcad866b9e0471`. The tracker is [#271](https://github.com/razrfly/dictionary/issues/271). This document grants no permission to deploy, migrate a working database, enable the editor, call a provider/model, or capture a working installation.

Layer 0 stays the source record. Layer 1 stores choices, exact references, original chooser evidence and later owner actions. Content, sense quotations, sense definitions, catalog works, accepted exemplars, public linked claims and every persistent discovery shelf share the composition/review/publication path. `Candidates.for_page/1` is the unbounded owner selection interface. The model receives a bounded v3 packet; its seven quotas total twelve and unused capacity flows down. Shelf focus rotates deterministically and can be requested for one generation. Existing v1/v2 packets remain readable. There is no new scheduler, panel, consensus or automatic publication.

## Read-only inspection

Use the pinned, compatible code and intended database explicitly. Unset `PHX_SERVER`; `DD_NO_OBAN=1` prevents jobs in the inspecting process. These commands do not request discovery or invoke a model:

```sh
DD_NO_OBAN=1 mix dd.curation.citations shelf --slug love
DD_NO_OBAN=1 mix dd.curation.citations packet --slug love --shelf news
DD_NO_OBAN=1 mix dd.curation.citations sweep --dry-run
DD_NO_OBAN=1 mix dd.curation.citations receipt --slug love --version 2
```

Only `sweep --dry-run` is intended before the citation migration. It imports no payload and binds no legacy row. It reports total candidate revision actions, whole-record deletions, the next bounded revision and record actions, cache result pruning and empty-record projections. Counts describe the read snapshot; actual cleanup locks and rechecks each canonical identity. A cited revision with unknown legacy retention is conservatively due. A unique live legacy observation protects only its exact revision, including beyond the binding batch. Already projected/durable rows consume no payload slot.

The dry run is not approval. Sitting 3's owner request must name the exact deployment SHA and the deletion/redaction counts. Follow #271's sitting sequence: #270 is deployed before the single editor activation. The serving checkout must never be moved by an inspection or build.

## Data and reader contract

- Discovery records the exact revision at successful completion, with captured retention seconds/policy and timestamps. Legacy binding requires exactly one metadata/payload match; neither latest revision nor record fetch time substitutes for it.
- `curation_shelf_citations` keeps immutable observation identity, checksum, expiry and policy classification. Only its live record/revision FKs may become NULL. A newer observation never revives an older choice.
- `curation_item_bases` preserves the original actor/run's offered-field digest, frozen claim representation and known reference/date identity. Take/Edit/Keep/copy attribute the owner separately. Legacy evidence remains explicitly unknown.
- Shelf text is metadata only. Quotes on shelf/claim candidates are refused. Model reasons that copy expiring fields become policy/digest markers; new owner annotations are validated across the complete source/destination union. Fixed dismissal/withdrawal actions allow no new unverified text after expiry.
- The public `/on/:slug/receipt/:version` is read-only, `noindex` and available only for published versions. Tiles link to their receipt rows. Dates distinguish the selected content date, source edition, fetch, choice and publication. Item and version-level visibility agree with the public reader. Expiry hides prohibited values immediately; the receipt separately reports whether physical redaction/deletion is confirmed.
- Cleanup uses per-revision deadlines and current stricter caps, locks canonical source/digest then record/revision, and projects protected payloads to the provider-specific retained set. Native revisions are preserved. Revision tombstones retain the original checksum while freeing the unredacted lookup key. A permitted identical refetch reuses the record and creates a new revision.

## Additive migration and rollback fence (L17.3)

There is one new migration, `20261028041101_create_curation_citations`. It accepts #264's old writers and leaves old item hashes unchanged. Sitting 3 applies it while the reviewed #264 code still serves, then verifies the old readers and NULL-column discovery writes before deployment. Deployment remains a fast-forward to the named, independently reviewed merge; merged is not deployed. This build performs none of those live steps.

Before proposing any code revert, inspect persisted state read-only:

```sql
SELECT curation_citations_rollback_eligible();
```

A code revert is eligible only before **all** of these states: citation/basis rows, new item kinds or citation references, stored shelf focus, a keyed refresh-window configuration, captured run policy, revision retention metadata, redacted record keys or revision tombstones. An apparently empty citation table alone is insufficient. If any state exists, roll forward with a compatible fix and a separately reviewed pinned SHA. Do not switch old code onto that state. Keep the additive migration for any permitted pre-use code revert; a separately approved migration down independently executes the same persisted-state fence. No live rollback is tested or authorized here. `dd.bundle/2` artifacts continue to require compatible restore code even if the working database itself passes the fence.

## Recovery bundles

Every new capture is `dd.bundle/2`. The custom dump excludes the disposable discovery cache/ledger and both source-record tables. Two binary COPY files, produced under the same exported snapshot, carry projected source records/revisions. Non-discovery revisions and their parent records survive independently of discovery-cache eligibility; durable FK references are preserved. All expiring discovery fields are removed even if an observation is still live. Projected state hashes/counts are compared after restoring pre-data, data, the COPY files, then post-data. Verification requires the projected roles and metadata. An old interrupted capture cannot be resumed into a v2-labelled bundle. Genuine v1 bundles remain readable/restorable; historical bundles are not cleaned or re-certified.

Fixture recovery tests create disposable databases and use stub volume probes. They are not a working-installation capture or a full restore drill.

## Daily reassessment

`bind --refresh-window 24h|48h|7d` creates a keyed configuration version. An unkeyed v1 reads as 48 hours; no existing version is rewritten. Every completion uses its claim's configuration version. Failed/offline/deferred work does not advance assessment time. Only proposed/abstained/no-change are editor assessments; unchanged/needs-editor retain the model-free wording. A qualifying visit drives reassessment; owner publication remains explicit.

## Delivery evidence

Run the complete precommit on the exact published tree with an isolated test partition, `MIX_ENV=test`, `DD_NO_OBAN=1`, `PHX_SERVER` unset and no HTTP server. Record its test count and exact head in the PR. The contract's test matrix and fixture demonstrations are approval gates; passing an early targeted subset is not delivery acceptance. Independent review must cover the final exact head, and every required finding must be fixed or explicitly resolved. Live acceptance and issue closures remain #271's later owner-authorized sittings.
