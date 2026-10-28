defmodule DevilsDictionary.Curation.Proposals do
  @moduledoc """
  The proposal path (#264): the generic editor proposes into the owner's
  screen through the same record the owner uses, and the owner takes,
  edits or dismisses what it proposed. **No bot operation moves the
  published pointer; an explicit human Take or Edit-publish may**, with the
  quality form and the existing compare-and-switch.

  **The step (R3–R9).** `step/3` is an editor step inside a claimed refresh
  run (`Refresh.check/3` hands it the claim while the editor is enabled),
  never a job of its own. In order:

    1. the page's packet is built under the binding's instruction and
       frozen (a refusal completes the run `needs_editor` /
       `packet_refused`);
    2. a pending proposal from the same packet, kept marks and parent
       completes the run `proposed` / `pending`, with no call;
    3. an attempt already under the generation's key on another packet is
       drift: the generation closes and nothing is proposed (R4.4);
    4. a review unit is reserved (`Refresh.reserve/2`); at the cap the run
       is deferred `review_capacity`;
    5. the frozen packet goes to `Runtime.run/3` as the bot actor, under
       the key `proposal:<composition>:<configuration version>:<generation>`;
    6. the result is mapped exactly as R6's table says: an accepted answer
       is merged with the owner's kept items (`Proposals.Merge`) and
       written by `Compositions.write_proposal/2` with its proposal row, in
       one fenced transaction (`Refresh.write/4`); an abstention completes
       `abstained`; every answerless or refused outcome is deferred.

  **The owner's acts (R10–R12).** `take/3`, `edit_publish/3` and
  `dismiss/3`, each a reviewer's, each one transaction. Take and
  Edit-publish write a manual version parented to the proposal
  (`Compositions.take_version/3`), accept it and publish it with the
  compare-and-switch, and need the complete quality form
  (`Proposals.QualityForm`); Dismiss is a `rejected` review with its reason.

  **Review units (R5):** `units_in_use/0`, pending proposals plus reserved
  refresh rows, against `Refresh.review_units/0`. There is no counter to
  drift: a proposal holds its unit while pending, a row while its stamp is
  set.

  Nothing here calls `Reviews` or `Publications` on the editor's behalf:
  only `take/3` and `edit_publish/3` do, as the signed-in reviewer.
  """

  import Ecto.Query

  alias DevilsDictionary.Curation.{
    Authority,
    Composition,
    CompositionItem,
    CompositionMembership,
    CompositionVersion,
    Compositions,
    Configuration,
    ConfigurationVersion,
    Configurations,
    Digest,
    Eligibility,
    Proposal,
    Publications,
    Refresh,
    RefreshState,
    Reviews,
    Transaction
  }

  alias DevilsDictionary.Curation.Proposals.{Merge, QualityForm}
  alias DevilsDictionary.Curation.Runtime
  alias DevilsDictionary.Curation.Runtime.{Attempt, ModelConfig, Packet}
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Registry.Lexeme
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Actor

  @doc """
  The request key of a generation's attempt (#264 R4.1). The configuration
  version is in it because generations restart under each configuration
  version's row, and keys are unique across every attempt.
  """
  def request_key(composition_id, configuration_version_id, generation),
    do: "proposal:#{composition_id}:#{configuration_version_id}:#{generation}"

  # ── the step ─────────────────────────────────────────────────────────────

  @doc """
  The editor step of a claimed run (#264 R3). `ctx` is `%{slug, inputs,
  editor}`: the On page the run is for, the inputs `Refresh.inputs/2` read,
  and the binding (`Configurations.editor_enabled/1`). `opts`: `:runtime`
  (the runtime's options: a service key, a fake host, in tests), `:now`,
  `:jitter`.

  Answers what the `Refresh` function that moved the row answers: `{:ok,
  row}` (completed, deferred or closed), or `{:error, :lease_lost |
  :configuration_changed}` when the fence was lost and nothing was written.
  """
  def step(claim, %{slug: slug, inputs: inputs, editor: editor} = ctx, opts) do
    page = slug |> Lexicon.lookup() |> WordPage.build(viewer: :public)

    with {:ok, packet} <-
           Packet.for_page(page,
             instruction_version: editor.instruction_version,
             generation: claim.generation,
             shelf: Map.get(claim, :shelf_focus)
           ),
         {:ok, frozen} <- Packet.freeze(packet) do
      frozen_step(claim, ctx, frozen, opts)
    else
      {:error, reason} ->
        Refresh.complete(
          claim,
          inputs,
          Keyword.put(opts, :outcome, {:needs_editor, "packet_refused:" <> refusal(reason)})
        )
    end
  end

  defp frozen_step(claim, ctx, frozen, opts) do
    key = request_key(claim.composition_id, claim.configuration_version_id, claim.generation)
    row = Repo.get!(RefreshState, claim.row_id)
    composition = Repo.get!(Composition, claim.composition_id)

    cond do
      pending_same?(composition, frozen.hash, row.admitted_parent_version_id) ->
        Refresh.complete(claim, ctx.inputs, Keyword.put(opts, :outcome, {:proposed, "pending"}))

      drifted?(key, frozen.hash) ->
        Refresh.close(claim, opts)

      true ->
        case Refresh.reserve(claim, opts) do
          {:ok, _row} -> call(claim, ctx, frozen, key, opts)
          {:deferred, row} -> {:ok, row}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # R6 row 2: the proposal the owner has not reviewed yet already answers
  # this packet, these marks and this parent. Nothing is called.
  defp pending_same?(composition, packet_hash, parent) do
    case pending(composition.id) do
      %Proposal{} = p ->
        p.packet_hash == packet_hash and p.marks_digest == marks_digest(composition.kept_items) and
          p.published_parent_version_id == parent

      nil ->
        false
    end
  end

  # R4.4: the generation's attempt was made from another packet. Checked
  # before calling the runtime, which would refuse `:idempotency_conflict`,
  # so it needs no running service.
  defp drifted?(key, packet_hash) do
    case Repo.get_by(Attempt, request_key: key) do
      nil -> false
      attempt -> attempt.packet_hash != packet_hash
    end
  end

  defp call(claim, ctx, frozen, key, opts) do
    runtime =
      opts
      |> Keyword.get(:runtime, [])
      |> Keyword.merge(request_key: key, actor_id: ctx.editor.bot_actor.id, purpose: :request)

    case Runtime.run(ctx.editor.model_config, frozen, runtime) do
      {:ok, receipt} -> answered(claim, ctx, frozen, key, receipt, opts)
      {:replay, receipt} -> answered(claim, ctx, frozen, key, receipt, opts)
      {:uncertain, _receipt} -> defer(claim, "uncertain", opts)
      {:refused, :stale} -> defer(claim, "stale", opts)
      {:refused, reason} -> defer(claim, refusal(reason), opts)
    end
  end

  # R6's mapping of an attempt's answer. A refused, unknown or missing
  # answer spends the generation (R4.5): the next admission opens another.
  defp answered(claim, ctx, frozen, key, receipt, opts) do
    case receipt do
      %{state: :completed, outcome: :accepted} ->
        write(claim, ctx, frozen, key, Repo.get!(Attempt, receipt.attempt_id), opts)

      %{state: :completed, outcome: :abstained} ->
        Refresh.complete(
          claim,
          ctx.inputs,
          Keyword.put(opts, :outcome, {:abstained, "abstained"})
        )

      %{state: :completed, outcome: outcome} ->
        defer(claim, to_string(outcome), opts)

      %{state: state} ->
        defer(claim, to_string(state), opts)
    end
  end

  defp defer(claim, reason, opts), do: Refresh.fail(claim, reason, opts)

  defp refusal(reason) when is_atom(reason), do: to_string(reason)
  defp refusal({reason, _detail}) when is_atom(reason), do: to_string(reason)
  defp refusal(reason) when is_binary(reason), do: reason
  defp refusal(reason), do: inspect(reason)

  # ── the write (R7–R9) ─────────────────────────────────────────────────────

  defp write(claim, ctx, frozen, key, attempt, opts) do
    result =
      Refresh.write(claim, ctx.inputs, opts, fn row, composition ->
        cv = Repo.get!(ConfigurationVersion, claim.configuration_version_id)

        plan(
          %{claim: claim, ctx: ctx, frozen: frozen, key: key, attempt: attempt},
          row,
          composition,
          cv
        )
      end)

    case result do
      {:ok, {row, _value}} -> {:ok, row}
      {:error, reason} when reason in [:lease_lost, :configuration_changed] -> {:error, reason}
      {:error, reason} -> defer(claim, refusal(reason), opts)
    end
  end

  # Everything R7.6 and R8 check, then the write. Answers what
  # `Refresh.write/4` takes from its function.
  defp plan(run, row, composition, cv) do
    %{ctx: %{editor: editor}, frozen: frozen, attempt: attempt} = run
    members = Compositions.member_ids(composition.id)

    with :ok <- binding_holds(cv, editor, attempt, run.key),
         :ok <- same_scope(composition, frozen),
         {:ok, choices} <- resolve(attempt, frozen),
         :ok <- choices_eligible(choices, frozen, members),
         {carried, marks} = carried(composition, row.admitted_parent_version_id, members),
         merged = Merge.arrange(carried, choices, cv.max_highlights),
         :ok <- model_placed(merged),
         placed = placed(merged),
         items = Compositions.proposal_arrangement(placed, editor.bot_actor),
         :ok <- merge_holds(items, members, composition, cv),
         :ok <- not_published(items, composition),
         arrangement = Digest.arrangement_hash(items),
         :ok <- not_dismissed(composition.id, frozen.hash, arrangement),
         {:ok, version} <-
           Compositions.write_proposal(editor, %{
             composition: composition,
             configuration_version: cv,
             attempt: attempt,
             items: placed
           }) do
      proposal =
        insert!(%{
          run: run,
          row: row,
          composition: composition,
          version: version,
          marks: marks,
          overflow: merged.overflow
        })

      reason = if proposal.superseded_on_arrival, do: "superseded_on_arrival", else: "written"
      {:complete, {:proposed, reason}, proposal}
    end
  end

  # R7.6: the claim's binding still stands, and the attempt is the binding's
  # and the generation's.
  defp binding_holds(cv, editor, attempt, key) do
    case Configurations.editor(cv) do
      {:ok, current}
      when current.profile.id == editor.profile.id and
             current.bot_actor.id == editor.bot_actor.id and
             current.model_config.id == attempt.model_config_id and
             attempt.request_key == key and attempt.requested_by_actor_id == editor.bot_actor.id ->
        :ok

      _changed ->
        {:error, :editor_binding_changed}
    end
  end

  # The packet was cut for exactly these words: a scope changed since is an
  # input change, and the generation closes.
  defp same_scope(composition, frozen) do
    ids = get_in(frozen.packet, ["target", "lexeme_ids"]) || []

    if Compositions.signature(ids) == composition.scope_signature,
      do: :ok,
      else: {:close, :scope_changed}
  end

  @doc false
  # R7.1–R7.5: every chosen candidate and meaning resolved through the
  # frozen packet, never through what the registry offers now, and checked
  # against the summary the attempt kept. The model's quote stays on the
  # attempt: it is never an item's `words_sha256`, nor text.
  def resolve(%Attempt{result: result, packet_summary: summary}, frozen) do
    packet = frozen.packet
    candidates = Map.new(packet["candidates"], &{&1["candidate_id"], &1})
    meanings = Map.new(packet["meanings"], &{&1["meaning_id"], &1})
    kept = Map.new((summary || %{})["candidates"] || [], &{&1["candidate_id"], &1})

    lead = if result["lead"], do: [{:lead, 1, result["lead"]}], else: []

    highlights =
      (result["highlights"] || [])
      |> Enum.with_index(1)
      |> Enum.map(fn {h, n} -> {:highlight, n, h} end)

    Enum.reduce_while(lead ++ highlights, {:ok, %{lead: nil, highlights: []}}, fn
      {role, position, choice}, {:ok, acc} ->
        with {:ok, candidate} <-
               Transaction.need(candidates[choice["candidate_id"]], :unknown_candidate),
             {:ok, meaning} <- Transaction.need(meanings[choice["meaning_id"]], :unknown_meaning),
             :ok <- summarized(candidate, kept[candidate["candidate_id"]]),
             {:ok, item} <- item(candidate, meaning, role, position, choice["reason"]) do
          entry = entry(item, candidate["candidate_id"])

          acc =
            if role == :lead,
              do: %{acc | lead: entry},
              else: %{acc | highlights: acc.highlights ++ [entry]}

          {:cont, {:ok, acc}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  # The summary on the attempt is the audit record: every reference it kept
  # (with each quotation's `words_sha256`, R7.3) must be the packet's.
  defp summarized(_candidate, nil), do: {:error, :summary_mismatch}

  defp summarized(candidate, summarized) do
    if Enum.all?(summarized, fn {k, v} -> candidate[k] == v end),
      do: :ok,
      else: {:error, :summary_mismatch}
  end

  # R7.4: an item by kind, from the frozen candidate.
  defp item(candidate, meaning, role, position, reason) do
    base = %{
      role: role,
      position: position,
      item_object_id: candidate["object_id"],
      selection_origin: :model,
      note: reason
    }

    meaning_fields =
      case meaning do
        %{"kind" => "lexeme", "lexeme_id" => id} ->
          %{meaning_lexeme_id: id, meaning_sense_revision_id: nil}

        %{"kind" => "sense_revision", "sense_revision_id" => id} ->
          %{meaning_sense_revision_id: id, meaning_lexeme_id: nil}
      end

    kind_fields =
      case candidate do
        %{"kind" => "content"} ->
          {:ok, %{item_kind: :content, content_revision_id: candidate["content_revision_id"]}}

        %{"kind" => "sense_definition"} ->
          {:ok,
           %{
             item_kind: :sense_definition,
             sense_revision_id: candidate["sense_revision_id"],
             words_sha256: candidate["words_sha256"]
           }}

        %{"kind" => "claim"} ->
          {:ok,
           %{
             item_kind: :claim,
             assertion_revision_id: candidate["assertion_revision_id"],
             basis: candidate["basis"]
           }}

        %{"kind" => "shelf", "shelf" => %{} = shelf} ->
          {:ok, %{item_kind: :work, source_record_revision_id: shelf["revision"], shelf: shelf}}

        %{"kind" => "sense_quotation"} ->
          {:ok,
           %{
             item_kind: :sense_quotation,
             sense_revision_id: candidate["sense_revision_id"],
             locator: candidate["locator"],
             words_sha256: candidate["words_sha256"]
           }}

        # The only work shape the packet builds on `main`: a catalog row. A
        # work without one waits for P3's brief (#268 re-audit R1).
        %{"kind" => "work", "catalog" => %{"manifest" => m, "checksum" => c, "identity" => i}}
        when is_binary(m) and is_binary(c) and is_binary(i) ->
          {:ok,
           %{item_kind: :work, catalog_manifest: m, catalog_checksum: c, catalog_identity: i}}

        %{"kind" => "work"} ->
          {:error, :unsupported_work_reference}

        %{"kind" => "exemplar"} ->
          {:ok,
           %{
             item_kind: :exemplar,
             assertion_revision_id: candidate["assertion_revision_id"],
             content_revision_id: candidate["content_revision_id"]
           }}
      end

    with {:ok, kind_fields} <- kind_fields do
      {:ok, struct(CompositionItem, base |> Map.merge(kind_fields) |> Map.merge(meaning_fields))}
    end
  end

  defp entry(%CompositionItem{} = item, candidate_id) do
    %{
      ref: Compositions.reference(item),
      identity: Compositions.display_identity(item),
      exemplar?: item.item_kind == :exemplar,
      candidate_id: candidate_id,
      item: item
    }
  end

  # R7.6: an item the editor chose that is not eligible now (superseded,
  # withdrawn, its meaning gone) closes the generation.
  defp choices_eligible(choices, frozen, members) do
    candidates = Map.new(frozen.packet["candidates"], &{&1["candidate_id"], &1})
    meanings = frozen.packet["meanings"]

    ineligible =
      Enum.reject(List.wrap(choices.lead) ++ choices.highlights, fn entry ->
        candidate = candidates[entry.candidate_id]
        meaning = Enum.find(meanings, &same_meaning?(&1, entry.item))
        meaning && Packet.check(candidate, meaning, members) == :ok
      end)

    if ineligible == [], do: :ok, else: {:close, :chosen_item_ineligible}
  end

  defp same_meaning?(%{"kind" => "lexeme", "lexeme_id" => id}, item),
    do: item.meaning_lexeme_id == id

  defp same_meaning?(%{"kind" => "sense_revision", "sense_revision_id" => id}, item),
    do: item.meaning_sense_revision_id == id

  # R8.1: each kept mark whose exact reference is an item of the
  # generation's admitted parent, and still eligible, is carried; the others
  # are listed with why not. Read here, in the write's transaction, under the
  # composition's lock: a mark set during the call is honoured (R8.5).
  defp carried(composition, parent_id, members) do
    {parent_items, contexts} =
      case parent_id && Repo.get(CompositionVersion, parent_id) do
        %CompositionVersion{} = parent ->
          {Compositions.items(parent.id), (parent.resolution || %{})["claim_contexts"] || %{}}

        nil ->
          {[], %{}}
      end

    results =
      for mark <- composition.kept_items do
        ref = Compositions.reference(mark["reference"] || %{})

        case Enum.find(parent_items, &(Compositions.reference(&1) == ref)) do
          nil ->
            {:not, mark, "not_in_parent"}

          item ->
            case Eligibility.check(item, members, contexts) do
              :ok -> {:carry, mark, item}
              {:error, reason} -> {:not, mark, to_string(reason)}
            end
        end
      end

    carried_items =
      for {:carry, _mark, item} <- results, do: item

    lead = Enum.find(carried_items, &(&1.role == :lead))

    highlights =
      carried_items |> Enum.filter(&(&1.role == :highlight)) |> Enum.sort_by(& &1.position)

    marks =
      Enum.map(results, fn
        {:carry, mark, item} ->
          %{"key" => mark["key"], "carried" => true, "item_id" => item.id, "reason" => nil}

        {:not, mark, reason} ->
          %{"key" => mark["key"], "carried" => false, "item_id" => nil, "reason" => reason}
      end)

    {%{lead: lead && entry(lead, nil), highlights: Enum.map(highlights, &entry(&1, nil))}, marks}
  end

  defp model_placed(%{model?: true}), do: :ok
  defp model_placed(_merged), do: {:complete, {:no_change, "kept_only"}, nil}

  # The merged places as the writer takes them, positions renumbered from
  # 1: an editor's choice is the model's item, a kept one a copy of the
  # parent's.
  defp placed(merged) do
    lead = if merged.lead, do: [place(merged.lead, :lead, 1)], else: []

    highlights =
      merged.highlights
      |> Enum.with_index(1)
      |> Enum.map(fn {e, n} -> place(e, :highlight, n) end)

    lead ++ highlights
  end

  defp place(%{candidate_id: nil, item: item}, role, position),
    do: {:copy, %{item | role: role, position: position}}

  defp place(%{item: item}, role, position),
    do: {:model, %{item | role: role, position: position}}

  # R7.6, R6: the merged arrangement as the manual writer checks one. A
  # refusal here repeats on every retry (same packet, marks and answer), so
  # it is an assessment, `merge_refused`, not an input change.
  defp merge_holds(items, members, composition, cv) do
    evaluation = Eligibility.evaluate(items, members, composition.scope_signature, cv.id)

    cond do
      Compositions.one_display_identity(items) != :ok ->
        {:complete, {:no_change, "merge_refused"}, nil}

      not match?({:ok, _}, evaluation.lead_rule) ->
        {:complete, {:no_change, "merge_refused"}, nil}

      not evaluation.ok? ->
        {:complete, {:no_change, "merge_refused"}, nil}

      true ->
        :ok
    end
  end

  # R8.4: the published version's references in the same places.
  defp not_published(items, %Composition{current_published_version_id: id}) when is_integer(id) do
    if places(Compositions.items(id)) == places(items),
      do: {:complete, {:no_change, "matches_published"}, nil},
      else: :ok
  end

  defp not_published(_items, _composition), do: :ok

  defp places(items) do
    items
    |> Enum.map(fn i ->
      {i.role, i.position, Compositions.reference(i), i.meaning_lexeme_id,
       i.meaning_sense_revision_id}
    end)
    |> Enum.sort()
  end

  # R8.4, #253 §6a: the same arrangement on the same packet as a dismissed
  # proposal is not proposed again.
  defp not_dismissed(composition_id, packet_hash, arrangement) do
    if Repo.exists?(
         from p in Proposal,
           where:
             p.composition_id == ^composition_id and p.state == :dismissed and
               p.packet_hash == ^packet_hash and p.arrangement_hash == ^arrangement
       ),
       do: {:complete, {:no_change, "dismissed_duplicate"}, nil},
       else: :ok
  end

  # R9.3–R9.4: the proposal row, and the older pending one made obsolete in
  # the same transaction, naming this one (OD-6c).
  defp insert!(w) do
    %{run: run, row: row, composition: composition, version: version} = w
    now = DateTime.utc_now()
    %{rows: [[id]]} = Repo.query!("SELECT nextval('curation_proposals_id_seq')")

    case Repo.one(
           from p in Proposal,
             where: p.composition_id == ^composition.id and p.state == :pending,
             lock: "FOR UPDATE"
         ) do
      nil ->
        :ok

      older ->
        older
        |> Ecto.Changeset.change(
          state: :obsolete,
          resolved_at: now,
          resolution_reason: "superseded_by_proposal",
          obsoleted_by_proposal_id: id
        )
        |> Repo.update!()
    end

    Repo.insert!(%Proposal{
      id: id,
      composition_id: composition.id,
      version_id: version.id,
      configuration_version_id: run.claim.configuration_version_id,
      refresh_state_id: row.id,
      refresh_generation: run.claim.generation,
      request_key: run.key,
      model_config_id: run.attempt.model_config_id,
      profile_id: run.ctx.editor.profile.id,
      profile_version_id: run.ctx.editor.profile_version.id,
      packet_hash: run.attempt.packet_hash,
      arrangement_hash: version.arrangement_hash,
      published_parent_version_id: row.admitted_parent_version_id,
      superseded_on_arrival:
        composition.current_published_version_id != row.admitted_parent_version_id,
      marks_digest: marks_digest(composition.kept_items),
      carried: w.marks,
      overflow: w.overflow,
      inserted_at: now
    })
  end

  @doc "The digest of a composition's kept marks: what a proposal was merged with."
  def marks_digest(kept_items) do
    kept_items
    |> List.wrap()
    |> Enum.map(&Digest.term(&1["reference"] || %{}))
    |> Enum.sort()
    |> Digest.term()
  end

  # ── generations and units (R4.3, R5) ─────────────────────────────────────

  @doc """
  Whether a deferred row's generation can still be retried (#264 R4.3 b):
  no attempt under its key yet, or one that completed with an answer to
  write (accepted or abstained). Any other attempt spent the generation.
  """
  def generation_open?(%RefreshState{} = row) do
    key = request_key(row.composition_id, row.configuration_version_id, row.refresh_generation)

    case Repo.get_by(Attempt, request_key: key) do
      nil -> true
      %Attempt{state: :completed, outcome: outcome} -> outcome in [:accepted, :abstained]
      _spent -> false
    end
  end

  @doc """
  The review units in use (#264 R5.1): pending proposals, plus refresh rows
  holding a reservation, over every composition and configuration version.
  """
  def units_in_use do
    # A single statement sees the reservation-to-pending conversion in one
    # snapshot. Two SELECTs can miss both sides of that atomic conversion.
    %{rows: [[units]]} =
      Repo.query!("""
      SELECT (SELECT count(*) FROM curation_proposals WHERE state = 'pending') +
             (SELECT count(*) FROM curation_refresh_states
              WHERE review_unit_reserved_at IS NOT NULL)
      """)

    units
  end

  @doc """
  Makes every pending proposal of a configuration made under another
  version obsolete (`configuration_changed`, #264 R1.4). Called by
  `Configurations.activate/4` in its transaction. Answers the count.
  """
  def obsolete_other_versions(configuration_id, version_id) do
    versions =
      from v in ConfigurationVersion,
        where: v.configuration_id == ^configuration_id and v.id != ^version_id,
        select: v.id

    {count, _} =
      Repo.update_all(
        from(p in Proposal,
          where: p.state == :pending and p.configuration_version_id in subquery(versions)
        ),
        set: [
          state: :obsolete,
          resolved_at: DateTime.utc_now(),
          resolution_reason: "configuration_changed"
        ]
      )

    count
  end

  # ── reads ────────────────────────────────────────────────────────────────

  @doc "A composition's pending proposal, or `nil`."
  def pending(composition_id) do
    Repo.one(
      from p in Proposal, where: p.composition_id == ^composition_id and p.state == :pending
    )
  end

  @doc "The proposal of a model version, or `nil`."
  def for_version(version_id), do: Repo.get_by(Proposal, version_id: version_id)

  @doc """
  Every pending proposal, newest first, for the queue's Proposed tab (#264
  §2.1): `%{proposal, version, composition, attempt_id, proposed_by,
  against}`. `proposed_by` is read from the attempt's model config, never
  written as a literal; `against` is the published parent's version number,
  or `nil`.
  """
  def list_pending do
    proposals =
      Repo.all(from p in Proposal, where: p.state == :pending, order_by: [desc: p.id])

    versions =
      by_id(
        CompositionVersion,
        Enum.flat_map(proposals, &[&1.version_id, &1.published_parent_version_id])
      )

    compositions = by_id(Composition, Enum.map(proposals, & &1.composition_id))
    configs = by_id(ModelConfig, Enum.map(proposals, & &1.model_config_id))

    for p <- proposals do
      version = versions[p.version_id]

      %{
        proposal: p,
        version: version,
        composition: compositions[p.composition_id],
        attempt_id: version.attempt_id,
        proposed_by: proposed_by(configs[p.model_config_id]),
        against: versions[p.published_parent_version_id]
      }
    end
  end

  @doc "Who proposed, as the attempt's model config names it: `\"<instruction> · <slug>\"`."
  def proposed_by(%ModelConfig{} = config), do: Configurations.editor_label(config)
  def proposed_by(_none), do: "an unrecorded editor"

  @doc """
  What the editor's proposal strip shows (#264 §2.2), for a model version:
  `%{proposal, version, items, attempt, model_config, proposed_by, offered,
  candidates_total, omitted, newest?}`, or `nil` when the version is not a
  proposal.
  """
  def view(version_id) do
    with %CompositionVersion{origin: :model} = version <- Repo.get(CompositionVersion, version_id),
         %Proposal{} = proposal <- for_version(version.id) do
      attempt = Repo.get(Attempt, version.attempt_id)
      config = attempt && Repo.get(ModelConfig, attempt.model_config_id)
      summary = (attempt && attempt.packet_summary) || %{}
      counts = summary["counts"] || %{}
      offered = length(summary["candidates"] || [])

      %{
        proposal: proposal,
        version: version,
        items: version.id |> Compositions.items() |> in_place(),
        attempt: attempt,
        model_config: config,
        proposed_by: proposed_by(config),
        offered: offered,
        candidates_total: counts["offered"] || offered,
        omitted: length(summary["omitted"] || []),
        newest?:
          match?(
            %{id: id} when id == version.id,
            Compositions.latest_version(version.composition_id)
          )
      }
    else
      _none -> nil
    end
  end

  # The lead first, then the highlights in their places.
  defp in_place(items), do: Enum.sort_by(items, &{&1.role != :lead, &1.position})

  defp by_id(_schema, []), do: %{}

  defp by_id(schema, ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
    Repo.all(from r in schema, where: r.id in ^ids) |> Map.new(&{&1.id, &1})
  end

  # ── the owner's acts (R10–R12) ───────────────────────────────────────────

  @doc """
  Take as is (#264 R11.2), as a reviewer, in one transaction: a manual
  version parented to the proposal whose items are verified copies of the
  proposal's, accepted with the reviewer's reason and published from the
  pointer the screen saw; then the proposal is `:taken` with its form.

  `opts`: `:reason`, `:expected_pointer` (required), `:answers` and `:note`
  (the quality form, required complete). Refused for a proposal that is not
  pending, not the newest version (`{:stale_parent, newest}`; Dismiss stays
  open), lacking an item the owner keeps now (`{:kept_item_missing, key}`:
  use Edit), or with an incomplete form.
  """
  def take(scope, proposal_id, opts) do
    resolve_by_publication(scope, proposal_id, opts, fn _proposal, items, composition ->
      with :ok <- kept_present(composition, items) do
        {:ok, Enum.map(items, &{:copy, &1.id, &1.role, &1.position})}
      end
    end)
  end

  @doc """
  Edit then publish (#264 R11.3), as a reviewer: as `take/3`, from the
  owner's edited arrangement. `opts` also carry `:lead` (an item spec or
  `nil`) and `:highlights` (item specs, in order), as
  `Compositions.create_version/3` takes them, with `note: %{text: text}`.
  An item kept as offered (the same reference, meaning and note text) is
  written as a copy of the proposal's; an item whose note the owner
  rewrote, or that the owner added, is the owner's; a dropped item is
  dropped.
  """
  def edit_publish(scope, proposal_id, opts) do
    resolve_by_publication(scope, proposal_id, opts, fn _proposal, items, _composition ->
      lead = if spec = Keyword.get(opts, :lead), do: [{spec, :lead, 1}], else: []

      highlights =
        opts
        |> Keyword.get(:highlights, [])
        |> Enum.with_index(1)
        |> Enum.map(fn {spec, n} -> {spec, :highlight, n} end)

      {:ok,
       for {spec, role, position} <- lead ++ highlights do
         case Enum.find(items, &as_offered?(&1, spec)) do
           %CompositionItem{id: id} -> {:copy, id, role, position}
           nil -> {:own, spec, role, position}
         end
       end}
    end)
  end

  defp resolve_by_publication(scope, proposal_id, opts, arrange) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :reviewer),
           {:ok, reason} <- Transaction.required(opts, :reason),
           expected = Keyword.fetch!(opts, :expected_pointer),
           {:ok, proposal} <- lock_pending(proposal_id),
           :ok <- newest(proposal),
           items = Compositions.items(proposal.version_id),
           :ok <-
             DevilsDictionary.Curation.ProviderText.validate(
               [
                 reason,
                 opts[:note],
                 get_in(opts[:lead] || %{}, [:note, :text]),
                 Enum.map(opts[:highlights] || [], &get_in(&1, [:note, :text]))
               ],
               items,
               fixed_reason: reason == "dismissed_by_owner"
             ),
           {:ok, form} <- form(items, opts, actor, :required),
           composition = Repo.get!(Composition, proposal.composition_id),
           {:ok, specs} <- arrange.(proposal, items, composition),
           {:ok, version} <-
             Compositions.take_version(scope, proposal.version_id, %{
               reason: reason,
               items: specs,
               quality_note: opts[:note]
             }),
           {:ok, _review} <-
             Reviews.decide(scope, version.id, :accepted,
               reason: reason,
               idempotency_key: key("take-review")
             ),
           {:ok, receipt} <-
             Publications.publish(scope, version.id,
               reason: reason,
               idempotency_key: key("take-publish"),
               expected_pointer: expected
             ) do
        proposal =
          proposal
          |> Ecto.Changeset.change(
            state: :taken,
            resolved_at: DateTime.utc_now(),
            resolved_by_actor_id: actor.id,
            resolution_reason: reason,
            resolution_version_id: version.id,
            quality_form: form
          )
          |> Repo.update!()

        {:ok, %{proposal: proposal, version: version, receipt: receipt}}
      end
    end)
  end

  @doc """
  Dismiss (#264 R12), as a reviewer, in one transaction: a `rejected`
  review of the proposal version with the reviewer's reason (required),
  and the proposal `:dismissed` with the review, the reason and the form if
  one was filled (complete, or absent; a partial form is refused). Offered
  whether or not the proposal is still the newest version (OD-6d). The
  proposal keeps the arrangement and packet hashes the next run compares
  (R8.4).
  """
  def dismiss(scope, proposal_id, opts) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :reviewer),
           {:ok, reason} <- Transaction.required(opts, :reason),
           {:ok, proposal} <- lock_pending(proposal_id),
           items = Compositions.items(proposal.version_id),
           :ok <-
             DevilsDictionary.Curation.ProviderText.validate(
               [
                 reason,
                 opts[:note],
                 get_in(opts[:lead] || %{}, [:note, :text]),
                 Enum.map(opts[:highlights] || [], &get_in(&1, [:note, :text]))
               ],
               items,
               fixed_reason: reason == "dismissed_by_owner"
             ),
           {:ok, form} <- form(items, opts, actor, :optional),
           {:ok, review} <-
             Reviews.decide(scope, proposal.version_id, :rejected,
               reason: reason,
               idempotency_key: key("dismiss")
             ) do
        {:ok,
         proposal
         |> Ecto.Changeset.change(
           state: :dismissed,
           resolved_at: DateTime.utc_now(),
           resolved_by_actor_id: actor.id,
           resolution_reason: reason,
           resolution_review_id: review.id,
           quality_form: form
         )
         |> Repo.update!()}
      end
    end)
  end

  # The composition first, then the proposal: the order the editor's write
  # takes them (composition, refresh row, proposals), and publications and
  # withdrawals take theirs (Stage 0 check, recommendation 1), so a Take and
  # a proposal landing together never deadlock.
  defp lock_pending(id) do
    with {:ok, %Proposal{composition_id: composition_id}} <-
           Transaction.need(Repo.get(Proposal, id), :not_found),
         {:ok, _composition} <-
           DevilsDictionary.Curation.Standing.lock_composition(composition_id) do
      case Repo.one(from p in Proposal, where: p.id == ^id, lock: "FOR UPDATE") do
        %Proposal{state: :pending} = p -> {:ok, p}
        %Proposal{state: state} -> {:error, {:proposal_resolved, state}}
      end
    end
  end

  # R11.1: Take and Edit-publish are offered only while the proposal is the
  # page's newest version (OD-6d). `Compositions.take_version/3` checks it
  # again under the composition's lock.
  defp newest(proposal) do
    case Compositions.latest_version(proposal.composition_id) do
      %{id: id} when id == proposal.version_id -> :ok
      newest -> {:error, {:stale_parent, newest && newest.id}}
    end
  end

  defp form(items, opts, actor, need) do
    case QualityForm.build(items, Keyword.get(opts, :answers), Keyword.get(opts, :note), actor.id) do
      {:ok, nil} when need == :required -> {:error, :quality_form_incomplete}
      other -> other
    end
  end

  # R11.2: every item the owner keeps now, and could carry (an item of the
  # published version, still eligible), is in the proposal.
  defp kept_present(composition, items) do
    members = Compositions.member_ids(composition.id)

    published =
      case composition.current_published_version_id do
        nil -> []
        id -> Compositions.items(id)
      end

    missing =
      Enum.find(composition.kept_items, fn mark ->
        ref = Compositions.reference(mark["reference"] || %{})
        source = Enum.find(published, &(Compositions.reference(&1) == ref))

        carriable? = source && Eligibility.check(source, members) == :ok
        carriable? && not Enum.any?(items, &(Compositions.reference(&1) == ref))
      end)

    if missing, do: {:error, {:kept_item_missing, missing["key"]}}, else: :ok
  end

  # The same reference, meaning and note text as a proposal item.
  defp as_offered?(%CompositionItem{} = item, spec) do
    probe = probe(spec)

    probe != nil and Compositions.same_reference?(probe, item) and
      probe.meaning_lexeme_id == item.meaning_lexeme_id and
      probe.meaning_sense_revision_id == item.meaning_sense_revision_id and
      trimmed(get_in(spec, [:note, :text])) == trimmed(item.note)
  end

  defp probe(%{kind: :exemplar} = spec) do
    case Repo.get(DevilsDictionary.Claims.AssertionRevision, spec[:assertion_revision_id]) do
      nil ->
        nil

      claim ->
        struct(
          CompositionItem,
          Map.merge(
            %{
              item_kind: :exemplar,
              item_object_id: claim.subject_object_id,
              assertion_revision_id: claim.id,
              content_revision_id: spec[:content_revision_id] || exemplar_words(claim)
            },
            meaning_of(spec[:meaning])
          )
        )
    end
  end

  defp probe(spec), do: DevilsDictionary.Curation.Candidates.probe(spec)

  defp exemplar_words(%{subject_kind: "content", subject_object_id: id}) do
    case DevilsDictionary.Registry.current_content_revision(id) do
      %{id: revision_id} -> revision_id
      nil -> nil
    end
  end

  defp exemplar_words(_claim), do: nil

  defp meaning_of({:lexeme, id}), do: %{meaning_lexeme_id: id}
  defp meaning_of({:sense_revision, id}), do: %{meaning_sense_revision_id: id}
  defp meaning_of(_none), do: %{}

  defp trimmed(nil), do: nil

  defp trimmed(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  defp key(action), do: "curation-proposal:#{action}:#{Ecto.UUID.generate()}"

  # ── the forms (R11.5) ────────────────────────────────────────────────────

  @doc """
  The quality forms of resolved proposals as Markdown, for posting on #253
  (`mix dd.curation.editor forms`): page, proposal version, attempt, model
  config, each item's answers, the decision and its reason. `opts`:
  `:counted_only` (only forms that count toward the five).
  """
  def export_forms(opts \\ []) do
    proposals =
      Repo.all(
        from p in Proposal,
          where: p.state in [:taken, :dismissed],
          order_by: [asc: p.resolved_at, asc: p.id]
      )
      |> Enum.filter(&(not Keyword.get(opts, :counted_only, false) or QualityForm.counts?(&1)))

    counted = Enum.count(proposals, &QualityForm.counts?/1)

    sections =
      for p <- proposals do
        version = Repo.get!(CompositionVersion, p.version_id)
        items = version.id |> Compositions.items() |> in_place()

        QualityForm.markdown(%{
          page: page_slug(p.composition_id) || "composition #{p.composition_id}",
          proposal: p,
          version: version,
          items: items,
          model_config_label: proposed_by(Repo.get(ModelConfig, p.model_config_id)),
          decision_reason: p.resolution_reason,
          item_label: &item_label/1
        })
      end

    """
    ## Quality forms (#253 §10, #264 R11.5)

    #{length(proposals)} resolved proposals; #{counted} with a complete form, which count toward the five.

    """ <> Enum.join(sections, "\n")
  end

  defp item_label(%CompositionItem{} = item) do
    ref =
      item
      |> Compositions.reference()
      |> Compositions.reference_key()

    who = if item.selection_origin == :model, do: "the editor's", else: "carried, the owner's"
    "#{ref} (#{who})"
  end

  # ── the Health card (R17) ────────────────────────────────────────────────

  @doc """
  The Proposals card's snapshot (#264 R17.3), SELECT-only and absent-data
  safe: it never reaches `Gateway.service!/1`, `Gateway.budget/2`,
  `Readiness`, an HTTP call or a service process, so mounting `/ops/health`
  inserts nothing.

      %{enabled: nil | %{configuration, configuration_version, at, by},
        review_units: %{pending, reserved, cap},
        proposals: %{pending, superseded_on_arrival, taken, dismissed, obsolete},
        today: %{proposed, abstained, no_change, deferred},
        deferred_now: non_neg_integer,
        last_deferral: nil | %{page, error, at, next_retry_at}}
  """
  def health_snapshot(now \\ DateTime.utc_now(), counts \\ nil) do
    by_state =
      Repo.all(from p in Proposal, group_by: p.state, select: {p.state, count(p.id)})
      |> Map.new()

    counts = counts || Refresh.counts(now)

    %{
      enabled: enabled(),
      review_units: %{
        pending: Map.get(by_state, :pending, 0),
        reserved:
          Repo.aggregate(
            from(r in RefreshState, where: not is_nil(r.review_unit_reserved_at)),
            :count
          ),
        cap: Refresh.review_units()
      },
      proposals: %{
        pending: Map.get(by_state, :pending, 0),
        superseded_on_arrival:
          Repo.aggregate(
            from(p in Proposal, where: p.state == :pending and p.superseded_on_arrival),
            :count
          ),
        taken: Map.get(by_state, :taken, 0),
        dismissed: Map.get(by_state, :dismissed, 0),
        obsolete: Map.get(by_state, :obsolete, 0)
      },
      today: %{
        proposed: counts.proposed_today,
        abstained: counts.abstained_today,
        no_change: counts.no_change_today,
        deferred: counts.deferred_today
      },
      deferred_now: counts.deferred_now,
      last_deferral: last_deferral()
    }
  end

  defp enabled do
    query =
      from c in Configuration,
        join: v in ConfigurationVersion,
        on: v.id == c.editor_enabled_version_id and v.id == c.current_version_id,
        left_join: a in Actor,
        on: a.id == c.editor_switched_by_actor_id,
        where: c.state == :enabled,
        order_by: [c.role, c.id],
        limit: 1,
        select: {c, v, a}

    case Repo.one(query) do
      # Enabled as the step sees it: the switch live and the binding still
      # standing (`Configurations.editor_enabled/1`, SELECTs only).
      {c, v, actor} ->
        case Configurations.editor_enabled(v.id) do
          {:ok, _editor} -> enabled_view(c, v, actor)
          :off -> nil
        end

      nil ->
        nil
    end
  end

  defp enabled_view(c, v, actor) do
    %{
      configuration: c.slug,
      configuration_version: v.version,
      at: c.editor_switched_at,
      by: actor && Compositions.author_label(actor)
    }
  end

  # The most recent deferral under a configuration's current version.
  defp last_deferral do
    query =
      from r in RefreshState,
        join: c in Composition,
        on: c.id == r.composition_id,
        join: cc in Configuration,
        on:
          cc.id == c.curation_configuration_id and
            cc.current_version_id == r.configuration_version_id,
        where: r.state == :deferred,
        order_by: [desc_nulls_last: r.last_deferred_at, desc: r.id],
        limit: 1

    case Repo.one(query) do
      nil ->
        nil

      row ->
        %{
          page: page_slug(row.composition_id),
          error: row.last_error,
          at: row.last_deferred_at,
          next_retry_at: row.next_retry_at
        }
    end
  end

  @doc "A composition's page, by its first member word's slug."
  def page_slug(composition_id) do
    Repo.one(
      from m in CompositionMembership,
        join: l in Lexeme,
        on: l.object_id == m.object_id,
        where: m.composition_id == ^composition_id,
        order_by: l.object_id,
        limit: 1,
        select: l.slug
    )
  end
end
