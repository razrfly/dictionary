defmodule Mix.Tasks.Dd.Report do
  @moduledoc """
  Shared printing for the `dd.*` tasks: a label/value row, thousands separators
  and a duration.

  Every task prints numbers (#69 §5), and the first four grew their own copies
  of `fmt/1` and `fmt_ms/1`. `dd.score` needs a fifth and a table besides, so
  they live here once instead.

  Not a `Mix.Task` despite the namespace — it has no `run/1` and never appears
  in `mix help`.
  """

  @doc "Writes a line."
  def say(line), do: Mix.shell().info(line)

  @doc "Writes a highlighted line — a threshold missed, a count that wants to be zero."
  def warn(line), do: Mix.shell().error(line)

  @doc "An indented `label   value` row, padded to `width`."
  def row(label, value, width \\ 26) do
    say("  #{String.pad_trailing(to_string(label), width)} #{fmt(value)}")
  end

  @doc "Thousands separators for integers; anything else passes through."
  def fmt(n) when is_integer(n) and n < 0, do: "-" <> fmt(-n)

  def fmt(n) when is_integer(n) do
    n
    |> Integer.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  def fmt(other), do: to_string(other)

  @doc "Milliseconds as something a person reads."
  def fmt_ms(ms) when ms < 1_000, do: "#{ms} ms"
  def fmt_ms(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)} s"
  def fmt_ms(ms), do: "#{div(ms, 60_000)}m #{rem(div(ms, 1000), 60)}s"

  @doc "`n / total (pct%)`, with the zero-total case spelled out rather than divided."
  def ratio(_part, 0), do: "0 / 0"
  def ratio(part, total), do: "#{fmt(part)} / #{fmt(total)} = #{pct(part, total)}%"

  @doc "One decimal place, and 0.0 rather than a division by zero."
  def pct(_part, 0), do: 0.0
  def pct(part, total), do: Float.round(part * 100 / total, 1)

  @doc "Turns a map's atom keys into strings, for `import_runs.stats` (jsonb)."
  def stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
