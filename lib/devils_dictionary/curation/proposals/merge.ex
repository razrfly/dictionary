defmodule DevilsDictionary.Curation.Proposals.Merge do
  @moduledoc """
  The arrangement a proposal carries (#264 R8.3, O2, OD-6a): the owner's
  kept items and the editor's choices, merged inside one lead and the
  configuration version's highlights. Pure: it decides places and reads
  nothing.

  Each entry is a map with:

    * `:ref`, the item's exact reference (what it shows, not why);
    * `:identity`, its display identity (`Compositions.display_identity/1`,
      C6) and `:exemplar?`;
    * `:candidate_id` for an editor's choice, `nil` for a kept item.

  The rules, in order:

    1. a kept (carried) lead takes the lead; the editor's lead, if it is
       another item, goes to `overflow`;
    2. kept highlights take the first places, in the parent's order;
    3. the editor's highlights fill the remaining places, up to
       `max_highlights`, in the editor's order, skipping any that shows the
       same thing as an item already placed (the same reference, or the C6
       display identity where an exemplar is involved); the rest go to
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

    {highlights, overflow} =
      Enum.reduce(choices.highlights, {placed_highlights, overflow}, fn choice, {acc, over} ->
        placed = List.wrap(lead) ++ acc

        cond do
          Enum.any?(kept ++ placed, &same?(&1, choice)) -> {acc, over}
          Enum.any?(placed, &shows_same?(&1, choice)) -> {acc, over}
          length(acc) < max_highlights -> {acc ++ [choice], over}
          true -> {acc, over ++ [choice.candidate_id]}
        end
      end)

    %{
      lead: lead,
      highlights: highlights,
      overflow: overflow,
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

  # C6: an exemplar never shares its object or words with another item.
  defp shows_same?(a, b),
    do: (a.exemplar? or b.exemplar?) and not MapSet.disjoint?(a.identity, b.identity)

  defp model?(entry), do: not is_nil(entry.candidate_id)
end
