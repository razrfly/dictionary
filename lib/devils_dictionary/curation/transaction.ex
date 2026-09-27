defmodule DevilsDictionary.Curation.Transaction do
  @moduledoc """
  The small vocabulary every curation write shares: one transaction per
  action, a failure that rolls it back, and idempotency keys that replay an
  earlier receipt rather than write a second one.
  """

  alias DevilsDictionary.Repo

  @doc """
  Runs `fun` in a transaction. `{:ok, value}` commits; `{:error, reason}` rolls
  back and is returned as is.
  """
  def run(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "`{:ok, value}`, or `{:error, reason}` for `nil` and `false`."
  def need(nil, reason), do: {:error, reason}
  def need(false, reason), do: {:error, reason}
  def need(value, _reason), do: {:ok, value}

  @doc "`:ok` when `condition` is `true`, else `{:error, reason}`."
  def check(true, _reason), do: :ok
  def check(_condition, reason), do: {:error, reason}

  @doc """
  What an idempotency key has already done. `:fresh` if nothing, `{:replay,
  row}` if the same action, `{:error, :idempotency_conflict}` if a different
  one. Call after taking the row lock that serializes the action, so a
  concurrent first use is seen.
  """
  def replay(schema, key, same?) do
    case Repo.get_by(schema, idempotency_key: key) do
      nil -> :fresh
      row -> if same?.(row), do: {:replay, row}, else: {:error, :idempotency_conflict}
    end
  end

  @doc "The non-blank string at `key` in `opts`, or `{:error, {:required, key}}`."
  def required(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:required, key}}, else: {:ok, value}

      _ ->
        {:error, {:required, key}}
    end
  end
end
