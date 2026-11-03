defmodule DevilsDictionary.Curation.Coverage do
  @moduledoc """
  Bounded read-only pilot coverage from existing attempts and published receipts.
  Historical packet counts and current eligibility are separate snapshots.
  No discovery/model admission, provider text, new persistence or inferred scores.
  """
  import Ecto.Query
  alias DevilsDictionary.{Repo, Lexicon}
  alias DevilsDictionary.Lexicon.WordPage

  alias DevilsDictionary.Curation.{
    Pilot,
    Configurations,
    Compositions,
    CompositionVersion,
    CompositionPublication,
    Receipt,
    WholeEntry
  }

  alias DevilsDictionary.Curation.Digest
  alias DevilsDictionary.Curation.Runtime.{Attempt, LedgerEntry, ModelConfig}

  @omissions ~w(over_quota meaning_out_of_bound meaning_unavailable no_excerpt outside_shelf_focus text_cut_excluded)
  @kinds ~w(content sense_definition sense_quotation work exemplar claim shelf)
  @sections ~w(definitions examples quotes images films music books poems news)

  def read(slug, opts \\ []) do
    if slug in Pilot.autonomous_pages() do
      read_pilot(slug, opts)
    else
      {:error, :outside_pilot}
    end
  end

  defp read_pilot(slug, opts) do
    limit = Keyword.get(opts, :limit, 20)
    from_id = Keyword.get(opts, :from, 1)
    to_id = Keyword.get(opts, :to, 9_223_372_036_854_775_807)

    if is_integer(limit) and limit in 1..100 and is_integer(from_id) and
         is_integer(to_id) and from_id > 0 and to_id >= from_id do
      page = slug |> Lexicon.lookup() |> WordPage.build(viewer: :public)
      lexemes = page.headword.lexemes
      ids = Enum.sort(Enum.map(lexemes, & &1.id))

      attempts =
        if ids == [] do
          []
        else
          Repo.all(
            from a in Attempt,
              where: a.purpose == :request and a.id >= ^from_id and a.id <= ^to_id,
              where:
                fragment(
                  "? #> '{target,lexeme_ids}' <@ ?::jsonb AND jsonb_array_length(? #> '{target,lexeme_ids}') > 0",
                  a.packet_summary,
                  ^ids,
                  a.packet_summary
                ),
              order_by: [desc: a.id],
              limit: ^(limit + 1)
          )
        end

      %{
        report_version: "curation-coverage-v1",
        slug: slug,
        observed_at: DateTime.utc_now(),
        historical_available_inventory: :not_recorded,
        attempt_limit: limit,
        attempts_truncated: length(attempts) > limit,
        attempts: Enum.map(Enum.take(attempts, limit), &attempt/1),
        current_publication: current(slug, lexemes, ids)
      }
    else
      {:error, :invalid_bounds}
    end
  end

  @doc "Safe counts and local selection IDs from a stored attempt, never its reason text."
  def summarize(%Attempt{} = attempt) do
    summary = attempt.packet_summary || %{}
    candidates = summary["candidates"] || []
    omitted = summary["omitted"]

    choices =
      if attempt.outcome in [:accepted, :abstained] and is_map(attempt.result) do
        List.wrap(attempt.result["lead"]) ++ (attempt.result["highlights"] || [])
      end

    by_id = Map.new(candidates, &{&1["candidate_id"], &1})

    %{
      attempt_id: attempt.id,
      state: attempt.state,
      outcome: attempt.outcome,
      attempt_finished_at: attempt.finished_at,
      model_config_id: attempt.model_config_id,
      packet_hash: attempt.packet_hash,
      instruction_version: summary["instruction_version"],
      eligible_pool: get_in(summary, ["counts", "offered"]),
      packet_candidates: length(candidates),
      packet_by_section: Enum.frequencies_by(candidates, &section/1),
      omitted: if(is_list(omitted), do: length(omitted)),
      omitted_by_reason:
        if(is_list(omitted),
          do:
            Enum.frequencies_by(
              omitted,
              fn row -> if row["reason"] in @omissions, do: row["reason"], else: "unknown" end
            )
        ),
      selected: if(is_list(choices), do: length(choices)),
      selected_by_section:
        if(is_list(choices),
          do:
            Enum.frequencies_by(
              choices,
              fn choice -> section(by_id[choice["candidate_id"]] || %{}) end
            )
        ),
      selected_candidate_ids: if(is_list(choices), do: Enum.map(choices, & &1["candidate_id"]))
    }
  end

  # ── comparison batches (#298 C5, C9) ─────────────────────────────────────

  @doc """
  The comparison report of batch `batch_id`, read from its `comparison`
  attempts only: per case (page, case number, snapshot) and arm, the
  attempt id, evidence fingerprint, packet hash, prompt sha256, model config
  id and hash, instruction and cut, the decision, the lead (and whether it
  is the priority candidate, or that the page has none), every proposed
  choice by candidate id with its meaning id, kind, section, reason sha256
  and reason origin (`model`, `rule` for a fixed lead's rule statement, or
  `withheld`), highlights by section and by kind, model-written reason and
  rule-statement counts, the eligible pool, omissions by reason and cost
  (wall ms, tokens, charged ms). A case is `complete` when it has every arm
  the batch ran anywhere, and `matched` when it is complete and arms that
  share a cut share one evidence fingerprint.

  Counts, ids and hashes only: no provider text and no reason text.
  """
  def comparison(batch_id) when is_binary(batch_id) do
    attempts =
      Repo.all(
        from a in Attempt,
          where:
            a.purpose == :comparison and
              fragment("split_part(?, ':', 1) = ?", a.comparison_case, ^batch_id),
          order_by: a.id
      )

    ids = Enum.map(attempts, & &1.id)
    config_ids = attempts |> Enum.map(& &1.model_config_id) |> Enum.uniq()

    configs =
      Repo.all(from c in ModelConfig, where: c.id in ^config_ids) |> Map.new(&{&1.id, &1})

    charged =
      Repo.all(
        from e in LedgerEntry,
          where: e.attempt_id in ^ids and e.kind == :charge,
          group_by: e.attempt_id,
          select: {e.attempt_id, sum(e.amount_ms)}
      )
      |> Map.new()

    rows = Enum.map(attempts, &comparison_row(&1, configs, charged))
    expected = rows |> Enum.map(& &1.arm) |> Enum.uniq() |> Enum.sort()

    cases =
      rows
      |> Enum.group_by(& &1.comparison_case)
      |> Enum.map(fn {case_id, arms} -> comparison_case(case_id, arms, expected) end)
      |> Enum.sort_by(&{page_rank(&1.page), &1.case_number})

    %{
      report_version: "curation-comparison-v1",
      batch: batch_id,
      observed_at: DateTime.utc_now(),
      fingerprint_rule:
        "matched = complete and, within each cut, one evidence fingerprint (#{DevilsDictionary.Curation.Runtime.Packet.fingerprint_scheme()})",
      arms: expected,
      cases: cases,
      totals: Map.new(expected, &{&1, arm_totals(&1, cases)})
    }
  end

  defp page_rank(slug), do: Enum.find_index(Pilot.autonomous_pages(), &(&1 == slug)) || 99

  defp comparison_case(case_id, arms, expected) do
    [_batch, page, n] = String.split(case_id, ":")
    arms = Enum.sort_by(arms, &Enum.find_index(expected, fn label -> label == &1.arm end))

    fingerprints =
      arms
      |> Enum.group_by(& &1.cut, & &1.evidence_fingerprint)
      |> Map.new(fn {cut, prints} -> {cut, Enum.uniq(prints)} end)

    complete = Enum.sort(Enum.map(arms, & &1.arm)) == expected

    %{
      case_id: case_id,
      page: page,
      case_number: String.to_integer(n),
      snapshot: arms |> Enum.map(& &1.snapshot) |> Enum.uniq(),
      complete: complete,
      matched: complete and Enum.all?(Map.values(fingerprints), &(length(&1) == 1)),
      fingerprints_by_cut: fingerprints,
      arms: arms
    }
  end

  defp comparison_row(%Attempt{} = a, configs, charged) do
    summary = a.packet_summary || %{}
    candidates = summary["candidates"] || []
    by_id = Map.new(candidates, &{&1["candidate_id"], &1})
    priority = summary["priority_candidates"] || []
    result = if is_map(a.result), do: a.result, else: %{}
    lead = result["lead"]
    highlights = result["highlights"] || []

    choices =
      Enum.map(
        List.wrap(lead && {lead, "lead"}) ++ Enum.map(highlights, &{&1, "highlight"}),
        &choice_row(&1, by_id)
      )

    highlight_rows = Enum.filter(choices, &(&1.role == "highlight"))
    config = configs[a.model_config_id]
    metrics = a.metrics || %{}
    omitted = summary["omitted"]

    %{
      arm: a.arm,
      comparison_case: a.comparison_case,
      snapshot: a.comparison_snapshot,
      attempt_id: a.id,
      state: a.state,
      outcome: a.outcome,
      decision: result["decision"] || (a.outcome && to_string(a.outcome)),
      refusal_reasons: a.refusal_reasons,
      evidence_fingerprint: a.evidence_fingerprint,
      packet_hash: a.packet_hash,
      prompt_sha256: a.prompt_sha256,
      model_config_id: a.model_config_id,
      model_config_hash: config && config.config_hash,
      instruction_version: summary["instruction_version"],
      cut: get_in(summary, ["policy", "cut"]),
      eligible_pool: get_in(summary, ["counts", "offered"]),
      packet_candidates: length(candidates),
      packet_by_section: Enum.frequencies_by(candidates, &section/1),
      omitted: if(is_list(omitted), do: length(omitted)),
      omitted_by_reason:
        if(is_list(omitted),
          do:
            Enum.frequencies_by(omitted, fn row ->
              if row["reason"] in @omissions, do: row["reason"], else: "unknown"
            end)
        ),
      priority_candidates: priority,
      fixed_lead: summary["fixed_lead"],
      lead: lead && Enum.find(choices, &(&1.role == "lead")),
      lead_is_priority:
        cond do
          priority == [] -> nil
          is_map(lead) -> lead["candidate_id"] in priority
          true -> false
        end,
      choices: choices,
      highlights: length(highlight_rows),
      highlights_by_section: Enum.frequencies_by(highlight_rows, & &1.section),
      highlights_by_kind: Enum.frequencies_by(highlight_rows, & &1.kind),
      model_written_reasons: Enum.count(choices, &(&1.reason_origin == "model")),
      rule_statements: Enum.count(choices, &(&1.reason_origin == "rule")),
      withheld_reasons: Enum.count(choices, &(&1.reason_origin == "withheld")),
      cost: %{
        wall_ms: metrics["wall_ms"],
        prompt_tokens: metrics["prompt_eval_count"],
        output_tokens: metrics["eval_count"],
        charged_ms: charged[a.id]
      }
    }
  end

  defp choice_row({choice, role}, by_id) do
    candidate = by_id[choice["candidate_id"]] || %{}

    %{
      role: role,
      candidate_id: choice["candidate_id"],
      meaning_id: choice["meaning_id"],
      kind: candidate["kind"],
      section: section(candidate),
      reason_sha256: is_binary(choice["reason"]) && Digest.sha256(choice["reason"]),
      reason_origin:
        cond do
          choice["reason_origin"] == "rule" -> "rule"
          is_nil(choice["reason"]) -> "withheld"
          true -> "model"
        end
    }
  end

  defp arm_totals(label, cases) do
    rows = for c <- cases, row <- c.arms, row.arm == label, do: {c, row}
    sum = fn f -> rows |> Enum.map(fn {_c, r} -> f.(r) || 0 end) |> Enum.sum() end

    %{
      cases: length(rows),
      matched_cases: Enum.count(rows, fn {c, _r} -> c.matched end),
      decisions: Enum.frequencies_by(rows, fn {_c, r} -> r.decision end),
      lead_is_priority: Enum.frequencies_by(rows, fn {_c, r} -> inspect(r.lead_is_priority) end),
      highlights: sum.(& &1.highlights),
      highlights_by_section:
        Enum.reduce(rows, %{}, fn {_c, r}, acc ->
          Map.merge(acc, r.highlights_by_section, fn _k, a, b -> a + b end)
        end),
      model_written_reasons: sum.(& &1.model_written_reasons),
      rule_statements: sum.(& &1.rule_statements),
      wall_ms: sum.(& &1.cost.wall_ms),
      prompt_tokens: sum.(& &1.cost.prompt_tokens),
      output_tokens: sum.(& &1.cost.output_tokens),
      charged_ms: sum.(& &1.cost.charged_ms)
    }
  end

  defp section(candidate) do
    if candidate["kind"] in @kinds do
      result = WholeEntry.section(candidate)
      if result in @sections, do: result, else: "unknown"
    else
      "unknown"
    end
  end

  defp attempt(row) do
    config = Repo.get(ModelConfig, row.model_config_id)

    publications =
      Repo.all(
        from v in CompositionVersion,
          join: p in CompositionPublication,
          on: p.published_version_id == v.id and p.action == :publish,
          where: v.attempt_id == ^row.id,
          distinct: true,
          order_by: v.id,
          select: %{version_id: v.id, version: v.version, composition_id: v.composition_id}
      )

    summarize(row)
    |> Map.put(:model_config_hash, config && config.config_hash)
    |> Map.put(
      :publication_versions,
      Enum.map(publications, fn version ->
        Map.put(version, :placed_items, length(Compositions.items(version.version_id)))
      end)
    )
  end

  defp current(_slug, [], _ids), do: %{status: :no_scope, items: []}

  defp current(slug, [first | _], ids) do
    with {:ok, %{configuration: configuration}} <- Configurations.resolve_default(),
         composition when not is_nil(composition) <-
           Compositions.active(
             configuration.id,
             :lexical_page,
             first.language,
             Compositions.signature(ids)
           ),
         id when is_integer(id) <- composition.current_published_version_id,
         version <- Repo.get!(CompositionVersion, id),
         {:ok, receipt} <- Receipt.read(slug, version.version) do
      items =
        Enum.map(receipt.items, fn item ->
          %{
            item_id: item.id,
            role: item.role,
            position: item.position,
            kind: item.kind,
            status: item.status,
            status_reason: reason_code(item.status_reason),
            original_attempt_id: item.chooser.attempt_id,
            original_model_config_id: item.chooser.model_config_id
          }
        end)

      %{
        status: :published,
        composition_id: composition.id,
        version_id: version.id,
        version: version.version,
        placed: length(items),
        by_status: Enum.frequencies_by(items, & &1.status),
        items: items
      }
    else
      _ -> %{status: :no_current_publication, items: []}
    end
  end

  defp reason_code(nil), do: nil
  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_code(reason) when is_tuple(reason),
    do:
      reason
      |> Tuple.to_list()
      |> Enum.filter(&is_atom/1)
      |> Enum.map_join(":", &Atom.to_string/1)

  defp reason_code(_), do: "withheld"
end
