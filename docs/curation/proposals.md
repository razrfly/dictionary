# Curation proposals: the editor proposes, the owner disposes

The operating notes for [#264](https://github.com/razrfly/dictionary/issues/264) (P6 of
[#254](https://github.com/razrfly/dictionary/issues/254)): how the generic editor's
proposals reach the owner's screen, how a proposal window is run, and how it is rolled
back. The rules are #264 §4 (R1–R19); this page says how to operate them. The model
service itself is [runtime-operations.md](runtime-operations.md)'s, run with
`mix dd.runtime`.

**No bot operation moves the published pointer.** The editor writes a proposal: a model
version with its attempt, never accepted and never published (the code and the database
refuse both). Only the owner's Take or Edit-publish, with the quality form and the
compare-and-switch, publishes anything.

## The pieces

| What | Where |
|---|---|
| The editor's identity | the `generic-editor` source (a bot, inactive, not counted on the home page), its bot actor labelled `"<instruction> · <model config slug>"`, and the `generic-editor` profile, admitted from an empty version (R2) |
| The binding | a configuration version whose manifest names the profile, its version, its bot actor, the model config and its hash, and the instruction (R1.1). Its mode stays `manual` |
| The switch | `curation_configurations.editor_enabled_version_id`, separate from activation: the editor runs only while it equals the current version (R1.5). Every activation leaves it behind, so the editor is off after one until it is enabled again |
| The step | inside a claimed refresh run: a check that finds an editor is needed, while the editor is on, freezes the page's packet, reserves a review unit and calls the runtime as the bot (R3–R5) |
| The proposal | `curation_proposals`, one pending per page: `taken`, `dismissed` or `obsolete`, once (R10) |
| The owner's screen | the queue's Proposed tab, the proposal strip on the page's editor (Take, Edit then publish, Dismiss, the quality form), the D8 marks, Request (R11–R15, R18) |
| The audit | `/ops/curation/attempts/:id`, reviewer-only and 404 through the tunnel: what the editor was offered and what it answered, by ids and hashes (R16) |
| The Health card | "Proposals" on `/ops/health`, below the runtime card: the switch, review units, proposals by state, today's assessments and the last deferral (R17) |

## The live steps

Each is `DD_NO_OBAN=1 mix dd.curation.editor <command> --as <reviewer email> --reason
<text>`, with `--dry-run` to see what it would do. Each write is a live step of #264 §10
(#268 Stages 3c–3d) and waits for the owner's yes.

1. `seed --model-config <slug>`: the source, bot actor, profile and its empty version.
2. `admit`: the editor admitted under the narrow rule.
3. `bind --model-config <slug>`: a new configuration version binding them. It is not
   active.
4. `activate --version <n>`: the binding becomes current. **Every version made under
   the previous configuration version stops standing** (`:configuration_changed`):
   re-publish each page it showed in the same sitting, from the screen (OD-3). Pending
   proposals of the previous version become obsolete.
5. `provision --slug <slug>` for each page that has no composition yet.
6. The window (OD-8): start the service (`mix dd.runtime service start`, `ready`), then
   `enable`. `request --slug <slug>` asks for one page's proposal; the server's own
   queue runs it. The owner reviews it on the page's editor and fills the quality
   form. At the end, `disable`, then stop the service and confirm the stop.
7. `forms`: the resolved proposals' quality forms, as Markdown for #253 §10.

Between windows the editor is off: a check completes as P5's does ("checked, not
judged"), and the next window uses Request or the 48-hour window.

## What a run can come to (R6)

| Result | The page's clock |
|---|---|
| A proposal written | `proposed` / `written` (or `superseded_on_arrival` when the owner published during the call); next assessment in 48 hours |
| The editor abstained | `abstained`; nothing written; next assessment in 48 hours |
| Nothing to change | `no_change` / `kept_only`, `matches_published`, `dismissed_duplicate` or `merge_refused` |
| No packet could be built | `needs_editor` / `packet_refused:<reason>` |
| The service down, the slot busy or paused, the budget spent, the review units at their cap (30) | deferred with backoff, freshness untouched, the generation kept |
| No answer, an uncertain call, an answer refused by validation | deferred with backoff; the generation is spent and the next run opens another |
| The inputs moved under the attempt, or a chosen item became ineligible | the run closes its generation, dirty, and the next visit admits another |

A deferral never delays a reader: the call is in the worker, never in a request.

## Rollback (R19.3)

**Before the editor's configuration version is activated** (#268 3c), "revert the code"
means moving the Studio checkout back to #267's recorded deployment SHA, the one it ran
before this issue's, on the owner's yes. It does not mean a revert commit deployed by
fast-forward (Stage 0 check, recommendation 6): deployment is pinned to recorded SHAs
(#264 §11), and a revert commit would be a new, unchecked head. One request then
recompiles; no restart. The migration stays: it is additive, and the earlier code reads
every row it can write. Its `down` refuses to run once any model version, proposal or
copied item exists.

**After the first model row**, the rollback is `disable`: the editor stops proposing,
pending proposals stay where they are for the owner, and the code stays. The earlier
code cannot read `origin: :model`, `selection_origin: :model` or the new outcomes.
