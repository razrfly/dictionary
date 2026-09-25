defmodule Mix.Tasks.Dd.Exemplars.Seed do
  @shortdoc "Seeds an exemplar manifest (#181) as one account's nominations"

  @moduledoc """
  Seeds a committed exemplar manifest from `priv/exemplars/` through
  `Contributions.propose/6`, as the account named by `--as`:

      mix dd.exemplars.seed priv/exemplars/first-v1.json --as curator@example.com --dry-run
      mix dd.exemplars.seed priv/exemplars/first-v1.json --as curator@example.com
      mix dd.exemplars.seed priv/exemplars/first-v1.json --stamp

  Every row becomes a `needs_review` `illustrates` claim with `method:
  "curated"`, or is reported **held** (the claim exists — a re-run writes
  nothing) or **refused** with its reason. A row whose `sense.match` hits zero
  or several senses is refused with the word's glosses printed, so the match
  can be fixed. See `DevilsDictionary.Examples.Seeder`.

    * `--as` — the account the nominations are submitted by. It must be an
      internal contributor or a reviewer; `propose/6` refuses anyone else.
    * `--dry-run` — resolve every row and write nothing; makes no request.
    * `--limit N` — the first N rows only.
    * `--wikidata-limit N` — at most N Wikidata requests for minting nominees
      (default 10). Requests are paced at Wikidata's own interval. Beyond the
      cap, a nominee is reported `deferred` and a re-run tries again.
    * `--stamp` — rewrite the manifest's `row_count` and `checksum` after a
      hand edit, and exit. A manifest whose checksum does not match its
      contents is refused, so an edit nobody stamped never seeds.

  Nothing is reviewed here. A reviewer accepts on `/connections/:id`, and only
  then does a person's card become public.
  """

  use Mix.Task

  alias DevilsDictionary.Absorb.Sources.Wikidata
  alias DevilsDictionary.Accounts.User
  alias DevilsDictionary.Examples.{Manifest, Seeder}
  alias DevilsDictionary.Repo

  @switches [
    as: :string,
    dry_run: :boolean,
    limit: :integer,
    wikidata_limit: :integer,
    stamp: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, paths, invalid} = OptionParser.parse(args, strict: @switches)

    path =
      case {paths, invalid} do
        {[path], []} -> path
        _ -> Mix.raise("usage: mix dd.exemplars.seed <manifest.json> --as <email> [--dry-run]")
      end

    if opts[:stamp] do
      manifest = Manifest.stamp!(path)
      Mix.shell().info("Stamped #{path}: #{manifest["row_count"]} rows, #{manifest["checksum"]}")
    else
      seed(path, opts)
    end
  end

  defp seed(path, opts) do
    start_repo_only()

    # A database seeded before build 2 has no `community` row, and every
    # cited URL is stored under it. Say how to add it rather than crash on
    # the first row.
    unless opts[:dry_run] ||
             DevilsDictionary.Sources.get_source_by_slug(
               DevilsDictionary.Examples.Community.slug()
             ) do
      Mix.raise(
        "no `community` source row: run Sources.Catalog.seed!/0 first, e.g. " <>
          "mix run --no-start -e 'Application.ensure_all_started(:ecto_sql); " <>
          "DevilsDictionary.Repo.start_link(); DevilsDictionary.Sources.Catalog.seed!()'"
      )
    end

    email = opts[:as] || Mix.raise("--as <email> is required: whose nominations are these?")
    user = Repo.get_by(User, email: email) || Mix.raise("no account #{email}")

    manifest =
      try do
        Manifest.load!(path)
      rescue
        error in [ArgumentError, File.Error, Jason.DecodeError] ->
          Mix.raise(Exception.message(error))
      end

    {:ok, summary} =
      Seeder.run(manifest, %{user: user},
        dry_run: opts[:dry_run] || false,
        limit: opts[:limit],
        claim: claim(opts[:wikidata_limit] || 10)
      )

    Mix.shell().info(
      "Exemplar manifest #{path}: #{summary.manifest}, #{summary.rows} rows, checksum #{summary.checksum}"
    )

    Enum.each(summary.results, &Mix.shell().info(line(&1)))

    Mix.shell().info(
      "created #{summary.created} (minted #{summary.minted}) · held #{summary.held} · " <>
        "refused #{summary.refused} · deferred #{summary.deferred} · would seed #{summary.would_seed}"
    )
  end

  # The repo and an HTTP client, and nothing else: `app.start` would start
  # Oban, and a second Oban node beside a running server executes that
  # server's queued runs with this checkout's code. A seed needs neither.
  defp start_repo_only do
    Mix.Task.run("app.config")
    Logger.configure(level: :info)
    {:ok, _} = Application.ensure_all_started([:postgrex, :ecto_sql, :req])

    case DevilsDictionary.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  # Pacing and a hard cap, because a seed has no discovery run for the shared
  # `wikidata` budget to be charged to (`Examples.Seeder`).
  defp claim(limit) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fn _stage ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        n when n < limit -> {:ok, if(n == 0, do: 0, else: Wikidata.rate_limit_ms())}
        _ -> {:error, :wikidata_limit_reached}
      end
    end
  end

  defp line(%{row: row, word: word, subject: subject, outcome: outcome} = result) do
    head = "  row #{row}: #{subject} → #{word} — #{outcome}"

    detail =
      case result do
        %{assertion_id: id, minted: true} -> " (claim #{id}, person minted)"
        %{assertion_id: id} -> " (claim #{id})"
        %{reason: reason} -> " (#{reason})"
        %{mint: true} -> " (would mint the subject from Wikidata)"
        _ -> ""
      end

    glosses =
      case result do
        %{glosses: [_ | _] = glosses} ->
          "\n" <> Enum.map_join(glosses, "\n", &"      · #{&1}")

        %{glosses: []} ->
          "\n      · (the word has no current sense from that source)"

        _ ->
          ""
      end

    head <> detail <> glosses
  end
end
