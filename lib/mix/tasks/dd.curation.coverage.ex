defmodule Mix.Tasks.Dd.Curation.Coverage do
  @shortdoc "Read-only ten-page coverage from stored attempts and current receipts"
  @moduledoc """
  DD_NO_OBAN=1 mix dd.curation.coverage --slug love --from 25 --to 35
  DD_NO_OBAN=1 mix dd.curation.coverage --all --from 25 --to 35

  PHX_SERVER must be unset. Starts no server, discovery or model work; uses one
  repeatable-read, read-only transaction. Default latest 20 attempts per page,
  --limit 1..100; reports truncation. No provider text or editorial reasons printed.
  Use explicit database environment settings; never infer a target from a URL.
  """
  use Mix.Task
  alias DevilsDictionary.{Repo, Curation.Coverage, Curation.Pilot}
  @impl Mix.Task
  def run(args) do
    unless System.get_env("DD_NO_OBAN") == "1" and is_nil(System.get_env("PHX_SERVER")),
      do: Mix.raise("Set DD_NO_OBAN=1 and unset PHX_SERVER; coverage runs no jobs or server.")

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [slug: :string, all: :boolean, from: :integer, to: :integer, limit: :integer]
      )

    unless rest == [] and invalid == [] and
             ((is_binary(opts[:slug]) and not opts[:all]) or
                (opts[:all] == true and is_nil(opts[:slug]))),
           do: Mix.raise("Use exactly --slug PILOT or --all, with optional --from/--to/--limit.")

    slugs = if opts[:all], do: Pilot.autonomous_pages(), else: [opts[:slug]]

    {repo, oban, endpoint} =
      read_only_config(
        Application.fetch_env!(:devils_dictionary, Repo),
        Application.fetch_env!(:devils_dictionary, Oban),
        Application.fetch_env!(:devils_dictionary, DevilsDictionaryWeb.Endpoint)
      )

    Application.put_env(:devils_dictionary, Repo, repo)
    Application.put_env(:devils_dictionary, Oban, oban)
    Application.put_env(:devils_dictionary, DevilsDictionaryWeb.Endpoint, endpoint)
    Mix.Task.run("app.start")

    {:ok, reports} =
      Repo.transaction(
        fn ->
          Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")

          Enum.map(slugs, fn slug ->
            case Coverage.read(slug, Keyword.take(opts, [:from, :to, :limit])) do
              {:error, reason} -> Mix.raise("Coverage refused: #{reason}")
              report -> report
            end
          end)
        end,
        timeout: 120_000
      )

    Mix.shell().info(Jason.encode!(reports, pretty: true))
  end

  @doc false
  def read_only_config(repo, oban, endpoint) do
    parameters =
      Keyword.put(Keyword.get(repo, :parameters, []), :default_transaction_read_only, "on")

    {Keyword.put(repo, :parameters, parameters),
     Keyword.merge(oban, queues: false, plugins: false, peer: false, testing: :manual),
     Keyword.put(endpoint, :server, false)}
  end
end
