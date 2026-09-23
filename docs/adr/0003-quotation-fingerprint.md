# ADR 0003 — a quotation's words are its identity

Status: accepted, 2026-09-23 (#158 open question 6, answered yes by the owner;
built as #158 build 3). This is the one written exception to the discovery
rule *association is identity, never text* (`docs/discovery/README.md`, "The
one rule"). There is no other, and a second would need its own ADR.

## Context

Everything the encyclopedia folds, it folds on an identifier: a film on its
TMDb or Wikidata id, an artwork on its Met object id or QID, a person on a QID
(#164). A title is never identity — *Titanic* (1953) and *Titanic* (1997) share
one and are two films, and a label match is exactly the mistake the discovery
rule exists to prevent.

A quotation has no such identifier. "We must cultivate our garden" has no id
that Wikiquote, Wiktionary and a primary text would all publish; the only thing
the three have in common is the words. Since #164 a quotation is a
`content_items` row matched on its `identifiers`, and with only the provider's
own id there, the same line from two providers is two subjects, two cards, two
rows on Voltaire's page — and "two independent sources agree", which build 5's
*Verified* badge depends on, cannot be computed at all.

## Decision

A quotation's normalised words, hashed, are published as an identifier.

- **Namespace** `quotation_fingerprint`. **External id** the lower-case hex
  SHA-256 of the normalised text (64 characters). The normalised text itself
  is never stored as the identifier; `content_revisions.body` keeps the words
  as the source gave them.
- **Every quotation provider** puts the fingerprint in `identifiers` beside its
  own id — on the item, so `Shelf.dedup/2` folds at read time, and on the
  `SourceIdentity.Entry`, so resolution folds in the registry. The provider's
  own id stays the stable identifier, so a provider correcting its own typo
  keeps its item.
- **Resolution** needs nothing new. The existing verified-unique index on
  `external_identifiers (namespace, external_id)` makes the second provider's
  copy match the first's item; it writes no item, and its `authored_by` is a
  second assertion on the same subject — the agreement build 5 counts. No
  migration: the namespace is a value.
- **Alternate text** (`SourceIdentity.add_alternate_text/2`, #164 C2) compares
  fingerprints, not bytes: a full stop or a curly quote is not a second text,
  a different wording still is.
- **Implementation**: `DevilsDictionary.Quotations.Fingerprint` —
  `normalise/1`, `fingerprint/1`, `identifier/1`, with a doctest per rule and
  one pinned fingerprint.

### What is normalised (version 1)

Differences of typography and transcription only:

1. Unicode canonical composition (NFC).
2. Case, folded to lower.
3. Curly quotes and primes straightened; every dash (en, em, figure,
   horizontal bar, minus) straightened to a hyphen.
4. `...` written as `…`; a leading or trailing ellipsis dropped. An ellipsis
   **inside** a line marks an elision and is kept: "I came … I conquered" is
   not "I came I conquered".
5. Apostrophes removed (`don't` and `dont` are one transcription); every other
   punctuation mark becomes a word break — except `%`, `&` and `#`, which read
   as words.
6. Whitespace collapsed and trimmed.

### What is never normalised

- **No stemming, synonyms or spelling variants.** "cultivate our garden" and
  "cultivate one's garden" are different claims and must stay different
  fingerprints; a stemmer would fold them.
- **No translation.** "Il faut cultiver notre jardin" and "We must cultivate
  our garden" are two lines, two fingerprints and two subjects. The link
  between them is a claim (`excerpt_of`, or a later `translation_of`), made by
  someone who knows, never a fold.
- Digits and symbols are words.

## Limits

- **It is not a search.** A fingerprint is compared for equality, the way a
  QID is. Nothing looks a line up by fuzzy similarity, and a near-miss is two
  lines. The rule's point — a search proposes, an identifier decides — stands.
- **A collision would be visible.** Two genuinely different lines that
  normalise to the same text (they would have to differ only in case,
  punctuation or an edge ellipsis) would fold into one card with two sources,
  on a public page, where a reader or a reviewer would see it. None has been
  observed. SHA-256 collisions between different normalised texts are not a
  practical concern.
- **Punctuation can matter and is still dropped.** "Let's eat, Grandma" and
  "Let's eat Grandma" fold. For quotations, where sources re-punctuate freely
  and the words are the claim, that is the right trade; it is the reason this
  is an exception for quotations and not a rule for text.
- **An item may carry more than one fingerprint.** When a provider's own
  wording changes (a correction upstream), its item gains the new fingerprint
  beside the old one; both wordings then resolve to it. If the new wording is
  already another item's, the two identifiers point at different objects and
  resolution opens the existing `external_identifier_conflict` case rather
  than choosing.
- **The rules are frozen by version.** `normalisation_version: 1` is recorded
  on every fingerprint identifier. Changing a rule changes fingerprints and
  would orphan every held one, so a change is a new version with a rewrite of
  the held identifiers, decided in a new ADR.

## Consequences

- Build 1's Wiktionary renderer calls `Fingerprint.fingerprint/1` for
  display-time folding and writes nothing. Build 4's Wikiquote provider
  carries `Fingerprint.identifier/1` from its first run, so its lines fold with
  Wiktionary's from day one.
- Build 5's two-agreement rule is a count of distinct sources crediting one
  subject; before this ADR it had nothing to count.
