defmodule DevilsDictionary.Routing.Id do
  @moduledoc """
  A database id as the routing API accepts one: a positive integer that fits
  `bigint`.

  Checked before any query, so a nil, a string, a float or an out-of-range
  number is one record's error tuple rather than a cast or encoding exception
  — which, inside a caller's batch transaction, would abort the batch.
  """

  @max 9_223_372_036_854_775_807

  defguard is_id(value) when is_integer(value) and value > 0 and value <= @max
end
