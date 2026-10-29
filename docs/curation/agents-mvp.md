# One curator: Phase A of #275

Status: implementation and isolated automated tests only. No deployed persona,
model registration, admission, activation or quality comparison is claimed.
The live acceptance of #271 still precedes live use. Phase B panels, scheduling
and automatic publication are not implemented here.

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

Do not run these against v2 until #271 is accepted and the owner approves the
migration/deployment and each live operation. Read `runtime-operations.md` and
`proposals.md` first. Never start/restart the public server on 4007. All editor
commands require `DD_NO_OBAN=1`. Below, EMAIL and MODEL-CONFIG are placeholders
resolved by the owner/operator, not defaults.

1. Enumerate intervening migrations. Apply this additive persona-author-guard
   migration before deploying this code, after approval. It adds no table or
   configuration row and changes no existing record. It preserves the deployed
   generic/manual writer path. A test-partition up/down/up is checked; down
   reinstates the old future-insert guard, retaining histories. Before a code
   rollback, disable the persona binding and explicitly restore an approved
   manual/generic configuration; this is not an automatic rollback or activation.
2. In an approved model window, register the **already installed** 9B artifact
   under a **new slug**, pinned to `voltaire-selector-v1`, using the existing
   `dd.runtime setup --model <installed tag> --slug <new slug>
   --instruction voltaire-selector-v1 --accept-license` path. Do not use `--pull`.
   Registration talks to the runtime and records provenance; it is not done by
   seeding the persona. Verify license, artifact and generation limits and smoke
   readiness. The old `qwen3.5-9b-v2` row and instruction stay unchanged.
3. Preview, then run approved `dd.curation.editor seed --profile voltaire
   --as EMAIL --model-config MODEL-CONFIG --reason TEXT`. It prepares only an
   inactive bot source, model-labelled bot and unadmitted dossier. Repeat returns
   existing records, not duplicate versions. No model call, binding or activation.
4. Review the dossier. `dd.curation.editor admit --profile voltaire --as EMAIL
   --model-config MODEL-CONFIG --reason TEXT` is a separate reviewer's act.
5. `dd.curation.editor bind --profile voltaire --as EMAIL --model-config
   MODEL-CONFIG --refresh-window 24h --reason TEXT` creates an immutable default
   configuration version only. Activation, enablement and affected-page
   republication follow the existing #271 runbook and remain separate approved
   acts. Seeding/admission/binding never enable the editor.
6. Provision a permitted pilot page if needed, enable only for the approved model
   window, and request through the existing `dd.curation.editor request` path.
   The shared Refresh → Packet → Runtime → Proposals pipeline records the
   actual persona/profile version, model config, attempt, prompt and dates.
7. Review in `/ops/curation`: Take, Edit or Dismiss with the existing quality
   form. A model never publishes. Take/Edit keep original chooser/model lineage
   in the shared reader receipt and record the owner's publication separately.
   Disable the editor and stop the runtime at the end of the approved window.
8. Show a real public receipt and next-day assessment only after approved live
   use. A fixture or fake response is not evidence of editorial quality.

Every command supports `--dry-run`; it starts the application but performs no
command writes. It is not permission to start background work on another host.
Generic seed/admit/bind commands without `--profile` keep their existing behavior.

## Evidence and next gate

`agents/persona_test.exs` exercises sourced/idempotent preparation, no activation,
role refusal, profile/model mismatch, immutable old dossiers, stale admission,
the actual packet/proposal/owner-Take/reader-receipt path with a controlled model
fake, and abstention without publication. Existing proposal lifecycle, expiry,
wrong-ID/injection, review and refresh tests remain the shared protections.

The ten-page quality benchmark is **NOT RUN**: real calls, owner ratings and a
real daily assessment are excluded from this no-activation implementation.
Before calls, freeze #275's five tuning/five held-out packets and scorecard,
respect provider retention, and approve numerical usefulness/review-time gates.
Compare the generic control and persona on identical lawful evidence; include
failures, abstentions, latency, memory and reviewer time. Do not call this lens
better than the generic editor until the dated report supports it.
