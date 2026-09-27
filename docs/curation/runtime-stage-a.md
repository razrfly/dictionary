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
| Service process | `Runtime.ServiceProcess` | Start, stop (the confirmed stop recovery needs) and status of the one private `ollama serve`. A recorded pid counts only while it runs the configured binary, so a pid reused after a reboot is never signalled |
| Slot authority | `Runtime.Authority` (`<run_dir>/authority.json`) | The one database, cluster and service key whose slot row governs the physical service |
| Checks | `Runtime.Readiness` | Slot, volume, models root, authority, runtime version, served digest, manifest on the models root |
| Contracts | `Runtime.Packet`, `Runtime.Contract` | The frozen input and the validated output |
| Coordination | `Runtime.Gateway` | Admission, dispatch, completion, quarantine, sweep, recovery, pause and resume |
| Entry point | `Runtime.run/3` and `mix dd.runtime` | Readiness → packet check → admission → dispatch → validation → settlement |
| Benchmark | `Runtime.Bench`, `priv/curation/runtime_bench/` | The predeclared plan, its frozen packets, and the runner. A cold sample runs only after a confirmed unload; otherwise it is reported as not measured |

Operating the service is in [runtime-operations.md](runtime-operations.md). The measured
benchmark is in [runtime-benchmark-2026-09-27.md](runtime-benchmark-2026-09-27.md).

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
   may be retried, at most twice, on the same attempt.
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
| G4 | A result is accepted only from the current holder under its fence; stale, late or duplicate results are refused | completion checks holder, fence and state under the row lock | "a result is accepted once, from the holder under its fence"; `GatewayRaceTest` "a caller that dies mid-generation leaves the slot held until a confirmed stop" (its late completion is stale) |
| G5 | A timeout, crash or expired lease after dispatch quarantines; it frees and refunds nothing | `dispatched` committed before send; `uncertain` handling; lease sweep | "a timeout after dispatch quarantines the service, frees nothing and refunds nothing"; "an expired admitted lease releases the slot; an expired dispatched lease quarantines it"; `RuntimeTest` "a timeout after dispatch quarantines the service; the next caller is refused" |
| G6 | Recovery requires a confirmed stop of the service process, settles once, and holds the slot until resume | `Gateway.recover/2` takes the stop confirmation; epoch bump; paused until `resume` | "a confirmed stop settles the uncertain attempt once and holds the slot until resume"; the killed-caller race test; `RuntimeTest` "recovery stops nothing unless this database owns a quarantined slot" |
| G7 | Each attempt reserves once, releases once, and is charged at most once per UTC day | append-only ledger; unique `(attempt, kind, day)`; ledger guard and lifecycle triggers; deferred `inference_attempts_settled` | "the ledger settles each attempt once, and only a finished one"; the killed-caller race test (a duplicate charge from another connection is refused) |
| G8 | Daily occupancy is bounded; occupancy crossing midnight is charged to both days; pending work is capped | admission checks charged plus open reservations; charge split by UTC day | "the budget refuses admission once today's occupancy is spent"; "occupancy crossing midnight is charged to both UTC days"; "the pending-work cap refuses admission"; `BenchTest` "an interval is charged to each UTC day it touches" |
| G9 | Only a refused connection (never sent) is retried, at most twice | `Runtime.Ollama` `retry: false`; the retry loop in `Runtime.run/3` | `RuntimeTest` "a refused connection is retried twice, then fails before dispatch"; `ReadinessTest` "a refused connection was never sent; a timeout is uncertain; an error answer is an answer" |
| G10 | Memory pressure, swap growth or repeated runtime failures pause the service until an operator resumes it | `Runtime.System` samples; pause rules | "memory pressure refuses and pauses; swap growth during a call pauses after it"; "three runtime failures in a row pause the service until an operator resumes it"; "a validation refusal is an answer, not a runtime failure" |
| P1 | A packet is bounded: at most 12 candidates, bounded excerpts, an estimated prompt within context minus reserved output. Oversized packets are refused, never trimmed | `Packet.freeze/2`, `Packet.fits?/2` | `PacketTest` "limits refuse; they never trim the packet"; "excerpts are cut at a word boundary, never rewritten"; `RuntimeTest` "an oversized, stale or unready packet is refused before admission" |
| P2 | Every candidate is an exact, current, eligible registry revision; restricted evidence never enters a packet; an entry Bierce-first applies to is in the packet, or there is no packet | `Packet.build/3` (`priority_candidate_unavailable`); `Packet.verify/1` re-checks with `Curation.Eligibility` before dispatch | "a packet is built from the registry, Bierce first, and frozen under one hash"; "restricted or withdrawn evidence never enters a packet"; "a Bierce entry that applies but cannot be a candidate refuses the packet"; "a packet that no longer matches the registry is refused before dispatch" |
| P3 | Excerpts are untrusted data; attempts store hashes, ids and a text-free summary, never excerpt text or prompts | prompt rendering; attempt columns | "an attempt keeps ids and hashes, and never the excerpts"; `RuntimeTest` "instructions inside a source excerpt stay data: obeying them is refused" |
| C1 | Output is bounded, parseable, exactly shaped, and free of tool calls; emitted reasoning is measured as a length and never kept | `Contract.validate/3` | `ContractTest` "malformed, oversized, truncated or tool-calling output is refused"; "extra keys, wrong types and more than three highlights are refused"; "emitted reasoning is measured as a length and never kept" |
| C2 | Every id is from the packet, every meaning is allowed for its candidate, and every quote is an exact substring of its excerpt, kept as a hash and a byte range | `Contract.validate/3` | "fabricated ids, wrong meanings, fabricated quotes and duplicates are refused"; "a sound selection is accepted, and its quote kept as a hash and a range" |
| C3 | The selection is still eligible at validation time, and Bierce-first applies | `Curation.Eligibility`, `Curation.LeadRule` | "evidence restricted after the packet was frozen is refused at validation"; "Bierce first applies: another definition cannot lead where Bierce applies" |
| R1 | Readiness refuses with a stable reason, and never downloads or creates directories | `Runtime.Readiness` | `ReadinessTest`: "a missing or internal drive refuses before anything is asked of the service"; "an unreachable service, another version or a missing model refuses"; "a quarantined or paused slot refuses" |
| R2 | The served model is the pinned artifact on the external models root | `/api/tags` digest equals the pinned manifest digest, which equals the sha256 of the manifest file under the root | "a served tag that moved to another artifact refuses, and nothing is pulled"; "a served manifest that is not the one on the external root refuses" |
| — | Nothing public is written | `Runtime.run/3` writes attempts and ledger entries only | `RuntimeTest` "a packet gets a validated result, a receipt and accounting, and nothing public" |

## Operating limits

These are configuration defaults (`:devils_dictionary, :curation_runtime`). They are
limits, not measurements.

| Limit | Default | Why |
|---|---|---|
| Per-call deadline | 120 s | #195 |
| Reservation per call | deadline + 5 s | occupancy of one call cannot exceed it before a timeout |
| Daily occupancy budget | 30 min, UTC | #195 |
| Pending-work cap | 30 units, 1 per unsettled attempt | #195 (the panel reserves per composition and claim later) |
| Candidates per packet | 12 | #195 |
| Excerpt | 1,200 characters, cut at a word boundary | keeps 12 candidates inside 8K context |
| Context / output | `num_ctx` 8192, `num_predict` 1024 (thinking included) | #195 |
| Transport retries | 2, connection refused only | #195 |
| Pause | 3 consecutive runtime failures; swap growth ≥ 512 MB during a call; memory free < 10% | #195 "pause on memory pressure" |

## Deferred

- **#197:** runs, participants, rounds, ballots, decisions and the panel-decision
  publication authority. Attempts here carry no run or participant id, and none is
  invented.
- **#198:** scheduling, refresh and warm-window automation.
- **#101:** assessor and embedding models.

Promoting a model config into a panel-ready configuration version is a later, reviewed
configuration change. It is not done here.
