defmodule DevilsDictionary.Curation.WholeEntry do
  @moduledoc "Bounded whole-entry selection and display sections; shared citations, one model call."
  @limits [
    {"definitions", 1},
    {"examples", 2},
    {"quotes", 2},
    {"images", 1},
    {"films", 1},
    {"music", 1},
    {"books", 1},
    {"poems", 1},
    {"news", 1}
  ]
  def sections, do: Enum.map(@limits, &elem(&1, 0))
  def limit(section), do: Map.get(Map.new(@limits), section, 1)
  def instructions, do: ["voltaire-whole-entry-v1", "voltaire-whole-entry-v2"]
  def instruction, do: "voltaire-whole-entry-v2"
  def enabled?(%{manifest: m}), do: m["selection_scope"] == "whole_entry_v1"
  def packet?(%{"packet_version" => "runtime-packet-v4"}), do: true
  def packet?(_), do: false
  def section(%{"kind" => "shelf", "shelf" => %{"shelf_kind" => kind}}), do: kind
  def section(%{"kind" => kind}) when kind in ["content", "sense_definition"], do: "definitions"
  def section(%{"kind" => "sense_quotation"}), do: "quotes"
  def section(%{"kind" => kind}) when kind in ["exemplar", "claim"], do: "examples"
  def section(%{"kind" => "work"}), do: "images"
  def section(%{kind: :shelf, work: %{kind: kind}}), do: kind
  def section(%{kind: :definition}), do: "definitions"
  def section(%{kind: :quotation}), do: "quotes"
  def section(%{kind: kind}) when kind in [:exemplar, :linked_claim], do: "examples"
  def section(%{kind: :poem}), do: "poems"
  def section(%{kind: :book}), do: "books"
  def section(_), do: "images"
  def title("definitions"), do: "Selected definitions"
  def title("examples"), do: "Selected examples"
  def title("quotes"), do: "Selected quotations"
  def title(section), do: "Selected " <> section

  def groups(highlights),
    do:
      for(
        s <- sections(),
        items = Enum.filter(highlights, &(section(&1) == s)),
        do: %{key: s, title: title(s), items: items}
      )

  def shelf_order(queue, generation) do
    groups = Enum.group_by(queue, & &1.packet["shelf"]["shelf_kind"])

    rows =
      for kind <- sections(), group = Map.get(groups, kind, []), group != [] do
        sorted = Enum.sort_by(group, & &1.sort)
        offset = rem(generation, length(sorted))
        Enum.drop(sorted, offset) ++ Enum.take(sorted, offset)
      end

    for index <- 0..(Enum.max(Enum.map(rows, &length/1), fn -> 0 end) - 1),
        row <- rows,
        item = Enum.at(row, index),
        not is_nil(item),
        do: item
  end

  def validate(decoded, packet) do
    if packet?(packet) do
      candidates = Map.new(packet["candidates"], &{&1["candidate_id"], &1})
      choices = Enum.filter(decoded["highlights"], &Map.has_key?(candidates, &1["candidate_id"]))

      lead =
        if is_nil(decoded["lead"]) and decoded["decision"] == "select" and
             Enum.any?(packet["candidates"], &(&1["kind"] in ["content", "sense_definition"])),
           do: [["lead", "definition_required"]],
           else: []

      lead ++
        (choices
         |> Enum.group_by(&section(candidates[&1["candidate_id"]]))
         |> Enum.flat_map(fn {s, items} ->
           if length(items) > limit(s), do: [["section", s <> "_over_limit"]], else: []
         end))
    else
      []
    end
  end

  def item_section(%{item_kind: :work, shelf_citation_id: id}) when is_integer(id),
    do: DevilsDictionary.Curation.ShelfCitations.get(id).shelf_kind

  def item_section(%{item_kind: :work, shelf: shelf}) when is_map(shelf),
    do: shelf[:shelf_kind] || shelf["shelf_kind"]

  def item_section(%{item_kind: kind}), do: section(%{"kind" => to_string(kind)})

  def limit_plan(items) do
    {kept, _} =
      Enum.reduce(items, {[], %{}}, fn
        {:copy, %{role: :lead}} = entry, {kept, counts} ->
          {kept ++ [entry], counts}

        {:model, %{role: :lead}} = entry, {kept, counts} ->
          {kept ++ [entry], counts}

        {origin, item}, {kept, counts} ->
          section = item_section(item)
          count = Map.get(counts, section, 0)

          if count < limit(section),
            do:
              {kept ++
                 [
                   {origin,
                    %{
                      item
                      | position: Enum.count(kept, fn {_, i} -> i.role == :highlight end) + 1
                    }}
                 ], Map.put(counts, section, count + 1)},
            else: {kept, counts}
      end)

    kept
  end

  def coherent?(manifest) do
    whole = manifest["selection_scope"] == "whole_entry_v1"

    instruction =
      case manifest["editor"] do
        editor when is_map(editor) -> editor["instruction_version"]
        _ -> nil
      end

    if whole,
      do: instruction in instructions() and manifest["max_highlights"] == 12,
      else: instruction not in instructions() and manifest["max_highlights"] in 0..3
  end
end
