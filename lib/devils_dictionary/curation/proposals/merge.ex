defmodule DevilsDictionary.Curation.Proposals.Merge do
  @moduledoc """
  The arrangement a proposal carries (#264 R8.3, O2, OD-6a): the owner's
  kept items and the editor's choices, merged inside one lead and the
  configuration version's highlights. Pure: it decides places and reads
  nothing.

  Each entry is a map with:

    * `:ref`, the item's exact reference (what it shows, not why);
    * `:identity`, its display identity (`Compositions.display_identity/1`,
      C6) and the legacy-named exemplar? flag, meaning any item guarded by the shared C6 predicate (exemplar, claim, sense definition or shelf);
    * `:candidate_id` for an editor's choice, `nil` for a kept item.

  The rules, in order:

    1. a kept (carried) lead takes the lead; the editor's lead, if it is
       another item, goes to `overflow`;
    2. kept highlights take the first places, in the parent's order;
    3. the editor's highlights fill the remaining places, up to
       `max_highlights`, in the editor's order, skipping any that shows the
       same thing as an item already placed (the same reference, or the C6
       display identity where the shared C6 predicate applies); the rest go to
       `overflow`, by candidate id;
    4. an editor's choice equal to a kept item becomes the kept item: it is
       placed once, as the owner's;
    5. positions are renumbered from 1.

  Answers `%{lead, highlights, overflow, model?}`, where `model?` says
  whether any placed item is the editor's (a merge with none proposes
  nothing, `kept_only`).
  """

  @doc "Merges `carried` and `choices` (each `%{lead, highlights}`) under `max_highlights`."
  def arrange(carried, choices, max_highlights) do
    kept = List.wrap(carried.lead) ++ carried.highlights

    {lead, overflow} = lead(carried.lead, choices.lead, kept)

    placed_highlights = Enum.take(carried.highlights, max_highlights)

    {highlights, overflow, omitted} =
      Enum.reduce(choices.highlights, {placed_highlights, overflow, []}, fn choice,
                                                                            {acc, over, omitted} ->
        placed = List.wrap(lead) ++ acc

        cond do
          Enum.any?(kept ++ placed, &same?(&1, choice)) ->
            {acc, over, omitted}

          retained = Enum.find(placed, &shows_same?(&1, choice)) ->
            retained_item = Map.get(retained, :item)
            recommended_item = Map.get(choice, :item)

            record = %{
              "candidate_id" => choice.candidate_id,
              "reference" => choice.ref,
              "selection_reason" => recommended_item && recommended_item.note,
              "kept_candidate_id" => retained.candidate_id,
              "kept_reference" => retained.ref,
              "kept_item_id" => retained_item && retained_item.id,
              "kept_version_id" => retained_item && retained_item.composition_version_id,
              "reason" => "duplicate_display_identity"
            }

            {acc, over, omitted ++ [record]}

          length(acc) < max_highlights ->
            {acc ++ [choice], over, omitted}

          true ->
            {acc, over ++ [choice.candidate_id], omitted}
        end
      end)

    %{
      lead: lead,
      highlights: highlights,
      overflow: overflow,
      omitted: omitted,
      model?: Enum.any?(List.wrap(lead) ++ highlights, &model?/1)
    }
  end

  # A kept lead leads. The editor's lead leads only where nothing was kept
  # there and it is not one of the owner's kept items.
  defp lead(nil, nil, _kept), do: {nil, []}
  defp lead(%{} = carried, nil, _kept), do: {carried, []}

  defp lead(carried, choice, kept) do
    cond do
      Enum.any?(kept, &same?(&1, choice)) -> {carried, []}
      carried -> {carried, [choice.candidate_id]}
      true -> {choice, []}
    end
  end

  @doc "Whether two entries reference the same thing."
  def same?(a, b), do: a.ref == b.ref

  # C6 applies only when the existing shared predicate guards either item.
  defp shows_same?(a, b),
    do: (a.exemplar? or b.exemplar?) and not MapSet.disjoint?(a.identity, b.identity)

  defp model?(entry), do: not is_nil(entry.candidate_id)
end
