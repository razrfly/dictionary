defmodule Mix.Tasks.Dd.Routing.Guard do
  @shortdoc "Refuse to destroy a database holding durable routing state"

  @moduledoc """
  Raises if the configured database holds durable routing state and
  `DD_ROUTING_SNAPSHOT` does not name a covering snapshot of it — the check
  `mix dd.reset`, `mix dd.snapshot --restore` and `mix dd.rebuild` make
  themselves (`DevilsDictionary.Routing.Recovery.guard/3`).

      mix dd.routing.guard drop

  The `ecto.drop` alias in `mix.exs` runs it first, so `mix ecto.drop` and
  `mix ecto.reset` are guarded too:

      mix dd.snapshot --out ~/Backups/dictionary.dump
      DD_ROUTING_SNAPSHOT=~/Backups/dictionary.dump mix ecto.drop

  A database without routing tables, or with empty ones, passes. The supported
  recovery is `docs/routing/recovery.md`.
  """

  use Mix.Task

  alias DevilsDictionary.Routing.Recovery

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    action = List.first(args) || "drop"
    config = Application.get_env(:devils_dictionary, DevilsDictionary.Repo)

    snapshot =
      case System.get_env("DD_ROUTING_SNAPSHOT") do
        blank when blank in [nil, ""] -> nil
        path -> Path.expand(path)
      end

    case Recovery.guard(config, action, snapshot) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
