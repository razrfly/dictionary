# One curator: Phase A of #275

Status: implementation and isolated tests only; no autonomous live activation
or real-model quality result is claimed. Owner amendment, 29 October 2026 (#275):
human review is development evaluation, never the routine publication queue.
One explicitly enabled curator can publish through the common record and receive
due assessments without visits. Multiple-agent consensus remains Phase B.
Existing live policy/switches are unchanged until separately approved rollout.

## Reuse, not a new agent system

The first lens is **Inspired by Voltaire**, grounded in *Candide* chapters I,
III and XXX (Project Gutenberg 19942) and the BnF person authority's death
record. The committed dossier names locators, two short character passages,
rights, editorial interpretation, selection principles, examples, blind spot
and abstention. Character dialogue is not a literal historical endorsement.
No new words, definitions, semantic claims or provider queries are generated.

The one JSON manifest is in
`priv/curation/agents/personas/voltaire/v1/profile.json`. `Agents.Persona`
compiles that reviewed lens into the pinned `voltaire-selector-v1` instruction,
appended to the unchanged generic-editor-v2 safety rules. Full dossiers are not
sent to the model. Existing packet cuts and runtime context/output budgets remain
in force. Packet prompt hashes include the lens. The instruction hash regression
requires a new instruction version for changes; do not edit a historical v1 lens.
The database guard also binds this first lens to the exact admitted dossier.

No dynamic plugin system or second orchestration layer is added. Later models
can reuse this instruction through new immutable model configs. New personality
instructions need new sourced manifests, validation and tests, not new gateways.
The current profile has one active bot/model binding; changing it invalidates an
older binding rather than silently reassigning in-flight work.

## Operating sequence (future owner-approved window only)

Live use is the amended #271/#275 acceptance exercise, not something waiting
for a completed manual-review ceremony. It still requires named migration,
deployment, model and activation approval. Read `runtime-operations.md` first.
Never start/restart or reconfigure the public server on 4007. All editor commands
require `DD_NO_OBAN=1` and explicit v2 targeting. EMAIL and MODEL-CONFIG below
mean the existing operator identity and pinned config, not a new account/password.

1. Check the deployed SHA/cluster and enumerate every intervening migration.
   Persona guard `20261029020011` is already live at the current c426c8a pin;
   `20261029142135` adds the single-editor authority. Apply only approved pending
   migrations before deploying the exact reviewed merge. Verify old manual code
   still reads/publishes before deployment. No activation or model start follows
   implicitly from DDL or code deployment.
2. Reuse the admitted generic editor and existing `qwen3.5-9b-v2` config for the
   first autonomous demonstration. Its artifact/instruction/hash stay pinned.
   To compare the already implemented Voltaire lens later, separately register
   the installed artifact under a new `voltaire-selector-v1` model-config slug,
   then seed/admit it using `--profile voltaire`; do not pull another model or
   rewrite the generic config. Dossier admission is setup, not per-entry review.
3. Freeze the ten-page scorecard and permitted evidence, and dry-run binding:
   `dd.curation.editor bind --as EMAIL --model-config MODEL-CONFIG
   --publication single_editor_v1 --refresh-window 24h --reason TEXT --dry-run`.
   Inspect packet dry runs through the existing `dd.runtime packet` command.
   No model answer or publication is fabricated by this preparation.
4. On named approval create that immutable binding without `--dry-run`, then
   activate its exact configuration version. Activation invalidates old-version
   publications and leaves the editor off; it does not republish pages for the
   owner. Provision missing compositions only for the ten approved pilot pages.
   Choose Mine on any page that must remain under owner control.
5. Start/verify the pinned model through the approved runtime window, then
   deliberately enable the editor for the current version. Enable schedules the
   bounded due scan; no browser visit or owner request is needed. Existing Refresh
   workers perform actual assessments sequentially within the shared budget.
6. Inspect the published page and its public receipt. Valid choices publish as
   the actual agent without Take, Edit, acceptance row or quality form. Invalid,
   abstained, stale or offline results are recorded honestly; never publish weak
   or invented output just to obtain a screenshot. Owner editing is optional.
7. Record real publication/expiry/cleanup, the next-due assessment without visits,
   zero unnecessary fresh inference and a hold preventing overwrite, as #271/#275
   require. Developer inspection produces a dated benchmark report, not a runtime
   human approval gate or a general accuracy claim.
8. At the approved window's end, disable the editor and stop the runtime through
   its existing operations. Verify the switch/port and record attempts, receipts,
   costs, dates, deployed SHA and remaining obligations. No automatic expansion.

Every command supports `--dry-run`; it starts the application but performs no
command writes. It is not permission to start background work on another host.
Generic seed/admit/bind commands without `--profile` keep their existing behavior.

## Evidence and next gate

`agents/persona_test.exs` exercises sourced/idempotent preparation, no activation,
role refusal, profile/model mismatch, immutable old dossiers, stale admission,
the optional manual packet/proposal/owner-Take/reader-receipt path with a controlled model
fake, and abstention without publication. Existing proposal lifecycle, expiry,
wrong-ID/injection, review and refresh tests remain the shared protections.

The ten-page quality benchmark is **NOT RUN**: real calls, owner ratings and a
real daily assessment are excluded from this no-activation implementation.
Before calls, freeze #275's five tuning/five held-out packets and scorecard,
respect provider retention, and freeze numerical usefulness gates and record development inspection cost.
Compare the generic control and persona on identical lawful evidence; include
failures, abstentions, latency, memory and reviewer time. Do not call this lens
better than the generic editor until the dated report supports it.


## Single-curator authority (29 October owner amendment)

`Configurations.create_version/3` accepts `editor_publication: "single_editor_v1"`
only with a valid bound editor. Absence means the historical `manual` policy.
CLI: `dd.curation.editor bind --publication single_editor_v1 --refresh-window 24h`
with the existing reviewer identity, pinned model-config and reason arguments.
`--dry-run` prints the proposed policy/window/binding without writing or calling
a model. Binding is not activation; activation resets the run switch. Deliberate
`enable` starts one bounded due-dispatch chain for that version. Every five minutes
it feeds provisioned open pilot pages into existing Refresh admission.
A runtime pilot override can restrict that scan but cannot expand the fixed ten-page
autonomous set; changing enrollment needs a reviewed database/policy amendment. It does not
call a model itself or create a second inference queue. Visits coalesce with it;
backoff, leases, one inference slot and daily budgets still apply. No guarantees
that all pages fit the day's budget; offline/budget failures defer honestly.

An accepted choice goes through the existing packet, exact-reference/eligibility
validation, owner-kept merge, model-version writer and common publication commit
inside Refresh's fenced write. Its receipt says `single_editor`, names the bot
and immutable model/profile/instruction/attempt, and has **no human acceptance
row**. This is not consensus or independent factual corroboration. All item kinds
share the same citation/basis record and read-time eligibility. Public receipts
say automatic publication without human approval; expiry still withholds payloads
without losing permitted citation/provenance. No source content is authored.

Configuration/binding changes, input dirtying, lost lease, owner publication during
a call, ineligible/expired choices or disabled switch veto publication. An unchanged
arrangement completes `no_change`; no duplicate publication. Abstention advances
assessment without a publication; failed/offline calls do not. Automatic publication
records its new baseline, avoiding a self-triggered second inference.

Optional owner controls remain. **Mine** is the persistent page hold: dispatch skips
it and an in-flight answer cannot publish after it is set. **Open** explicitly
releases it. **Keep** protects exact eligible items when later choices are merged;
expiry/rights veto still wins. **Withdraw** suppresses the page until explicit
Re-open and cannot be undone by dispatch. A manual edit alone does not set Mine:
choose Mine if you want a durable freeze. An owner publication during an in-flight
call wins the pointer race. Old versions/receipts and actual contributors survive
replacement. Existing Take/Edit/Dismiss/forms are optional manual-policy tools,
not a prerequisite to running single-editor policy.

Stop: `dd.curation.editor disable` with the normal owner identity/reason arguments,
then separately stop the model through the runtime task. Disabled dispatcher jobs
exit without scheduling successors; a queued/in-flight worker rechecks the switch
and cannot publish afterward. Deliberate enable restarts dispatch. Starting/stopping
the runtime is still an explicit operation, not a side effect of page access.

## Owner editing without a website password

On the Studio, open `http://localhost:4007/ops/curation`. From the MacBook, privately
forward the existing loopback server, then open the forwarded address:

```sh
ssh -N -L 4008:127.0.0.1:4007 holden@192.168.1.15
```

Open `http://localhost:4008/ops/curation`. SSH uses the existing machine access;
the website asks for no password. Keep that Terminal connection open. This does not
restart/reconfigure the server or expose a new network listener on the Studio.

Only exact curation routes on a localhost/loopback request without proxy headers
may use the enabled global configuration's latest activator's existing reviewer identity.
It fails closed if that account no longer has the role. It creates no account,
password, role grant or login token. Signed-in account identities are not replaced.
The connected socket rechecks the private connection and database identity. Other
operator tools acquire no owner capability. Public ngrok cannot obtain this local
identity; its optional authenticated reviewer path remains, and other ops/mailbox
stay blocked. Never remove the public boundary to avoid a local login prompt.

## Rollout and developer experiment

Migration `20261029142135` replaces only publication authority/shape constraints
and the authority trigger. It creates no policy, jobs, accounts, activations or
publications. Existing operator/manual code and receipts remain compatible until
the new policy is activated. After single-editor receipts exist, old readers cannot
decode that enum: disable the editor and roll forward with a reviewed fix. Migration
down refuses while single-editor history exists; never delete that history to undo
an application release. Deploy only the exact reviewed merge, after all intervening
migrations and explicit approval. No server restart/configuration change is needed.

Before real model calls freeze ten pilot cases (five tuning/five held-out), packet
and instruction/model/profile versions, scorecard and budget. Dry-run binding and
packets first. Then separately approve the bounded model/publishing window. Inspect
results as developers, not runtime approvers. Report zero invented quotations or
unauthorized source writes, meaning/relevance/usefulness with denominators and
abstentions, latency/memory/inference cost, and dates/artifact hashes. Proposed gates
are #275's; freeze them before calls and do not fit them to results. Real publication,
public receipt, actual news expiry/cleanup, next-due unattended assessment, fresh
zero-inference repeat and hold behavior are live acceptance, not claimed by tests.
A failed experiment is a dated NO-GO. Keep the model stopped until that window.
