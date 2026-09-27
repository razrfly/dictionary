# #172 final sweep, 2026-09-27: produced Wikiquote run 400 (bunny, refreshed with the red-link fix) (see README.md).
# Runs every covering server provider for the given words on the dev database,
# in this process, with this branch's code — and never lets the main checkout's
# Oban node (port 4007, same database) see a job.
#
#   mix run --no-start run_pages.exs grief love
#
# Oban starts in :manual mode with no queues and no plugins. Discovery.request
# is called inside an outer transaction; the RunWorker job it inserts is deleted
# before that transaction commits, so no other node can ever claim it. The run
# is then executed here with Discovery.execute_run/1.

import Ecto.Query
Logger.configure(level: :warning)

oban = Application.fetch_env!(:devils_dictionary, Oban)

Application.put_env(
  :devils_dictionary,
  Oban,
  Keyword.merge(oban, testing: :manual, queues: false, plugins: false)
)

{:ok, _} = Application.ensure_all_started(:devils_dictionary)

alias DevilsDictionary.{Discovery, Lexicon, Repo}
alias DevilsDictionary.Discovery.{ContentTypes, Providers, Run}
alias DevilsDictionary.Lexicon.WordPage

only = System.get_env("ONLY") && String.split(System.get_env("ONLY"), ",")

for slug <- System.argv() do
  page = slug |> Lexicon.lookup() |> WordPage.build(trail: [])
  target = Discovery.target_for_page(page, nil, false)

  providers =
    Providers.server_providers()
    |> Enum.filter(&ContentTypes.any_known?(&1.capabilities().content_types))
    |> Enum.filter(&Discovery.covers?(&1, target))
    |> Enum.filter(&(is_nil(only) or &1.slug() in only))

  IO.puts("#{slug}: target #{target.object_id}, covered by #{Enum.map_join(providers, ",", & &1.slug())}")

  for provider <- providers do
    {:ok, outcome} =
      Repo.transaction(fn ->
        case Discovery.request(target, provider.slug(), refresh: System.get_env("REFRESH") == "1") do
          {:queued, %Run{} = run} = queued ->
            {n, _} =
              Repo.delete_all(
                from j in "oban_jobs",
                  where: fragment("?->>'run_id' = ?", j.args, ^to_string(run.id))
              )

            {queued, n}

          other ->
            {other, 0}
        end
      end)

    case outcome do
      {{:queued, run}, deleted} ->
        result = Discovery.execute_run(run.id)
        run = Repo.get!(Run, run.id)
        items = Repo.aggregate(from(r in DevilsDictionary.Discovery.Result, where: r.run_id == ^run.id), :count)
        IO.puts("  #{provider.slug()}: ran #{run.id} (job rows removed: #{deleted}) -> #{inspect(result)} #{run.status}, #{items} results")

      {other, _} ->
        IO.puts("  #{provider.slug()}: #{inspect(other, limit: 3)}")
    end
  end
end
