defmodule DevilsDictionary.Curation.ShelfFocus do
  @moduledoc "Deterministic bounded shelf rotation, frozen per generation (#270 L9)."
  alias DevilsDictionary.Curation.Shelf

  def order(queue, generation, requested, slots) do
    by_kind = Enum.group_by(queue, & &1.packet["shelf"]["shelf_kind"])
    present = Enum.filter(Shelf.kinds(), &Map.has_key?(by_kind, &1))

    focus =
      if requested,
        do: to_string(requested),
        else: if(present != [], do: Enum.at(present, rem(generation, length(present))))

    primary = Map.get(by_kind, focus, []) |> Enum.sort_by(& &1.sort)

    offset =
      if primary == [] or present == [],
        do: 0,
        else: rem(div(generation, length(present)) * slots, length(primary))

    rotated = Enum.drop(primary, offset) ++ Enum.take(primary, offset)

    kinds =
      if focus in present,
        do:
          Enum.drop(present, Enum.find_index(present, &(&1 == focus)) + 1) ++
            Enum.take(present, Enum.find_index(present, &(&1 == focus))),
        else: []

    borrowed =
      if length(primary) < slots,
        do:
          kinds
          |> Enum.flat_map(&(Map.get(by_kind, &1, []) |> Enum.sort_by(fn c -> c.sort end)))
          |> Enum.take(slots - length(primary)),
        else: []

    offered = rotated ++ borrowed
    keys = MapSet.new(offered, & &1.packet["key"])
    excluded = Enum.reject(queue, &MapSet.member?(keys, &1.packet["key"]))

    {offered, excluded,
     %{
       "focus" => focus,
       "source" => if(requested, do: "requested", else: "rotation"),
       "generation" => generation,
       "offset" => offset,
       "slots" => slots
     }}
  end
end
