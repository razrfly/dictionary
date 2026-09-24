defmodule DevilsDictionary.Examples.Rank do
  @moduledoc """
  The one ordering of a word's examples (#181), pure over each item's `layer`
  and `signals` and nothing else.

  Today's rule, as the issue wrote it:

    1. featured exemplars, in featured order;
    2. the other exemplars by `human_up − human_down`, then evidence count;
    3. instances by `source_count` descending, then `best_tier`, then label.

  Then `id` ascending, so two renders of one page agree.

  **Signals never cross layers** (C3). An exemplar is never scored by how many
  sources name it, and an instance is never reordered by a vote: the instance
  clause below reads `source_count`, `best_tier` and the label, and would read
  the same whatever else an item's `signals` carried. That is what lets a
  curation layer later replace *this function* without touching the shape —
  the rule the entry band (#156) codified.

  An item without a `layer` has no clause and raises: it is not an example of
  either kind, and ordering it would be guessing which.
  """

  @tier_rank %{aristocracy: 0, middle: 1, plebs: 2}

  @doc "The items in reading order: exemplars, then instances."
  def order(items) when is_list(items) do
    {exemplars, instances} = Enum.split_with(items, &exemplar?/1)

    Enum.sort_by(exemplars, &exemplar_key/1) ++ Enum.sort_by(instances, &instance_key/1)
  end

  defp exemplar?(%{layer: :exemplar}), do: true
  defp exemplar?(%{layer: :instance}), do: false

  # `false < true`, so a featured exemplar (`is_nil` false) sorts first, and
  # among the featured the earlier feature leads.
  defp exemplar_key(%{signals: s, id: id}) do
    {is_nil(s[:featured_at]), featured_order(s[:featured_at]),
     -((s[:human_up] || 0) - (s[:human_down] || 0)), -(s[:evidence_count] || 0), id}
  end

  defp featured_order(nil), do: 0
  defp featured_order(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)

  defp featured_order(%NaiveDateTime{} = at),
    do: featured_order(DateTime.from_naive!(at, "Etc/UTC"))

  defp instance_key(%{signals: s, subject: subject, id: id}) do
    {-s.source_count, Map.get(@tier_rank, s.best_tier, 3), String.downcase(subject.label || ""),
     id}
  end
end
