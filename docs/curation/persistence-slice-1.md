# Curation persistence, slice 1: default configuration and manual compositions

First delivery slice of [#196](https://github.com/razrfly/dictionary/issues/196)
and [#201](https://github.com/razrfly/dictionary/issues/201) under
[#193](https://github.com/razrfly/dictionary/issues/193).

This slice adds the configuration and profile identities that curation is frozen
against. It also adds the durable records every published composition rests on:
exact-reference versions, their eligibility, and publication receipts with the
authority that authorized each one.

**Publication has two authorities, and only one exists yet.** See
[Publication authority](#publication-authority).

* **Routine curation is meant to publish on a panel decision.** The configured
  agent panel reaches consensus on a version, the version passes the evidence and
  policy checks, and the publication service publishes it. There is no
  per-selection human sign-off. That path needs genuine decision records from panel
  runs (#197), which do not exist, so it is **unavailable**. Nothing here fabricates
  a run, vote or decision to stand in for one.
* **The operator path is what this slice implements**, as an optional mechanism:

      provision composition → manual version → operator review → operator publication

  It is for manual compositions made before any model exists, and later for
  overrides, corrections and withdrawals. It is not the gate every selection must
  pass.

This is not the whole of #196 or #201. Runs, candidates, ballots, round responses,
co-proposers, leases, schedulers, budgets and public history are later slices, listed
under [Deferred](#deferred).

**PostgreSQL 15 or newer is required.** The item references use column-list
referential actions (`ON DELETE SET NULL (column)`), which arrived in 15. The
migration checks the server version first and stops with an explicit error on an
older one.

## Ownership

| Owner | Owns | This slice |
|---|---|---|
| #196 / #201 (this slice) | Configuration identities and versions, profile identities and versions, rosters, compositions, their versions, items, operator reviews and publication receipts | Creates them |
| #194 / PR #205 | Pages, paths, page memberships, On bodies, classification, page publication and indexability, **and the page ↔ composition binding table** | Untouched. The binding migration follows this one, per #205's recorded contract (`page_composition_bindings.composition_id` → `editorial_compositions.id`; the language must equal the page locale; the scope must be compatible). |
| #190 | Bot claim writes | None are made here. An item may reference an assertion revision only if it is already current, active and publicly visible (`Claims.visible/2`). |
| #195 / #197 | Model runtime, panel execution, **and the panel-decision publication authority** | Absent. A configuration version is **manual-only** until a later migration adds a validated model configuration. |
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
   Configuration administration stays a human act; that is a separate policy choice
   from per-selection publication.
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
   it instead. Either way the evidence must identify the selected object (K7).
8. **Publication authority is explicit and versioned.** The draft's receipt has a
   required `authorizing_review_id`, which would make a human review the only possible
   authority. Here every receipt names its `authority_kind`. Only `operator` is valid
   now, and the panel decision is the intended routine authority, added with #197.

## Publication authority

A publication receipt records **what authorized it** (`authority_kind`). The commit it
authorizes is the same for every authority (`Publications`): lock the composition, then
check the expected pointer, that the version still stands (scope, configuration version,
a clean evaluation to its own eligibility fingerprint), and the authority. Only then
does it write the receipt and move the pointer, in one transaction.

### `operator` (available)

A reviewer publishes a version whose **latest** operator review is an acceptance of its
fingerprint (`Publications.publish/3`), or withdraws a publication
(`Publications.withdraw/3`). The database refuses an operator receipt from anyone but a
human reviewer, one citing a review that is not the version's latest, or one that did
not accept, or one of another fingerprint. It is optional, and it is used for:

* manual compositions, before any model exists;
* overrides and corrections of panel output, once there is some;
* withdrawal at any time.

### `panel_decision` (intended routine path, not available)

A routine selection publishes because the configured panel decided on it, not because a
person signed it off. The database refuses this authority today
(`authority_kind IN ('operator')`, and the authority trigger), because the decision
records it needs do not exist. **The integration that adds it (#197, with #195's model
configuration) must implement all of the following. Nothing less authorizes a
publication:**

1. **A genuine decision record.** It is a finalized, immutable run result of the
   composition's own configuration **version**:
   - the actual participants are that version's roster (admitted profile versions,
     weight 1);
   - every ballot and per-round response status is recorded;
   - a missing response is a status, never an abstain or a support;
   - the selection trace is deterministic (`selection-v1`, #203), and support counts
     can be recomputed from the ballots;
   - the configured consensus (4/5 support) is met for the lead and each highlight.

   The composition version it selected carries `origin = 'panel'` and
   `originating_run_id`. Its items carry `selection_origin = 'panel_recommendation'`.
   Model notes are written by the profile's `bot` actor, never a person.
2. **Receipt shape.** `authority_kind = 'panel_decision'` with a required
   `authorizing_decision_id`, and no review. A composite key ties the decision to the
   published version, and so to its composition and configuration. The actor is an
   accountable non-human principal for the curation pipeline: never a persona bot, and
   never a person's account.
3. **Database checks at insert and commit.** They are the counterparts of this slice's
   operator checks:
   - the decision is finalized and belongs to the published version;
   - its run's configuration version is the version's;
   - quorum was met;
   - its eligibility fingerprint equals the version's and the one published;
   - the version's latest operator review, if any, is not a rejection or a withdrawal
     (an operator veto stands);
   - the receipt chain and pointer checks apply unchanged.
4. **Service.** `Publications` publishes on a decision through the same commit
   (pointer, scope, configuration version, eligibility, idempotency keyed on the
   decision). A background job may switch the pointer only this way, and only with a
   finalized decision.
5. **Tests.** Required before the path is called ready:
   - a **missing** decision is refused;
   - a **forged** one is refused: not finalized, recomputed counts that disagree,
     another version's decision, or a person's review presented as a decision;
   - a **stale** one is refused: a fingerprint or configuration version that has since
     moved;
   - a **cross-configuration** decision is refused;
   - an operator rejection vetoes publication;
   - a panel decision never accepts a semantic claim.

What does not change for either authority:

* semantic claims are reviewed on their own (#190, #105). A panel decision, like an
  operator acceptance, never accepts a claim;
* source eligibility, rights, withdrawal and read-time withholding;
* actor provenance on every version, note and receipt;
* receipts are append-only, and approval never transfers to a new version.

## Invariants → constraint → test

The migrations are `20260926233642_create_curation_foundation` and
`20260927094256_repair_curation_integrity`. The services live under
`DevilsDictionary.Curation`. Test modules are under `test/devils_dictionary/curation/`:

| Module | Covers |
|---|---|
| `ConfigurationsTest` | C |
| `CompositionsTest` | K |
| `PublicationsTest` | R |
| `PublicationRaceTest` | the races, unboxed on committed connections |
| `AuditFindingsTest` | the regressions from the independent audit, one `describe` per finding |

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
| K5 | Versions and items are immutable; an arrangement is fixed at creation; one version per arrangement **per configuration version** | triggers; `arrangement_hash` (length-prefixed fields) recomputed from the items at commit; unique `(composition, configuration_version, arrangement_hash, eligibility_fingerprint)`; the fingerprint includes the configuration version | "a version cannot be edited, removed or have items added"; finding 3 "an unchanged arrangement is reissued under the new version, and needs its own review" |
| K6 | At most one lead and three highlights; the lead is a content item at position 1 | checks; unique `(version, role, position)`; the configuration version's `max_highlights` | "a fourth highlight or a second lead cannot be stored" |
| K7 | An exact revision belongs to its item's object, and is the current, active one; **a work's evidence is of that work** | composite FKs `(content_revision_id, item_object_id)` and `(sense_revision_id, item_object_id)`; `Eligibility`: superseded, withdrawn, words hash, catalog checksum and row, a catalog pin matching the object's verified identifier, a source record that materialized the object | "exact references are checked against the registry when the version is made"; finding 4 (three tests) |
| K8 | Exactly one intended meaning, on the scope | insert trigger (one of sense revision or lexeme); `Eligibility` (`:meaning_off_scope`) | "exact references are checked…" |
| K9 | Manual versions have manual origin, a reason, a human author and no run; **a note is its authenticated author's** | checks `origin = 'manual'` and `selection_origin = 'manual'`; human-actor trigger on `created_by_actor_id`; a note spec is its text alone; `note_author_actor_id` must be the version's author (a `bot` for a model note), under that actor's own label | "a version is manual, human, reasoned, exact, and invents no history"; finding 5 (three tests) |
| K10 | Bierce first, among entries that may lead | `Curation.LeadRule` at creation, review, publication and read. A definition is on the page only through a `defines` claim that passes `Claims.visible(:public)`. A priority entry that may not be displayed neither leads nor blocks | "an applicable Bierce entry leads, and a version without it is refused"; "where Bierce has no entry…"; finding 2 (four tests) |

### Review and publication (#196)

| # | Invariant | Enforced by | Test |
|---|---|---|---|
| R1 | Only reviewers make operator decisions; decisions are append-only and idempotent; an acceptance is of the version's own fingerprint | human-reviewer trigger; update/delete triggers; unique `idempotency_key`; acceptance trigger; `Reviews.decide/4` rechecks the role under lock and refuses a version that no longer stands | "a bot or a non-reviewer cannot review"; "decisions are append-only and idempotent"; "an acceptance is refused once the version no longer stands" |
| R2 | Approval is not publication, and not a claim or page decision | separate tables and services | "approval publishes nothing and accepts no claim or page" |
| R3 | The pointer moves only with a receipt, **and the receipt names a valid authority**: for `operator`, a reviewer and the version's latest review, an acceptance of the published fingerprint; any other authority is refused | composite FKs on receipts; `authority_kind` check; authority trigger; deferred trigger (pointer = latest receipt) | "the database refuses a pointer without a receipt…"; "every deferred check refuses at a real COMMIT"; finding 6 (five tests: missing, panel, forged, stale, cross-configuration) |
| R4 | Publication is atomic, checks the expected pointer, scope, configuration version and fingerprint, and is idempotent | `Publications` commit, in one transaction | "needs an accepted review, then writes a receipt…"; "is idempotent, checks the expected pointer…"; "stale fingerprints, a withdrawn approval and a changed configuration refuse" |
| R5 | Concurrent publications never overwrite each other, even past the service | row lock and expected pointer in the service; in the database, each receipt must continue the one before it, so the second COMMIT from one pointer fails | "two reviewers publishing from the same pointer: exactly one wins…"; "writers that skip the service's lock still cannot both commit from one pointer" (both unboxed) |
| R6 | Read time withholds and never substitutes | `Published.current/1`: a version-level problem withholds all of it (retired, configuration changed, scope changed, approval withdrawn); an item-level one withholds that item with its reason; a later Bierce entry, or a rejected defining claim, withholds a lead | the R6 tests in `PublicationsTest`; findings 1 and 2 |
| R7 | Source deletion is never blocked, never revives an item, and keeps nothing prohibited | every source reference `ON DELETE SET NULL (column)`, including the item's object and claim; the item guard permits only that nulling; `required_references` records at insert what the item was made with, so a nulled one withholds it (`:claim_deleted`, `:object_deleted`, …); items hold ids, hashes and locators | "a deleted source revision tombstones the item, and nothing prohibited is kept"; "an item's references can be nulled by a deletion, and never repointed"; finding 1 (two tests) |

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

### Repaired after the independent audit (`b8211ed`)

`20260927094256_repair_curation_integrity` is a separate migration, so every database
that applied the first one is repaired by `ecto.migrate`. It is reversible: rollback
restores the previous triggers, functions and index.

1. **Deleted claim evidence revived an item.** A deleted claim and "no claim" were
   both `nil`. Each item now records `required_references` at insert (written by the
   database, not the caller), and a nulled required reference withholds it.
2. **A rejected `defines` claim still authorized a lead.** `LeadRule` now reads the
   relationship through `Claims.visible(:public)` for both priority and fallback leads,
   and an applicable priority entry must itself be eligible to lead.
3. **A configuration upgrade blocked reissuing an unchanged selection.** The
   deduplication key and the fingerprint now include the configuration version. The
   reissued version needs its own review.
4. **An unrelated object could carry a catalog pin.** A pinned object must carry the
   row's identity as a verified external identifier, and a source-record work must be
   the object its record materialized. A catalog pin with no object remains a
   catalog-only work.
5. **A caller could name a note's author.** A note spec is its text alone. The author
   is the acting principal, recorded as `note_author_actor_id` under its own label,
   and the database refuses anything else.

The publication contract was also reconciled with the intended product (see
[Publication authority](#publication-authority)), and PostgreSQL 15+ is documented and
checked.

### Not written by this slice

No `curation_runs`, participants, candidates, ballots, nominations, decisions,
attempts or round responses; no `local_model_configs`; no page bindings. No
`assertions`, `assertion_revisions` or `assertion_reviews` row is written by any
service here, which a test asserts.

## Deferred

These are later scoped slices, each owned by its issue:

- **#196 / #197:** runs, participants, candidates, proposals, ballots, round responses,
  nominations and attempts. Five admitted profiles, weight 1, fixed 4/5, two rounds,
  ten normal generations plus at most one repair; a missing response is never an
  abstain ballot. **The panel-decision publication authority**, as specified above.
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
- PostgreSQL 15 or newer, in development, CI and production.
