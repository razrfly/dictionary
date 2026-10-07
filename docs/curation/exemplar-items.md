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
