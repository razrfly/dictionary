# Artsy artwork integration

Status: optional, server-side, bounded, and removable. Implemented for issue
[#86](https://github.com/razrfly/dictionary/issues/86) on top of the shared
source-identity work from issue #93.

## Product role

Artsy is a discovery and selected-record enrichment source. It is not the
durable identity authority and it never creates an accepted interpretation.
Wikidata QIDs plus exact P11005 (artwork) and P2042 (artist) statements provide
the durable crosswalk. Artsy's opaque artwork/artist IDs and its human-readable
slugs occupy different namespaces. Labels and years are descriptive fields,
never identity keys.

The public `/artworks` page searches the local catalog without network calls.
Its separate Artsy form is an explicit, transient source-availability check.
Word pages use only retained direct gene assignments and a versioned set of ten
exact sense/language mappings to display **not-yet-reviewed candidates**. A contributor
selects a local work and exact meaning in the existing `/connect` composer;
normal attribution, evidence, review, revision, and dispute rules apply.

No Artsy image bytes or hosted derivatives are downloaded. Remote thumbnails
are only reference fields in removable source payloads. Durable encyclopedia
text and images continue to come from independently licensed sources.

## Configuration

Set these server environment variables (the values must never be put in a
manifest, browser payload, log, fixture, or committed file):

```text
ARTSY_CLIENT_ID
ARTSY_CLIENT_SECRET
```

If either is absent, the provider is disabled while the local collection keeps
working. The client exchanges them for an in-memory XAPP token, refreshes once
after a 401, follows at most two same-host HTTPS `/api/` redirects, throttles
requests, caps retries, obeys `Retry-After`, and returns scrubbed error codes.

## Bulk seed runbook

Build a versioned manifest from exact Wikidata identifiers:

```sh
mix dd.artworks.seed \
  --manifest priv/artworks/manifests/pilot-v1.json \
  --build --candidate-limit 50 --discovery-request-limit 4
```

Validate without database or provider writes:

```sh
mix dd.artworks.seed \
  --manifest priv/artworks/manifests/pilot-v1.json \
  --dry-run
```

Run or resume a bounded import:

```sh
mix dd.artworks.seed \
  --manifest priv/artworks/manifests/pilot-v1.json \
  --record-limit 50 --request-limit 160 --batch-size 10 --resume
```

The JSON contains a schema version, selection policy, source identifiers,
selection reasons, creator crosswalks, checksum, and per-record outcome. It
contains no credentials. It is saved atomically after each record, so an
interrupted run can resume. Completed records are skipped with `--resume`;
quota-stopped records remain retryable. Re-running without `--resume` is also
safe: exact IDs converge through `SourceIdentity`, source records upsert, and
creator claims use a source-native origin key.

Only `Painting` Artsy records enter the selected painting catalog. Prints and
other possible reproductions are retained as source observations and reported,
but are not merged into the Wikidata painting. Missing Artsy records still
leave a useful Wikidata/Wikipedia-linked artwork.

The committed pilot manifest contains 43 paintings across 21 creators found in
two bounded Wikidata requests. It includes such independently identified works
as *The Birth of Venus* (Q151047), *Bacchus and Ariadne* (Q1206860), and
*Portrait of Pope Julius II* (Q11918714). The cap is 5,000 records, while the
issue's intended routine batch is at most 500.

## Live 2026-09-12 pilot

The readiness audit made 132 Artsy requests. The subsequent five-record import
made 13: four P11005 slugs were no longer retrievable and one resolved through
a safe redirect, producing one work, one creator link, and 13 direct genes.
The same batch was immediately run again with 13 requests: zero new works,
zero duplicate creator links, one exact match, and the same four honest
unavailable outcomes. There were no retries, conflicts, reproductions, or quota
errors. A final browser search used two more requests and returned an honest
empty state. Readiness, both import runs, and browser validation used 160 Artsy
requests, below the issue's 200-request feasibility ceiling.

The detailed audit and museum comparison are in
[`artsy-feasibility-2026-09-12.md`](artsy-feasibility-2026-09-12.md). It records
the 10-work/10-meaning probe, unsafe gene-filter finding, pagination defect,
404 rate, exact P11005/P2042 validation, and 20-query Metropolitan Museum
comparison.

## Retention and shutdown

Artsy's [API terms](https://developers.artsy.net/v2/terms) do not provide the
independent durable-data license Dictionary needs. Every Artsy source record is
therefore marked removable. Disable new calls by unsetting the credentials or
setting `config :devils_dictionary, :artsy, enabled: false`.

If access or terms end, execute the explicit withdrawal path:

```sh
mix dd.artsy.withdraw --reason "API access ended on YYYY-MM-DD"
```

It disables the source and mappings, makes cache results undisplayable, retires
materialized outputs, withdraws Artsy-source claims, rejects Artsy-only opaque
IDs, clears provider URLs/hashes, and physically removes Artsy raw revisions.
Wikidata QIDs/P11005 slugs, Wikipedia/Met facts, local identities, and human
editorial claims remain. The operation is transactional and tested.

## Known limits

- The Artsy API is retiring and many search hits no longer hydrate. This is
  expected source unavailability, not a reason to weaken identity matching.
- Artsy's `gene_id` search filter did not change the sampled result page, so
  gene traversal/filter acquisition is disabled. Only direct genes from an
  exact hydrated artwork are considered.
- The Metropolitan Museum API remains the better open-image/reference source,
  but its broad text search is noisy and four audit concepts had no results.
- The committed manifest is a reproducible seed set, not an assertion that all
  43 provider records remain live. Availability is intentionally recorded per
  run.

Primary API references: [authentication](https://developers.artsy.net/v2/docs/authentication),
[search](https://developers.artsy.net/v2/docs/search),
[artworks](https://developers.artsy.net/v2/docs/artworks), and the
[Metropolitan Museum API](https://metmuseum.github.io/).
