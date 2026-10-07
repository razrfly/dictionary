# Exemplar items (#212)

An **exemplar** is a person, a work or a passage that someone cited as an example of a meaning. It is recorded as an `illustrates` claim with a rationale, evidence and a review of its own (#181, layer 2). Build 1 of [#212](https://github.com/razrfly/dictionary/issues/212) lets a composition select one as a highlight.

It builds on [persistence slice 1](persistence-slice-1.md) and changes none of that slice's item shapes.

**Selecting never cites, and citing never selects.** A composition is a selection *of* eligible claims. It is not a fourth kind of claim. Composing, reviewing or publishing one writes no `assertions`, `assertion_revisions` or `assertion_reviews` row.

## Schema

The migration is `20260927204902_add_exemplar_composition_items`. It is additive, and it is reversible: rollback restores the previous shape check and insert trigger byte for byte.

| Change | Rule |
|---|---|
| `item_kind` gains `'exemplar'` | A highlight only (`editorial_composition_items_shape`). The lead is still a `content` definition (K10). |
| `assertion_revision_id` | Required at insert. It must name an `illustrates` claim (insert trigger). |
| Composite key `(assertion_revision_id, item_object_id) → assertion_revisions (id, subject_object_id)` | The claim is about the object shown. On delete it sets `assertion_revision_id` to NULL, so a deleted claim withholds the item (`required_references`, R7). |
| Unique index `assertion_revisions (id, subject_object_id)` | The key's target. `id` is already unique. The migration builds it inside its own transaction, so writes to `assertion_revisions` wait for it. |
| `content_revision_id` | Required when the subject is a `content` object: it pins the words shown. Refused for an entity (insert trigger, and the existing content key). |
| The other references | The sense-quotation and work references stay NULL (shape check). |

`arrangement_hash` and `required_references` are unchanged: both already cover every column an exemplar uses.

**The key binds every kind.** PostgreSQL has no per-kind foreign key. So a claim that annotates a `content`, `sense_quotation` or `work` item must now be about that item's object as well. Slice 1's only use, a `defines` claim on its own content item, already satisfies this. `Eligibility` refuses any other annotation with `:claim_not_about_object` before the insert, so `create_version/3` returns an error instead of raising. An exemplar-only trigger check is the alternative, and is on #212 for the owner.

## Invariants → constraint → test

The tests are in `test/devils_dictionary/curation/exemplar_items_test.exs`.

| # | Invariant | Enforced by | Test |
|---|---|---|---|
| E1 | An exemplar is a highlight that names an `illustrates` claim | Shape check; insert trigger; `create_version/3` refuses `:exemplar_is_a_highlight` and `:claim_required` | "names a claim and no object, and is a highlight only"; "refuses an exemplar without an illustrates claim, as a lead, or showing another object" |
| E2 | The claim is about the object shown | Composite key. The spec names no object: the item's object is the claim's subject (`:subject_not_an_input`). Other kinds: `:claim_not_about_object` | as E1; "the service refuses, rather than raises on, a claim about another object"; "binds any item that names a claim to the claim's subject" |
| E3 | A passage pins its words; an entity pins none | Insert trigger; content key; `:entity_has_no_words` | "pins a passage's words and no entity's"; "a passage is shown by its pinned words…" |
| E4 (C2) | The claim's **latest review is `accepted`**, whatever `Claims.visible/2` allows | `:claim_not_accepted` | rejected; disputed (a person, and a work the public still sees); withdrawn by a review; sent back for review; "cannot be composed, whatever the public gate allows" |
| E5 | The claim is the current, active revision | `:claim_not_current` | superseded; withdrawn by its revision |
| E6 | The claim is public, and a passage's words are not redacted | `:claim_not_visible` (`Claims.visible(:public)`, `Claims.Visibility`) | "a retired subject…"; "a passage whose words are restricted…" |
| E7 | The item means what the claim means | `:meaning_mismatch`. A claim about a sense needs that sense's revision. A claim about a concept needs a lexeme one of whose senses publicly `refers_to` that concept | "is refused when the item means another sense, or the word…"; "a concept's example needs that concept, referred to by a sense of that word"; "withholds a concept's example once no sense of the word refers to it" |
| E8 (C3, decision 2) | The accepting review still describes what is displayed, and it is the context the version was made with | `:claim_context_changed`. The claim revision and the context fingerprint enter the eligibility fingerprint, and the version records the fingerprint in `resolution["claim_contexts"]` | "withholds until a new version is reviewed, even after the claim is re-accepted" |
| E9 (C4, R7) | A deletion withholds the item for good | `required_references`; the composite key sets NULL | "nulls only its reference and withholds the item for good" |
| E10 (C6) | An arrangement with an exemplar shows each thing once | `create_version/3`: `{:duplicate_display_identity, object_id}`. Identity is the object (a catalog-only work counts as the registry work that carries its row's identity), plus the digest of the words for a passage, a quotation or a definition | four tests under "one display identity per arrangement" |
| E11 (C1) | Composing, reviewing and publishing write no claim row | Separate tables and services | "a nomination, accepted, composed, reviewed and published, reads back offline" |
| E12 (C7) | Reading makes no provider or model call | `Published.current/1` reads only the registry | the two proof tests, with every test HTTP plug raising and the provider registry empty |
| E13 (C10) | Only an internal user nominates | `Contributions.propose/6` (unchanged) | "propose/6 refuses a bot actor's scope" |
| E14 | A discovery result is only a cache | The claim and the item hold registry ids, never a result id | "…deleting its shelf result changes nothing" |

The checks run in this order, and a claim that fails several reports the first:

1. deletion;
2. `:claim_not_current`;
3. `:claim_not_accepted`;
4. `:claim_not_visible`;
5. the scope and `:meaning_mismatch`;
6. `:claim_context_changed`;
7. the subject.

The subject check is the one the `content` kind already has:
- an entity must be active;
- a passage's pinned revision must still be current and displayable. If it is not, the reason is `:revision_superseded` or `:revision_withdrawn`. `Eligibility` has no `:content_not_current`.

## Reading it back

For each exemplar it shows, `Published.current/1` fills the item's virtual `subject` from the registry at read time: `%{object_id, kind, subkind, label, words}`. For a passage, `words` is the pinned revision's body. For an entity it is `nil`. Nothing is read for an item that is withheld.

## The review that accepts a claim

A review that accepts a claim needs a context. `Contributions.review/6` opens one. `Claims.review/3` does not, and an acceptance without a context reads as *changed since review* on the card. An exemplar resting on such an acceptance is withheld as `:claim_context_changed`.

## Provenance (Build 2)

`Examples.Provenance.of/2` is the one answer to "why is this example here". The exemplar card's disclosure, the person page, the opening (Build 3, #156) and #203's history all read it. It has no table, and reading it writes nothing.

Its stages:

| Stage | Read from | `:none` means | `:unknown` means |
|---|---|---|---|
| `source` | `assertions.source_id`, and `source_assertion_outputs` to `source_records.url` | not source-listed (an exemplar) | never |
| `nomination` | the submitting account, or a manifest's curator; a cited claimant, kept apart; the revision's `rationale`, `metadata` and `method`; `assertion_evidence`; `assertions.inserted_at` | not cited (an instance) | a claim no account submitted and no manifest wrote |
| `agent` | the revision's `method`, and #197's records once they exist | human work (`curated`), or a source's (an instance) | any other method, or none recorded |
| `review` | the latest `assertion_reviews` row, and whether its context still matches what is displayed | no review yet | never |
| `selection` | `Rank.order/1`'s signals, or the composition item and its version's author | never | never |
| `publication` | the receipt that published the item's version | unpublished | never |
| `featured` | the published compositions of the enabled global default that select the claim now, through `Published.current/1`, each with its scope's words and `shown_on_page: false` | (an empty list) | never |

How it reads:

- **It goes through the viewer's gate.** Every read is through `Claims.visible/2` for the viewer. A claim the viewer may not see has no provenance at all (`nil`).
- **The public sees nothing a reviewer has not accepted.** For the public, a nomination whose latest review is not `accepted` also has no provenance, whatever its subject and whoever submitted it (#212 decision 1, taken 7 October). A claim no account submitted, such as a legacy row, is a nomination whose nominator is unknown, and is held to the same rule. The person-only public gate still decides the card and the count; that gate is #190's, and this issue does not change it.
- **The nominator is an account.** `nomination.by` is the submitting account, or a manifest's curator (`Provenance.nominator/2`, the rule the card uses too). A claimant the claim cites, such as a named person or an unknown claimant, is `nomination.claimant`, shown as "citing …". It is never presented as the nominator.
- **No page is claimed.** `featured` lists only the global default's compositions, the one configuration a page would read. An internal test configuration's are never listed. No page shows a composition yet: the binding is #194's, and the reader is #156 Phase 2's. So every entry says `shown_on_page: false`, and the surfaces say "selected for the opening of *word* … the page does not show openings yet".
- **Only a receipt dates a publication.** Publication times come from `editorial_composition_publications.committed_at` and nowhere else.
- **Where a nomination came from.** A form nomination records the shelf it was prefilled from, written by `ConnectionLive`, and nothing in the URL is taken on trust:
  - a result is recorded as `metadata["from_result"]` and `metadata["provider"]` only if it is about the prefilled subject, and the provider is read from the result's run;
  - a catalog link records `metadata["provider"]` only if `Artworks.catalog_source_slug/1` says the subject is that catalog's work;
  - anything unverified records nothing, so the origin stays unknown rather than guessed.

  The provider's name comes from `sources`, which retention never deletes.

## Service reuse map

| Surface | What it calls |
|---|---|
| Word page, `#examples` card | `WordPage.build/2` → `Examples.for_page/3` → `Provenance.attach/2` with the viewer; the card draws `DevilsDictionaryWeb.ExampleProvenance.why/1` |
| Word page, instance chip | nothing new. Each contributing claim keeps its own `/connections/:id`, one per source, never merged. |
| Person page, *cited as* | `EntityPage.build/2` → `Examples.cited_as/2` → `Provenance.attach/2` (`:public`); the "selected for the opening of…" line reads `provenance.featured` |
| Connect form | `ConnectionLive` → `Contributions.propose/6` with `metadata` (the shelf, verified against `discovery_results` or `Artworks.catalog_source_slug/1`) |
| Composing | `Compositions.create_version/3` → `Eligibility.evaluate/5` |
| Reviewing and publishing a composition | `Reviews.decide/4`, `Publications.publish/3` → `Standing.evaluate/2` (which passes the recorded claim contexts) |
| Reading a composition | `Published.current/1` → `Standing.evaluate/2`, then `subject` from the registry |
| The opening, development fixture (Build 3, behind `?opening=fixture`) | `ManualFixture` → `References.subject/1` and `References.exemplar_claim/2` → `Eligibility.check/3` on the item a composition would store → `Examples.exemplars/3` → `Provenance.of/2` (`:public`) → `Provenance.in_fixture/2`, drawn by `ExampleProvenance.rows/1` inside the opening's own disclosure |
| The opening, published (#156 Phase 2, not built here) | `Published.current/1` → `Provenance.of/2` on each `CompositionItem`; no page reads compositions until #194 binds one |
| #203's history | `Provenance.of/2` on a `CompositionItem`: its `selection` and `publication` |

**The seam #197's packet uses.** An exemplar candidate is an item of `Examples.exemplars(member_ids, :public)`. It stands if `Compositions.create_version/3` would accept `%{kind: :exemplar, assertion_revision_id: item.claim.revision_id, meaning: ...}`. That check is `Eligibility.check/3` on the item the spec builds. No candidate store or new object is involved.

The `agent` stage is the input contract #197's adapter must fill: profile and version, model digest and configuration, run and proposal ids, and a note. Until #197's records exist it reads `:none` for curated work and `:unknown` for anything else.

**What is not built here.** The issue's named discovery path, a Quotes-shelf card's connect link with the provider's record prefilled as evidence, does not exist on `main`. The quote card has no connect link, and `ConnectionLive` preselects only Artsy evidence. The test that covers this starts at the form with the shelf's parameters and proves the rest: the verified shelf record, the published exemplar read back after retention with every provider off, and no second object or claim. The link and the evidence prefill are deferred to #222.

## The opening (Build 3)

`Opening.Highlight` has a third kind, `:exemplar`. It is drawn only behind the development gate. `?opening=fixture` reaches it where `:curated_opening_fixtures` is on (dev and test configuration only), as with #202's other fixtures. `Curation.Published` is not wired to any page: the reader over published compositions is #156 Phase 2's, and the page binding is #194's.

- **How a fixture names an exemplar.** It names the subject, by a verified Wikidata QID or a passage's source record, and the meaning's sense, the way every fixture item is named. It never names a claim id.
  - The reader finds the `illustrates` claim of that pair (`References.exemplar_claim/2`): the current, active one whose latest review is not a rejection or a withdrawal, which `Contributions.propose/6` keeps unique. An earlier rejection does not count against a claim a later review accepted.
  - A row written another way, such as a legacy claim, can stand beside it. An accepted claim is then preferred, so a pending duplicate never hides one.
- **The same rules as a saved composition.** The reader builds the `CompositionItem` that `Compositions.create_version/3` would store. That is the claim's subject, a passage's pinned words and the meaning's sense revision. It asks `Eligibility.check/3` about that item, so an exemplar in a fixture is withheld for exactly the reasons Build 1 lists, accepted review first. Nothing is stored, and the fixture adds no approval of its own.
- **Withheld without a trace.** Every way a claim falls short (`:claim_not_found`, `:claim_not_accepted`, `:claim_not_visible`, `:claim_not_current`, `:claim_deleted`) reads the same under *How this was chosen*: "it is not an example a reviewer has accepted". Nobody is named, and the page does not say whether a nomination is waiting or was turned down.
- **The same stages as the card.** The tile's "Why this is here" holds the reason given and the six rows `ExampleProvenance.rows/1` draws on the card. Source, Nominated, Model and Reviewed are the card's word for word, because they come from `Provenance.of(item, :public)` for the same claim. Shown here and Opening describe the placement (`Provenance.in_fixture/2`): a development fixture chose it, and it is not published.
- **What the tile can draw.**
  - A person, work or other entity is drawn by its name.
  - A `quotation` or `passage` is drawn by its pinned words. They go through `Markdown.to_html/2` and sit under the quotation register, with the source's credit and licence on the tile, as the quotation tile carries them.
  - An `image` or `media` subject would need its own credits and image handling, so it is withheld as `:unsupported_subject`. Those are the four content kinds `illustrates` allows.
- **The committed fixture.** The `coward` composition in `priv/curation/opening-fixtures.json` names three fictional subjects by QIDs no Wikidata item has, under WordNet's *coward* sense as the dev corpus has it: two people (`Q999999212`, `Q999999213`) and a work (`Q999999214`). On a real corpus none resolves, and with no lead nothing renders.
  - `word_opening_exemplar_live_test.exs` makes all three, nominates each, and accepts only the first.
  - The pending work is the case that matters. Its card stays public under #190's gate, and only the opening's own rules keep it out.
