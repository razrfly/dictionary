defmodule Mix.Tasks.Dd.Curation.Seed do
  @shortdoc "Seeds the draft global-default curation configuration and five proposed profiles (#201)"

  @moduledoc """
  Seeds curation's system-owned identities (#196, #201):

      mix dd.curation.seed

  What it writes, if missing:

    * the `global-default` configuration, as a **draft**;
    * its manual-only version 1: Bierce-first lead, up to three highlights,
      empty roster;
    * the five proposed profile identities: Bierce, Voltaire, Vonnegut,
      Hitchens and Le Guin.

  It **activates nothing and approves nothing**. The default resolves as
  unavailable (`:no_active_version`) until a reviewer calls
  `Curation.Configurations.activate/4`. No profile gets a dossier, evidence
  or a bot actor, and no composition, version, review or publication is
  written. A re-run changes nothing, and an activated configuration stays
  activated.

  Curation state is restored from a backup, not regenerated, like routing
  state: registry object ids exist only in the database.
  """

  use Mix.Task

  alias DevilsDictionary.Curation.Configurations

  @impl Mix.Task
  def run(_args) do
    start_repo_only()

    %{configuration: c, version: v, profiles: profiles} = Configurations.seed!()

    Mix.shell().info(
      "#{c.slug}: #{c.state}, version #{v.version} (#{v.lead_policy}, " <>
        "#{v.max_highlights} highlights, roster #{String.slice(v.roster_hash, 0, 12)}…)"
    )

    Mix.shell().info("profiles: " <> Enum.map_join(profiles, ", ", &"#{&1.slug} (#{&1.state})"))

    Mix.shell().info("resolution: #{inspect(Configurations.resolve_default())}")
  end

  # The repo and nothing else: `app.start` would start Oban, and a second
  # Oban node beside a running server executes that server's queued runs with
  # this checkout's code.
  defp start_repo_only do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:postgrex, :ecto_sql])

    case DevilsDictionary.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
