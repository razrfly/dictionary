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

  alias DevilsDictionary.Curation.Runtime.{Attempt, ModelConfig}

  @omissions ~w(over_quota meaning_out_of_bound meaning_unavailable no_excerpt outside_shelf_focus)
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
