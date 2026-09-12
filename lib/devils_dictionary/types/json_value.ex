defmodule DevilsDictionary.Types.JsonValue do
  @moduledoc "A JSONB value that may be an object or an array."

  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(value) when is_map(value) or is_list(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl true
  def load(value) when is_map(value) or is_list(value), do: {:ok, value}
  def load(_value), do: :error

  @impl true
  def dump(value) when is_map(value) or is_list(value), do: {:ok, value}
  def dump(_value), do: :error

  @impl true
  def embed_as(_format), do: :self

  @impl true
  def equal?(left, right), do: left == right
end
