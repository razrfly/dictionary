# Curation runtime, stage A: a private local model behind one inference slot

Stage A of [#195](https://github.com/razrfly/dictionary/issues/195), on the foundation
merged in PR #206 ([persistence-slice-1.md](persistence-slice-1.md)).

**What it does.** An operator submits one bounded, frozen evidence packet to a private,
persistent local model. The answer is either a validated result or a precise refusal.
Either way it carries a durable request identity, the model's provenance, and its
accounting.

**What it does not do.** It writes no composition, version, review, publication, claim
or page row. It adds no personality dossier, panel run, ballot, decision, schedule or
automatic publication (#197, #198, #194). The default configuration stays manual-only
and public curation stays off. Personas will share this one model; there is no model or
process per persona.

## Moving parts

| Piece | Module | Holds |
|---|---|---|
| Model provenance | `Runtime.ModelConfig` (`local_model_configs`), written by `Runtime.Provenance` | Immutable: tag, manifest and layer digests, weights digest, quantization, license name and digest, template digest, runtime version, capabilities, generation settings, instruction and output-contract versions |
| Endpoint | `Runtime.Endpoint` (application config) | Operational only: base URL, mount point, models root, run directory, binary, limits. Never on a model config, never a persona property |
| Physical service | `Runtime.Service` (`inference_services`) | The one slot: state, holder, fence, epoch, lease, quarantine and pause reasons |
| Attempts | `Runtime.Attempt` (`inference_attempts`) | Request identity, owner, fence, lifecycle, packet hash and summary, validated result, metrics |
| Accounting | `Runtime.LedgerEntry` (`inference_ledger_entries`) | Append-only reserve, release and charge entries per UTC day |
| Client | `Runtime.Ollama` | Req, nonstreaming `/api/chat` with a JSON-schema `format`, no automatic retries |
| Host | `Runtime.System` | The volume (`diskutil`: mounted, external, device), memory and swap, files, process liveness. Tests swap in `RuntimeFakeSystem` |
| Service process | `Runtime.ServiceProcess` | Start, stop (the confirmed stop recovery needs) and status of the one private `ollama serve`. A recorded pid counts only while it runs the configured binary, so a pid reused after a reboot is never signalled. A stop is confirmed only when the server, every runner it started (read from the process table before anything is signalled) and its port are gone |
| Slot authority | `Runtime.Authority` (`<run_dir>/authority.json`) | The one database, cluster and service key whose slot row governs the physical service |
| Checks | `Runtime.Readiness` | Slot, volume, models root, authority, runtime version, served digest, manifest on the models root |
| Contracts | `Runtime.Packet`, `Runtime.Contract` | The frozen input and the validated output. The instruction is pinned by version (`generic-editor-v1`, `generic-editor-v2`), each text held to its sha256: a model config names one, a packet is built for and carries it, and `Runtime.run/3` refuses a packet built for another (#254 P7) |
| Coordination | `Runtime.Gateway` | Admission, dispatch, completion, quarantine, sweep, recovery, pause and resume |
| Entry point | `Runtime.run/3` and `mix dd.runtime` | Readiness → packet check → admission → dispatch → validation → settlement |
| Benchmark | `Runtime.Bench`, `priv/curation/runtime_bench/` | The predeclared plan, its frozen packets, and the runner. A cold sample runs only after a confirmed unload; otherwise that model's remaining calls are reported as not measured, since neither a cold nor a warm sample would mean what it says. The adverse counts each say how many answers they could be seen in, and are null, not 0, when none: a refused answer's ids are read from the ids-only shape the attempt keeps, and only a validated answer keeps its reasons (#221 B1). A plan names its instruction, and the go checks it declares are evaluated by `Bench.verdict/5`, failing on missing or unseen evidence |

Operating the service is in [runtime-operations.md](runtime-operations.md). The measured
benchmarks are [runtime-benchmark-2026-09-27.md](runtime-benchmark-2026-09-27.md) and its
re-run under `generic-editor-v2`, [runtime-benchmark-2026-10-26.md](runtime-benchmark-2026-10-26.md),
whose verdict for P6 is a no-go.

## The slot protocol

The authority is PostgreSQL, not a BEAM process. Every caller of the physical service,
on any node, goes through the same `inference_services` row.

"The same row" also means the same database. A caller connected to another database,
such as a test partition, a benchmark database or a second environment, would find a
slot row of its own. So `ServiceProcess.start/1` binds the service to one database,
cluster (`system_identifier`) and service key, in a marker on the volume
(`Runtime.Authority`). Readiness refuses every other caller with `foreign_authority`
before anything is sent. Moving the binding takes an explicit `--rebind`.

1. **Admit** (one transaction). Lock the service row with `FOR UPDATE`, then:
   - replay an existing attempt with the same `request_key`;
   - require the service to be `available`;
   - reserve the call's deadline against today's UTC budget, and one unit against the
     pending-work cap;
   - bump the fence, insert the attempt as `admitted`, and mark the service `occupied`
     by it.
2. **Dispatch.** Commit `dispatched` *before* the request is sent. From then on, a crash
   is known to have possibly reached the model. An attempt still in `admitted` state
   provably never did.
3. **Send.** Send one nonstreaming request with `retry: false` and the per-call deadline
   as the receive timeout. Only a connection refused (the request was never written)
   may be retried, at most twice, on the same attempt. Twice is the database's bound
   (`transport_retries` CHECK), read in code as `Attempt.max_transport_retries/0`:
   configuration may lower it, and a higher setting is refused before admission. A
   dispatch or retry note that finds the attempt no longer holding the slot (another
   caller's sweep took it) is refused as `:stale`, and nothing more is sent.
4. **Complete** (one transaction). Lock the service. The service must still be held by
   this attempt under this fence, or the result is refused as stale. Then:
   - validate the response;
   - record the result, the refusal reasons and the metrics;
   - release the slot, release the reservation, and charge the occupancy, all once.
5. **Uncertain.** A timeout or transport error after sending, a dead caller, or an
   expired lease on a `dispatched` attempt does **not** prove generation stopped. The
   attempt becomes `uncertain`, the service `quarantined`, the slot stays held, and
   nothing is settled or refunded.
6. **Recover** (operator). Stop the private service process and verify it is gone, which
   is the only proof the old generation ended. Then settle the uncertain attempt as
   `ended_by_restart`, charging its whole occupancy up to the confirmed stop. Bump the
   epoch, restart the service, and return the slot only after readiness passes. A late
   answer from the old generation then fails the fence check.

An `admitted` attempt whose lease expired never sent anything. It is released and
charged nothing.

## Invariants → enforcement → test

`G` is the gateway, `P` the packet, `C` the output contract, `R` readiness. The tests are
in `test/devils_dictionary/curation/runtime/`. `GatewayRaceTest` is unboxed: each caller
is its own process with its own database connection and committed transactions, so it
proves what a single-process mutex could not.

| # | Invariant | Enforced by | Test |
|---|---|---|---|
| G1 | At most one live attempt (admitted, dispatched or uncertain) per physical service, across nodes and databases | service row lock; partial unique index `inference_attempts_one_live_per_service`; the authority marker, checked by readiness | `GatewayRaceTest` "two independent callers: one generation, one busy refusal, one settlement" and "callers that skip the gateway still cannot both make a live attempt"; `GatewayTest` "an admitted attempt holds the slot; a second caller is refused, and so is the database" |
| G1′ | The physical service is governed by exactly one database, cluster and service key | `Runtime.Authority`; readiness step `authority`; `ServiceProcess.start/1` refuses to rebind silently | `ReadinessTest` "a caller of any database but the bound one is refused, before the service is asked"; "binds once, keeps its own binding, and moves only on an explicit rebind" |
| G2 | The holder belongs to the service and is live under the fence, whichever row changes; an `occupied` service has a holder | composite FK `(holder_attempt_id, id)`; shape check; deferred `inference_services_holder` trigger on the service and `inference_attempts_holder` on the attempt (migration `HardenCurationRuntime`) | same `GatewayTest` case; "an attempt cannot finish while it still holds the slot, even if the service is untouched" |
| G3 | Admission is idempotent per `request_key`; a different request under a used key is a conflict | unique `request_key`; replay compares the packet hash and model config | "a duplicate request replays its receipt; a different request under the key conflicts" |
| G4 | A result is accepted only from the current holder under its fence; stale, late or duplicate results are refused, and so is a stale dispatch or retry | dispatch, retry and completion check holder, fence and state under the row lock; `Runtime.run/3` answers `{:refused, :stale}` | "a result is accepted once, from the holder under its fence"; `GatewayRaceTest` "a caller that dies mid-generation leaves the slot held until a confirmed stop" (its late completion is stale) and "a sweep between admission and dispatch: the caller is refused, nothing is sent"; `RuntimeTest` "a retry on an attempt a sweep has taken is refused as stale" |
| G5 | A timeout, crash or expired lease after dispatch quarantines; it frees and refunds nothing | `dispatched` committed before send; `uncertain` handling; lease sweep | "a timeout after dispatch quarantines the service, frees nothing and refunds nothing"; "an expired admitted lease releases the slot; an expired dispatched lease quarantines it"; `RuntimeTest` "a timeout after dispatch quarantines the service; the next caller is refused" |
| G6 | Recovery requires a confirmed stop of the service process and every runner it started, settles once, and holds the slot until resume | `ServiceProcess.stop/1` confirms the server, its runners and the port; `Gateway.recover/2` takes the stop confirmation; epoch bump; paused until `resume` | "a confirmed stop settles the uncertain attempt once and holds the slot until resume"; the killed-caller race test; `RuntimeTest` "recovery stops nothing unless this database owns a quarantined slot"; `ServiceProcessTest` "a runner a killed server left behind is ended before the stop is confirmed" and "a runner that will not end means no confirmed stop" |
| G7 | Each attempt reserves once, releases once, and is charged at most once per UTC day | append-only ledger; unique `(attempt, kind, day)`; ledger guard and lifecycle triggers; deferred `inference_attempts_settled` | "the ledger settles each attempt once, and only a finished one"; the killed-caller race test (a duplicate charge from another connection is refused) |
| G8 | Daily occupancy is bounded; occupancy crossing midnight is charged to both days; pending work is capped | admission checks charged plus open reservations; charge split by UTC day | "the budget refuses admission once today's occupancy is spent"; "occupancy crossing midnight is charged to both UTC days"; "the pending-work cap refuses admission"; `BenchTest` "an interval is charged to each UTC day it touches" |
| G9 | Only a refused connection (never sent) is retried, at most twice, the database's bound | `Runtime.Ollama` `retry: false`; the retry loop in `Runtime.run/3`; `Attempt.max_transport_retries/0` and the `transport_retries` CHECK | `RuntimeTest` "a refused connection is retried twice, then fails before dispatch" and "configuration may retry less than the database allows, never more"; `GatewayTest` "the retry ceiling is the database's: up to it is recorded, one more is refused"; `ReadinessTest` "a refused connection was never sent; a timeout is uncertain; an error answer is an answer" |
| G10 | Memory pressure, swap growth or repeated runtime failures pause the service until an operator resumes it | `Runtime.System` samples; pause rules | "memory pressure refuses and pauses; swap growth during a call pauses after it"; "three runtime failures in a row pause the service until an operator resumes it"; "a validation refusal is an answer, not a runtime failure" |
| P1 | A packet is bounded: at most 12 candidates and 12 meanings by the recorded cut (packet v2, below), bounded excerpts, an estimated prompt within context minus reserved output. An oversized excerpt or prompt is refused, never trimmed | `Packet.for_page/2`, `Packet.freeze/2`, `Packet.fits?/2` | `PacketTest` "limits that need no registry refuse at freeze"; "excerpts are cut at a word boundary, never rewritten"; `PacketV2ScopeTest` test 4; `RuntimeTest` "an oversized, stale or unready packet is refused before admission" |
| P2 | Every candidate is one the curation screen offers, an exact, current, eligible registry revision; restricted evidence never enters a packet; an entry Bierce-first applies to is in the packet, or there is no packet | `Packet.for_page/2` through `Candidates.for_page/1` (`priority_candidate_unavailable`, `priority_candidates_exceed_cap`); `Packet.verify/1` re-derives every kind before dispatch | "a packet is built from the registry, Bierce first, and frozen under one hash"; "restricted or withdrawn evidence never enters a packet"; "a Bierce entry that applies but cannot be a candidate refuses the packet"; "a packet that no longer matches the registry is refused before dispatch"; `PacketV2ScopeTest` tests 1 and 6 |
| P4 | The cut is deterministic and recorded: what it left out is on the packet and the attempt by id and reason, never by text | `Packet.for_page/2`'s `omitted`; `Packet.summary/1` | `PacketV2ScopeTest` tests 3 and 5; `PacketTest` test 2 |
| I1 | The instruction a call is sent under is the one its model config pins, and a pinned text never changes | `Packet.build/3` takes the config's `instruction_version` (no default); `Packet.freeze/2` refuses an unpinned version; `Runtime.run/3` refuses a mismatch before admission; `Runtime.smoke/2` uses the config's | `PacketTest` "each instruction version is held to its text", "September's packets still render the prompts their attempts recorded"; `RuntimeTest` "a packet built for another instruction than the config's is refused before admission", "a config pinned to v2 sends v2, for a request and for its smoke call" |
| P3 | Excerpts are untrusted data; attempts store hashes, ids and a text-free summary, never excerpt text or prompts | prompt rendering; attempt columns | "an attempt keeps ids and hashes, and never the excerpts"; `RuntimeTest` "instructions inside a source excerpt stay data: obeying them is refused" |
| C1 | Output is bounded, parseable, exactly shaped, and free of tool calls; emitted reasoning is measured as a length and never kept | `Contract.validate/3` | `ContractTest` "malformed, oversized, truncated or tool-calling output is refused"; "extra keys, wrong types and more than three highlights are refused"; "emitted reasoning is measured as a length and never kept" |
| C2 | Every id is from the packet, every meaning is allowed for its candidate, and every quote is an exact substring of its excerpt, kept as a hash and a byte range | `Contract.validate/3` | "fabricated ids, wrong meanings, fabricated quotes and duplicates are refused"; "a sound selection is accepted, and its quote kept as a hash and a range" |
| C3 | The selection is still eligible at validation time, and Bierce-first applies | `Curation.Eligibility`, `Curation.LeadRule` | "evidence restricted after the packet was frozen is refused at validation"; "Bierce first applies: another definition cannot lead where Bierce applies" |
| R1 | Readiness refuses with a stable reason, and never downloads or creates directories | `Runtime.Readiness` | `ReadinessTest`: "a missing or internal drive refuses before anything is asked of the service"; "an unreachable service, another version or a missing model refuses"; "a quarantined or paused slot refuses" |
| R2 | The served model is the pinned artifact on the external models root | `/api/tags` digest equals the pinned manifest digest, which equals the sha256 of the manifest file under the root | "a served tag that moved to another artifact refuses, and nothing is pulled"; "a served manifest that is not the one on the external root refuses" |
| — | Nothing public is written | `Runtime.run/3` writes attempts and ledger entries only | `RuntimeTest` "a packet gets a validated result, a receipt and accounting, and nothing public" |

## Packet v2

`runtime-packet-v2` (#262, under #253 §5a) is what a P6 editor will be offered. A packet
v1 offered Bierce's entries, the other definitions and the sense quotations, and refused
more than 12 candidates or 12 meanings; love's whole On scope (five words, 43 senses, 48
packet meanings) could never be sent. v2:

- **Offers what the screen offers.** `Packet.for_page/2` reads `Curation.Candidates.for_page/1`,
  the owner's curation screen's own seam, so the packet holds the page's definitions,
  current senses' quotations, Saved catalog shelf (`work`) and accepted exemplars
  (`exemplar`), each only while it may be shown, and a definition as the screen shows it,
  by its entry's first block. A candidate the screen lists but cannot offer never enters a
  packet. Poems and books are not offered, because the screen offers none (#253 D6).
- **Cuts deterministically.** Every applicable Bierce entry is in, counted against the
  `content` quota; more of them than that quota, the cap or the meaning bound admits
  refuses the packet (`{:priority_candidates_exceed_cap, n}`). Each kind is then filled
  up to its quota in source-priority order (Bierce, Johnson, WordNet, Wiktionary,
  Wikipedia, any other; a verified corpus before a live one; exemplars by the date of
  their acceptance), ties by object id. A kind's unused quota flows to the next kind in
  `content, sense_quotation, work, exemplar` order and never back, so a page with no works
  can leave places empty while a quotation is cut.
- **Bounds meanings.** Every chosen candidate's meaning is kept; a candidate whose meaning
  no longer fits is omitted (`meaning_out_of_bound`) and its place goes to the next of its
  kind. The places left go to the other meanings by how many of the page's candidates
  cite them, then by rank on the page (the words, then the senses), then by id. Every
  candidate may be tied only to the meaning the screen offers it under: the screen draws a
  stored item by its candidate's key and saves it under that candidate's spec, so any other
  meaning would not survive an owner's Take. The other meanings are context.
- **Records its cut.** `omitted` lists every offered candidate not sent, by screen key,
  kind, object id and reason (`over_quota`, `meaning_out_of_bound`, `meaning_unavailable`,
  `no_excerpt`). `Packet.summary/1`, the attempt's `packet_summary`, keeps it with the
  instruction, the policy and the counts (#253 D9).
- **Re-derives every kind before dispatch.** `Packet.verify/1` builds the page again in the
  cut's order of words and asks the screen again: a candidate it no longer offers under the
  same item spec is `not_offered`, a definition or quotation it shows differently is
  `excerpt_changed`, and a changed set of applicable Bierce entries is `priority_changed`; a
  work's
  catalog checksum (`catalog_changed`), an exemplar's acceptance (`claim_not_accepted`)
  and the review context that accepted it (`claim_context_changed`) are checked by
  `Curation.Eligibility`; a work's or an exemplar's label must be the same.
- **Has no quote for a work or an exemplar.** They carry a `label` (title, creator and
  date; what the subject is and its name), and the contract refuses a quote on one
  (`quote_not_allowed`). A quotation's quote must still be an exact substring.
- **Is what the refresh clock compares.** `Packet.digest/1`, the cut by ids, revisions and
  hashes without the instruction or the omitted list, is the candidate half of P5's
  fingerprint under version `packet-v2/<cut policy>/<meaning policy>`, with meanings named
  by what they are, so a sense added elsewhere on the page renumbers them without changing
  it. A stored `candidates-v1` fingerprint, or one of another policy version, re-admits its
  page once and then settles. A candidate eligible outside the cut changes the fingerprint
  only where it changes what is sent (a new quotation can raise its sense into a free
  meaning place).

The quotas, bounds, source order and the two policy versions (`cut-v1`, `meanings-v2`)
are code defaults in `Runtime.Endpoint`, configuration-overridable. A changed policy
should name a new version, which is what re-admits the pilot pages. The September
benchmark's packets are `runtime-packet-v1` and still freeze to their hashes and verify
by v1's rules, so they were not re-frozen; `bench seed` keeps a plan's packet that is
already there while it verifies, and refuses to re-freeze one in its place.
`mix dd.runtime packet --scope SLUG --dry-run --instruction V` prints the cut for an On page
and writes nothing.

## Operating limits

These are configuration defaults (`:devils_dictionary, :curation_runtime`). They are
limits, not measurements.

| Limit | Default | Why |
|---|---|---|
| Per-call deadline | 120 s | #195 |
| Reservation per call | deadline + 5 s | occupancy of one call cannot exceed it before a timeout |
| Daily occupancy budget | 30 min, UTC | #195 |
| Pending-work cap | 30 units, 1 per unsettled attempt | #195 (the panel reserves per composition and claim later) |
| Candidates per packet | 12, cut by quota: `content 4, sense_quotation 3, work 3, exemplar 2` | #195, #253 §5a |
| Meanings per packet | 12; every chosen candidate's meaning kept | #253 §5a |
| Excerpt | 1,200 characters, cut at a word boundary | keeps 12 candidates inside 8K context |
| Context / output | `num_ctx` 8192, `num_predict` 1024 (thinking included) | #195 |
| Transport retries | 2, connection refused only; configuration may lower it, never raise it (the CHECK's bound) | #195, #221 A1 |
| Pause | 3 consecutive runtime failures; swap growth ≥ 512 MB during a call; memory free < 10% | #195 "pause on memory pressure" |

## Deferred

- **#197:** runs, participants, rounds, ballots, decisions and the panel-decision
  publication authority. Attempts here carry no run or participant id, and none is
  invented.
- **#198:** scheduling, refresh and warm-window automation.
- **#101:** assessor and embedding models.

Promoting a model config into a panel-ready configuration version is a later, reviewed
configuration change. It is not done here.
