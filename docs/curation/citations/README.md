# Delivery A fixture evidence

These are test-partition demonstrations, not live acceptance. The implementation is based on main `9bfa2440549fadd5e749dc9218fcad866b9e0471`. The PR records the exact reviewed head and full precommit count.

## Visual checks

The LiveView test exports actual rendered HEEx for the new candidate groups, published opening and public version receipt. The project's compiled Tailwind CSS and local image assets are embedded into offline HTML. Chrome captures at actual 1280 px and 375 px inner widths; the capture asserts no horizontal overflow. These use system font fallbacks, fixture records and no live network, model, provider or HTTP server. Each view was visually inspected at both widths. They establish fixture rendering and wrapping; proxy routing and live publication remain the later #271 sittings.

| View | Desktop | Phone |
| --- | --- | --- |
| Candidate groups | [1280](evidence/groups-1280.png) | [375](evidence/groups-375.png) |
| Published tiles | [1280](evidence/tiles-1280.png) | [375](evidence/tiles-375.png) |
| Public receipt | [1280](evidence/receipt-1280.png) | [375](evidence/receipt-375.png) |

## Contract test map

Paths below are relative to `test/devils_dictionary/curation/` unless specified. This maps the contract's test numbers to suites for independent review; it does not replace reviewing assertions against each rule.

| #270 test numbers | Evidence suites |
| --- | --- |
| 1–3: native coverage, linked claim paths and frozen representations | `citation_claims_test.exs`, `citation_edge_test.exs`, `citation_model_test.exs`; `test/devils_dictionary_web/live/citation_receipt_live_test.exs` |
| 4–6: exact and legacy observations, current eligibility | `citation_foundation_test.exs`, `citation_retention_test.exs`, `citation_providers_test.exs` |
| 7–10: immutable citation guards, SQL shapes, hash and identity | `citation_sql_test.exs`, `citation_providers_test.exs`, `citation_foundation_test.exs`, `citation_edge_test.exs` |
| 11–12: expiry, missing revision, visibility and publication | `citation_expiry_test.exs`, `citation_lifecycle_test.exs`, `citation_foundation_test.exs`, existing `published_reader_test.exs` |
| 13–15: packet cuts/fields, focus, retry and reachability | `runtime/packet_test.exs`, `runtime/packet_v2_scope_test.exs`, `runtime/contract_test.exs`, `citation_output_test.exs`, `citation_window_test.exs`; existing proposal/recovery regression suites |
| 16–18: writer, required reasons and original-choice ancestry | `citation_model_test.exs`, `citation_lifecycle_test.exs`, `citation_output_test.exs`, existing `publications_test.exs` and proposal/review regression suites |
| 19–20: dates, public receipt, historical status and references | `citation_receipt_test.exs`, `citation_lifecycle_test.exs`, `citation_model_test.exs`, existing `published_reader_test.exs`, `test/devils_dictionary_web/live/citation_receipt_live_test.exs` |
| 21: provider-copy guards and actual retained rows | `citation_expiry_test.exs` (12-provider actual-row checks), `citation_output_test.exs`, `citation_model_test.exs` |
| 22–23: starvation, deadlines, policy changes, redaction/refetch and races | `citation_retention_test.exs`, `citation_providers_test.exs`, `citation_sweep_race_test.exs`, `citation_foundation_test.exs` |
| 24: projected v2 bundle, integrity restore, v1 compatibility | `test/devils_dictionary/installation/citation_bundle_test.exs`, existing `bundle_bootstrap_test.exs` |
| 25: all completion windows and deferrals | `citation_window_test.exs`, existing `configurations_test.exs` and refresh/proposal regression suites |
| 26: additive compatibility and rollback fences | `citation_compatibility_test.exs`, `citation_sql_test.exs`, `test/devils_dictionary/installation/citation_pre_migration_test.exs` |
| 27: screen groups and reader elements | `test/devils_dictionary_web/live/citation_receipt_live_test.exs` |

All cleanup, policy aging, bundle capture/restore and model responses in these tests use disposable fixtures. Real daily reassessment, agent-chosen current news, proxy checks, expiry over real elapsed time and owner publication are not claimed here; #271 assigns those live acceptance steps after separate authorization.

## Independent review regressions

`citation_review_regression_test.exs` incorporates the five failing independent probes and counterexamples: deleted cited revision export, unprotected due revision beside native provenance, paginated display winner, frozen expiry after cache deletion, and redaction precedence. It also checks newer native record fields, provider/mapping gates, NULL record references and paired saved/frozen eligibility under a stricter current policy. `citation_bundle_test.exs` additionally inspects real COPY bytes and restores a cited record whose payload revision has been deleted.

`ProviderCitationFixtures.provider_observation!/2` drives the twelve existing committed conformance response fixtures through the real discovery adapter and fixture transport. It reproduces the resulting complete payload, match and metadata shape on the test curation page under a valid manual mapping. This is deliberately a fixture selection test, not a semantic assessment of the fixture article against the test word. No source content is authored and no network request is made. The twelve owner expiry cases in `citation_expiry_test.exs` inspect actual retained rows and policy field paths; hash-typed digests and independently permitted Open Library bibliographic values are distinguished from prohibited payload copies.

The twelve `citation_shaped_agent_test.exs` cases span all seven shelf kinds through packet → stubbed agent response → writer → owner publication → public receipt, preserving exact revision/checksum and model evidence. Guardian uses unchanged Edit-then-publish to test model attribution across that seam; the others use Take. The PoetryDB case also verifies unique legacy binding for both genuine adapter result shapes. The existing generic provider projection cases remain additional boundary tests.

`citation_deleted_history_test.exs` additionally covers saved and uncited frozen expiry after complete run/result removal, uncited missing-current history, prospective empty-record field projections, unique counts, deletion overlaps and repeat-sweep idempotence. The real COPY/restore fixture includes an uncited deleted current discovery revision with a retained older native sibling. Demonstrably current native payloads preserve their independent record fields; positive discovery identity/history without that proof is projected conservatively. No owner policy is amended by these identity/accounting refinements.
