# Curation persistence, slice 1: default configuration and manual compositions

First delivery slice of [#196](https://github.com/razrfly/dictionary/issues/196)
and [#201](https://github.com/razrfly/dictionary/issues/201) under
[#193](https://github.com/razrfly/dictionary/issues/193).

This slice is the durable path a **human** takes from a stable scope to a published
composition, with no model:

    provision composition → manual version → presentation review → explicit publication

The slice also adds the configuration and profile identities that path is frozen against.
It is not the whole of #196 or #201. Runs, candidates, ballots, round responses,
co-proposers, leases, schedulers, budgets and public history are later slices, listed
under [Deferred](#deferred).

## Ownership

| Owner | Owns | This slice |
|---|---|---|
| #196 / #201 (this slice) | Configuration identities and versions, profile identities and versions, rosters, compositions, their versions, items, reviews and publication receipts | Creates them |
| #194 / PR #205 | Pages, paths, page memberships, On bodies, classification, page publication and indexability, **and the page ↔ composition binding table** | Untouched. The binding migration follows this one, per #205's recorded contract (`page_composition_bindings.composition_id` → `editorial_compositions.id`; the language must equal the page locale; the scope must be compatible). |
| #190 | Bot claim writes | None are made here. An item may reference an assertion revision only if it is already current, active and publicly visible (`Claims.visible/2`). |
| #195 / #197 | Model runtime and panel execution | Absent. A configuration version is **manual-only** until a later migration adds a validated model configuration. |
| #203 / #204 | History projection and the method page | Absent. The records here are what #203 will project. |

## Reconciliations with the #196 draft

The draft table in #196 assumes a model exists. Taking it as written would force this
slice to fabricate that model, which the task forbids. These are the deliberate
differences:

1. **No `local_model_configs` table, and no `local_model_config_id` column.** A
   configuration version with no model is *manual-only*. Panel readiness is always
   `false`, and `resolve_default(purpose: :panel)` answers `{:unavailable, :panel_not_available}`.
   The migration that adds a real, validated model configuration adds the column and
   the panel check. No digest is invented to satisfy a foreign key.
2. **Profiles exist as identities, not dossiers.** The five inspired-by identities are
   seeded as `proposed`, with no version, no bot actor and no subject entity. A profile
   becomes `admitted` only through `Profiles.admit/4`: a human reviewer, a version whose
   dossier cites sources, deceased-status evidence and a reason. The database refuses an
   `admitted` row without these. No version is seeded, because no dossier has been
   reviewed; nothing is quoted or asserted about the five writers.
3. **The global-default version 1 has an empty roster.** It carries the Bierce-first
   lead policy and the three-highlight limit, which is all manual composition needs.
   It references no profile versions, because none exist to reference. The five-member,
   4/5, two-round roster is a later version, activated once admitted profile versions
   and a model configuration exist.
4. **Seeding does not activate anything.** `mix dd.curation.seed` creates the
   configuration identity and version 1 in state `draft`, with no current version, so
   the default resolves as `{:unavailable, :no_active_version}` until an operator runs
   `Configurations.activate/4`. That is an audited human action with a receipt. A seed
   or a migration never promotes a configuration, a profile or a composition.
5. **Composition freshness and refresh columns are omitted.** These are
   `last_completed_at`, `refresh_after`, `next_retry_at`, the refresh generation and the
   desired input fingerprint. They are #198's, and nothing in a manual path writes them.
   Each composition's clocks here are its own receipts: version, review and publication
   timestamps.
6. **`origin` is `manual` only**, and there is no `originating_run_id` until runs exist.
   A manual version never gets a run, participant, ballot or nomination.
7. **The catalog-work reference form.** A work shown from a committed catalog manifest,
   such as `wikidata-famous-v1`, has no source-record revision row. The item stores the
   manifest name, checksum and row identity. This is the exact committed revision; no
   content revision is invented. A work with a real source-record revision references
   it instead.

## Invariants → constraint → test

The migration is `20260926233642_create_curation_foundation`, and the services live under
`DevilsDictionary.Curation`. Test modules are under `test/devils_dictionary/curation/`:
`ConfigurationsTest` (C), `CompositionsTest` (K), `PublicationsTest` (R) and
`PublicationRaceTest`. The race module is unboxed and runs on committed connections.

**How the tests reach COMMIT.** A sandboxed test never commits, so the deferred
triggers would never fire there. There are two answers:

* sandboxed tests end their writes with `settle!/0` (`SET CONSTRAINTS ALL IMMEDIATE`,
  then `ALL DEFERRED`), and assert refusals with `refused/1`, which does the same inside
  a savepoint. No constraint in the schema is `DEFERRABLE INITIALLY IMMEDIATE`, so this
  restores the initial state exactly;
* `PublicationRaceTest` repeats every deferred check at a real COMMIT, and runs the
  races on separate connections.

### Configurations and profiles (#201)

| # | Invariant | Enforced by | Test |
|---|---|---|---|
| C1 | Only `system` ownership exists; at most one **enabled** global default | check `ownership_kind = 'system'`; partial unique index on `role` where `role = 'global_default' AND state = 'enabled'`; `activate/4` refuses `:another_default_enabled` | "only system ownership exists and one global default is enabled" |
| C2 | A current version belongs to its configuration | composite FK `(current_version_id, id)` → `curation_configuration_versions (id, configuration_id)` | "a pointer to another configuration's version is refused" |
| C3 | The pointer and the state move only with a receipt, and each receipt continues the last | append-only `curation_configuration_activations` (`activate` or `disable`); deferred trigger: pointer and state equal the latest receipt's, the latest receipt's `previous_version_id` equals the one before it, and a configuration with no receipt is a draft with no pointer | "a pointer moved without a receipt fails at commit"; "every deferred check refuses at a real COMMIT" |
| C4 | Versions and rosters are immutable; a roster is fixed at creation | update/delete triggers; `roster_hash` recomputed from the seats at commit | "versions and rosters cannot be edited, removed or extended" |
| C5 | A seat's profile version belongs to its profile; one slot and one profile per version; weight 1; only an admitted version | composite FK `(profile_version_id, profile_id)`; unique `(version, profile)` and `(version, slot)`; check `voting_weight = 1`; `create_version/3` refuses `:profile_not_admitted` | "a seat's profile version is its profile's…"; "a roster seat must be an admitted profile's admitted version" |
| C6 | An admitted profile has one admitted version citing sources and deceased-status evidence, a bot principal, a human reviewer, a time and a reason | check on `curator_profiles`; admission trigger (reviewer `user` actor, `bot` actor, non-empty refs, a new version needs a new admission); `Profiles.admit/4` | "needs a reviewer, a sourced version with deceased-status evidence, and a bot principal" |
| C7 | Default resolution is server-side and default-only; missing, draft, disabled, unready and panel are explicit | `Configurations.resolve_default/1`, which takes no configuration argument | "answers the default or an explicit unavailable, never another configuration"; "a panel is never available, and a version this build cannot run is unready" |
| C8 | Activation is a reviewer's, idempotent, checks the pointer the caller saw, and publishes nothing | `activate/4` and `disable/3`: reviewer role rechecked under the account row lock, configuration row lock, `:expected`, idempotency replay; human-actor trigger on receipts | "activation is a reviewer's audited, idempotent act and publishes nothing"; "a revoked reviewer is refused…"; `Dd.Curation.SeedTest` |

### Compositions (#196)

| # | Invariant | Enforced by | Test |
|---|---|---|---|
| K1 | Identity is `(scope_kind, scope_signature, language, configuration)`; two configurations keep independent histories, pointers and clocks | partial unique index where `state = 'active'`; per-composition version numbers, parents and receipts; `provision/3` idempotent under an advisory lock | "the identity is (kind, signature, language, configuration)…"; "two configurations over one scope keep independent histories, pointers and clocks"; "two provisions of one scope make one composition" (unboxed) |
| K2 | The signature is the memberships', never a spelling, and every scope has a receipt | deferred trigger: the signature equals `sha256` of the sorted members and the latest scope-change receipt, and receipts chain; `provision/3` takes lexeme ids | "a scope change is explicit and audited; a signature that does not match fails at commit" |
| K3 | Overlapping or split scopes are reconciled, not guessed; a lexeme scope has one member | `provision/3` refuses `{:overlapping_scope, ids}`; `change_scope/4` audited; deferred trigger counts members; memberships `ON DELETE RESTRICT` | "provisioning takes registry ids, refuses overlap and a mixed language" |
| K4 | A version's configuration version is its configuration's; a parent is from its composition; made only against the current scope of an active composition | composite FKs; insert trigger on versions; `create_version/3` requires an enabled configuration and `:expected_parent` | "cross-configuration, cross-composition and cross-object links are refused"; "two authors cannot both write the next version"; "a draft or disabled configuration has no compositions made under it" |
| K5 | Versions and items are immutable; an arrangement is fixed at creation | triggers; `arrangement_hash` (length-prefixed fields) recomputed from the items at commit | "a version cannot be edited, removed or have items added" |
| K6 | At most one lead and three highlights; the lead is a content item at position 1 | checks; unique `(version, role, position)`; the configuration version's `max_highlights` | "a fourth highlight or a second lead cannot be stored" |
| K7 | An exact revision belongs to its item's object, and is the current, active one when the version is made | composite FKs `(content_revision_id, item_object_id)` and `(sense_revision_id, item_object_id)`; `Eligibility` (superseded, withdrawn, words hash, catalog checksum and row) | "exact references are checked against the registry when the version is made" |
| K8 | Exactly one intended meaning, on the scope | insert trigger (one of sense revision or lexeme); `Eligibility` (`:meaning_off_scope`) | "exact references are checked…" |
| K9 | Manual versions have manual origin, a reason, a human author, no run and no model note | checks `origin = 'manual'` and `selection_origin = 'manual'`; human-actor trigger on `created_by_actor_id`; notes are the author's | "a version is manual, human, reasoned, exact, and invents no history" |
| K10 | Bierce first | `Curation.LeadRule` at creation, review, publication and read | "an applicable Bierce entry leads, and a version without it is refused"; "where Bierce has no entry, a person may choose a page definition, or none" |

### Review and publication (#196)

| # | Invariant | Enforced by | Test |
|---|---|---|---|
| R1 | Only reviewers decide; decisions are append-only and idempotent; an acceptance is of the version's own fingerprint | human-reviewer trigger; update/delete triggers; unique `idempotency_key`; acceptance trigger; `Reviews.decide/4` rechecks the role under lock and refuses a version that no longer stands | "a bot or a non-reviewer cannot review"; "decisions are append-only and idempotent"; "an acceptance is refused once the version no longer stands" |
| R2 | Approval is not publication, and not a claim or page decision | separate tables and services | "approval publishes nothing and accepts no claim or page" |
| R3 | The pointer moves only with a receipt, which names the **latest** review of that version, an acceptance of the published fingerprint | composite FKs on receipts; receipt trigger; deferred trigger (pointer = latest receipt) | "the database refuses a pointer without a receipt, and a receipt without the latest acceptance"; "every deferred check refuses at a real COMMIT" |
| R4 | Publication is atomic, checks the expected pointer, scope, configuration version and fingerprint, and is idempotent | `Publications.publish/3` in one transaction | "needs an accepted review, then writes a receipt…"; "is idempotent, checks the expected pointer…"; "stale fingerprints, a withdrawn approval and a changed configuration refuse" |
| R5 | Concurrent publications never overwrite each other, even past the service | row lock and expected pointer in the service; in the database, each receipt must continue the one before it, so the second COMMIT from one pointer fails | "two reviewers publishing from the same pointer: exactly one wins…"; "writers that skip the service's lock still cannot both commit from one pointer" (both unboxed) |
| R6 | Read time withholds and never substitutes | `Published.current/1`: a version-level problem withholds all of it (retired, configuration changed, scope changed, approval withdrawn); an item-level one withholds that item with its reason; a later Bierce entry withholds a fallback lead | "answers the published arrangement and nothing else"; "withholds an ineligible item and never substitutes another"; "withholds the whole version when its approval, configuration or scope moves"; "a scope change withholds…"; "a Bierce entry that appears later withholds a fallback lead…"; "withdrawal is its own receipt…" |
| R7 | Source deletion is never blocked; nothing prohibited is kept | every source reference `ON DELETE SET NULL (column)`, including the item's object; the item guard permits only that nulling; items hold ids, hashes and locators | "a deleted source revision tombstones the item, and nothing prohibited is kept"; "an item's references can be nulled by a deletion, and never repointed" |

### Changed while implementing

* **Disabling is a receipt too.** `curation_configuration_activations.action` is
  `activate` or `disable`, and the commit check compares the state as well as the
  pointer. A configuration's states are `draft`, `enabled` and `disabled`; retirement
  is left for later.
* **Receipts chain.** A receipt's `previous_*` must equal the one before it. This is what
  makes a race fail in the database, not only in the service.
* **An item's object reference nulls on delete.** It is nullable only for a catalog
  work, which may have no registry object.
* **A claim reference must be publicly visible.** It must be current, active and
  visible under `Claims.visible(:public)`. The earlier wording, "accepted", would have
  hidden every imported claim, which has no review.
* **A lexeme is not deleted from under a scope** (memberships and `meaning_lexeme_id`
  are `RESTRICT`). Lexemes hold no source text, so R7 does not apply.

### Not written by this slice

No `curation_runs`, participants, candidates, ballots, nominations, attempts or round
responses; no `local_model_configs`; no page bindings. No `assertions`,
`assertion_revisions` or `assertion_reviews` row is written by any service here, which
a test asserts.

## Deferred

These are later scoped slices, each owned by its issue:

- **#196 / #197:** runs, participants, candidates, proposals, ballots, round responses,
  nominations and attempts. Five admitted profiles, weight 1, fixed 4/5, two rounds,
  ten normal generations plus at most one repair; a missing response is never an
  abstain ballot.
- **#195:** `local_model_configs`, a real validated model, and panel-mode configuration
  versions.
- **#198:** refresh admission, freshness clocks, leases and the one global inference
  budget.
- **#194:** the page ↔ composition binding, and the ADR 0004 default/alternate wording
  amendment.
- **#156 Phase 2:** mapping `Published.current/1` onto the Phase 1 view model. PR #202
  is not merged, so this slice does not depend on it. Production selection stays
  disabled; no page reads compositions yet.
- **#203 / #204:** the history projection, profile pages and the method page.
- Later stages of #201: domain defaults and personal views.

## Operating notes

- `mix dd.curation.seed` is idempotent. It creates the `global-default` configuration
  (draft, no current version) and the five proposed profiles. It activates nothing and
  approves nothing.
- Registry object ids exist only in the database, so curation state is **restored, not
  regenerated**, like routing state (#205's recovery procedure).
