defmodule Mix.Tasks.Dd.Reset do
  @shortdoc "Drop and recreate a named database, then seed the catalog"

  @moduledoc """
  The clean-setup half of #74's milestone 1: *"an empty database can be created
  reproducibly"*.

      mix dd.reset --database devils_dictionary_v2
      mix dd.reset --database devils_dictionary_rebuild --quiet

  ## Why it demands the name

  #74: *"Reset commands must explicitly target the intended development/test
  database. Do not delete original source archives, unrelated databases or
  credentials."* So `--database` is required and must **match the one this
  environment is configured for**, unless `--force` is given with the name
  spelled out again. There is no default, and there is no way to run this
  without having typed the name of the thing being dropped.

  It refuses outright to touch a database whose name does not begin with
  `devils_dictionary`, and it never touches `data/`, `priv/sources/` or
  `priv/replay/` — the archived inputs are what a rebuild reads, and a reset
  that destroyed them would not be a reset.

  ## What it leaves behind

  An empty schema with the source catalog, the scopes and the predicate registry
  seeded: `sources`, `scopes`, `predicates`, `predicate_endpoint_rules`, and
  Bierce and Johnson as entities with their works and editions. That is the
  state `mix dd.rebuild` starts from.
  """

  use Mix.Task

  import Mix.Tasks.Dd.Report

  @requirements []

  @prefix "devils_dictionary"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [database: :string, force: :string, quiet: :boolean])

    configured = configured_database()
    named = opts[:database]

    check!(named, configured, opts[:force])

    quiet? = opts[:quiet] || false

    tell(quiet?, fn ->
      say("resetting #{named}")
      say("")
    end)

    Mix.Task.run("ecto.drop", ["--quiet"])
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])

    Mix.Task.run("app.start")
    catalog = DevilsDictionary.Sources.Catalog.seed!()

    tell(quiet?, fn ->
      row("database", named)
      row("sources", map_size(catalog.sources))
      row("scopes", map_size(catalog.scopes))
      row("predicates", map_size(catalog.predicates))
      row("people", map_size(catalog.people))
      say("")
      say("  empty and seeded. `mix dd.rebuild` is what fills it.")
    end)
  end

  defp tell(true, _fun), do: :ok
  defp tell(false, fun), do: fun.()

  defp check!(nil, configured, _force) do
    Mix.raise("""
    --database is required, and must be #{configured}.

    #74: a reset command must explicitly target the database it means. There is
    no default here on purpose — the name has to be typed.
    """)
  end

  defp check!(named, configured, force) do
    unless String.starts_with?(named, @prefix) do
      Mix.raise("refusing to touch #{named}: this task only resets #{@prefix}* databases")
    end

    cond do
      named == configured ->
        :ok

      force == named ->
        # Deliberate, and the name typed twice. Used when pointing a run at the
        # third database P5's rebuildability proof creates.
        :ok

      true ->
        Mix.raise("""
        #{named} is not the database this environment is configured for (#{configured}).

        If that is deliberate, set the environment's database first, or repeat the
        name: --database #{named} --force #{named}
        """)
    end
  end

  defp configured_database do
    Application.load(:devils_dictionary)
    get_in(Application.get_env(:devils_dictionary, DevilsDictionary.Repo), [:database])
  end
end
