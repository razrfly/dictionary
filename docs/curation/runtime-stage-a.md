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
| Model provenance | `Runtime.ModelConfig` (`local_model_configs`) | Immutable: tag, manifest and layer digests, quantization, license digest, template digest, runtime version, generation settings, instruction and output-contract versions |
| Endpoint | `Runtime.Endpoint` (application config) | Operational only: base URL, models root, binary, timeouts. Never on a model config, never a persona property |
| Physical service | `Runtime.Service` (`inference_services`) | The one slot: state, holder, fence, epoch, quarantine and pause reasons |
| Attempts | `Runtime.Attempt` (`inference_attempts`) | Request identity, owner, fence, lifecycle, packet hash, validated result, metrics |
| Accounting | `Runtime.Ledger` (`inference_ledger_entries`) | Append-only reserve, release and charge entries per UTC day |
| Client | `Runtime.Ollama` | Req, nonstreaming `/api/chat` with a JSON-schema `format`, no automatic retries |
| Checks | `Runtime.Readiness`, `Runtime.Volume`, `Runtime.Host` | Mount and external device, service version, served digest, manifest on the models root, memory and swap |
| Contracts | `Runtime.Packet`, `Runtime.Contract` | The frozen input and the validated output |
| Coordination | `Runtime.Gateway` | Admission, dispatch, completion, quarantine, recovery, pause and resume |
| Entry point | `Runtime.run/3` and the `dd.runtime.*` tasks | Readiness → packet check → admission → dispatch → validation → settlement |

## The slot protocol

The authority is PostgreSQL, not a BEAM process. Every caller of the physical service,
on any node, goes through the same `inference_services` row.

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
in `test/devils_dictionary/curation/runtime/`.

| # | Invariant | Enforced by | Test |
|---|---|---|---|
| G1 | At most one live attempt (admitted, dispatched or uncertain) per physical service, across nodes | service row lock; partial unique index `inference_attempts_one_live_per_service` | `GatewayRaceTest` (unboxed, separate connections): two callers, one admitted, fake runtime sees concurrency 1; raw second live insert refused |
| G2 | The holder belongs to the service, and an `occupied` service has a holder | composite FK `(holder_attempt_id, id)`; checks | `GatewayTest` "the slot and its holder" |
| G3 | Admission is idempotent per `request_key`; a different request under a used key is a conflict | unique `request_key`; replay compares the packet hash and model config | "a duplicate request replays its receipt" |
| G4 | A result is accepted only from the current holder under its fence; stale, late or duplicate results are refused | completion checks holder, fence and state under the row lock | "a late result after recovery is refused"; "a duplicate completion is refused" |
| G5 | A timeout, crash or expired lease after dispatch quarantines; it frees and refunds nothing | `dispatched` committed before send; `uncertain` handling; lease sweep | "a timeout after dispatch quarantines the service"; "an expired dispatched lease quarantines, an expired admitted lease releases" |
| G6 | Recovery requires a confirmed stop of the service process, and settles once | `Gateway.recover/2` takes the stop confirmation; ledger uniques | "recovery settles the uncertain attempt once and restores the slot only after readiness" |
| G7 | Each attempt reserves once, releases once, and is charged at most once per UTC day | append-only ledger; unique `(attempt, kind, day)`; transition trigger | "accounting settles once" (unboxed double-settle) |
| G8 | Daily occupancy is bounded; occupancy crossing midnight is charged to both days; no reset loophole | admission checks charged plus open reservations; charge split by UTC day | "budget exhaustion refuses admission"; "occupancy crossing midnight charges both days" |
| G9 | Only a confirmed pre-dispatch connection failure is retried, at most twice | `Runtime.Ollama` `retry: false`; gateway retry loop | "connection refused is retried twice, then fails pre-dispatch" |
| G10 | Memory pressure, swap growth or repeated runtime failures pause the service until an operator resumes it | `Runtime.Host` samples; pause rules | "swap growth pauses"; "three runtime failures pause"; "resume" |
| P1 | A packet is bounded: at most 12 candidates, bounded excerpts, an estimated prompt within context minus reserved output. Oversized packets are refused, never silently trimmed of the target meaning | `Packet.freeze/1` limits | `PacketTest` limits |
| P2 | Every candidate is an exact, current, eligible registry revision. Its excerpt hashes to the revision text, and restricted evidence never enters a packet | `Packet.verify/1` re-checks with `Curation.Eligibility` before dispatch | "a stale or restricted candidate refuses the packet" |
| P3 | Excerpts are untrusted data; attempts store hashes, ids and locators, never excerpt text or prompts | prompt rendering; attempt columns | "no prompt or excerpt text is persisted" |
| C1 | Output is bounded, parseable, exactly shaped, and free of tool calls and reasoning | `Contract.validate/2` | `ContractTest` malformed, oversized, extra keys, tool calls, thinking |
| C2 | Every id is from the packet, every meaning is allowed for its candidate, and every quote is an exact substring of its excerpt | `Contract.validate/2` | fabricated id, wrong meaning, fabricated quote |
| C3 | The selection is still eligible at validation time, and Bierce-first applies | `Curation.Eligibility`, `Curation.LeadRule` | "restricted evidence at validation time is refused"; "a non-Bierce lead is refused where Bierce applies" |
| R1 | Readiness refuses with a stable reason, and never downloads or creates directories | `Runtime.Readiness` | `ReadinessTest`: unmounted, internal, unreachable, version, missing model, digest mismatch, manifest not on the root, quarantined, paused |
| R2 | The served model is the pinned artifact on the external models root | `/api/tags` digest equals the pinned manifest digest, which equals the sha256 of the manifest file under the root | "digest mismatch refuses" |

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
