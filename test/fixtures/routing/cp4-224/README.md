# #224's inputs, for the standing review rule's tests (#237)

The files the owner's row-by-row review of 8 October 2026 was made from and
recorded in, so `ReviewRuleReproductionTest` can show what the standing
review rule decides on the same inputs. Copied from the private evidence of
[#224](https://github.com/razrfly/dictionary/issues/224)
(`private/2026-10-08-224/`); nothing here is edited.

| File | What it is | SHA-256 |
|---|---|---|
| `export-subset.jsonl` | The lines of the policy export `routing-input.jsonl` (SHA-256 `a33f1bc8c62b630be701d84b48f994fcfb6c127a8d4012bf492911cdb1b55fd0`, 173,949 lines) that the population's evaluation reads, byte for byte: the read-only attestation, the lexical count, the 170 population entities and the 171 class-evidence records their classifications depend on (`Policy.classify/3`'s dependencies and source lookups). 343 lines. | `73daf73a8905ec25829542708eabd85fcbe6b662fb4b6ac57a2639adbd06c387` |
| `review-worksheet.json` | The owner's worksheet: the 129 records awaiting review after #224's run without reviews (run `7008c6f3…`), each with the evidence fingerprint reviewed. | `af7ff2026865bb886df6908fbf5355b558b7106ce0c1c90d4ae72a599544cfd0` |
| `reviews-owner.json` | The owner's review file: 124 confirmations and 5 deferrals under the owner's reviewer account, bound to the population. | `57e26405cce64fd8b05a1d79e3d811f85e91b0cd428a1862946cb07f7a987792` |
| [`docs/routing/stage-2/extract_subset.exs`](../../../../docs/routing/stage-2/extract_subset.exs) | How `export-subset.jsonl` was made (kept beside `candidates.py`, outside `test/`, so `mix test` does not try to load it). | |

The population itself is `docs/routing/stage-2/candidates.json` (SHA-256
`c2cbd2ef7703b7a01acbd9e3f63051097779ce75ebed874d83ce408ded553d51`),
byte-identical to the file #224's runs read.

The subset is enough because an evaluation is a function of the entity's
input, the policy and exactly the records it depends on
(`docs/routing/stage-2/backfill.md`): `extract_subset.exs` checks that every
population entity classifies identically on the subset and on the whole
export, and the test checks that the subset gives every worksheet row the
fingerprint the owner reviewed.

    DD_NO_OBAN=1 mix run --no-start docs/routing/stage-2/extract_subset.exs \
      routing-input.jsonl docs/routing/stage-2/candidates.json export-subset.jsonl

These are public-domain catalogue data (Wikidata class evidence, registry
labels and descriptions) and the owner's routing decisions, already quoted
on #224. They are fixtures for tests, never written to a database.
