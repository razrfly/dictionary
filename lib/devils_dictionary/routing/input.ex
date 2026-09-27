defmodule DevilsDictionary.Routing.Input do
  @moduledoc """
  What the routing API accepts, checked before any query.

  Every routing writer may run inside a caller's batch transaction. A value
  that Ecto cannot cast, Postgrex cannot encode or PostgreSQL refuses to store
  raises there. Once PostgreSQL has refused a statement, the caller's
  transaction can only roll back, even if the exception is rescued. So each
  writer checks its input with these and returns one record's error tuple
  instead:

    * `is_id/1` — a positive integer that fits `bigint`.
    * `text?/1` — nil, or valid UTF-8 without a NUL byte (`text` stores
      neither an invalid sequence nor NUL).
    * `json?/1` — nil, or a map that encodes as JSON with no NUL byte in any
      key or string (`jsonb` refuses `\\u0000`).
  """

  @max 9_223_372_036_854_775_807

  defguard is_id(value) when is_integer(value) and value > 0 and value <= @max

  def text?(nil), do: true

  def text?(value) when is_binary(value),
    do: String.valid?(value) and not String.contains?(value, <<0>>)

  def text?(_value), do: false

  def json?(nil), do: true

  def json?(value) when is_map(value) do
    match?({:ok, _json}, Jason.encode(value)) and not nul?(value)
  rescue
    _error -> false
  end

  def json?(_value), do: false

  # The values themselves, not their encoding: the text `\\u0000` is six
  # ordinary characters, which `jsonb` stores.
  defp nul?(value) when is_binary(value), do: String.contains?(value, <<0>>)
  defp nul?(value) when is_list(value), do: Enum.any?(value, &nul?/1)
  defp nul?(value) when is_map(value), do: Enum.any?(value, fn {k, v} -> nul?(k) or nul?(v) end)
  defp nul?(value) when is_atom(value), do: nul?(Atom.to_string(value))
  defp nul?(_value), do: false
end
