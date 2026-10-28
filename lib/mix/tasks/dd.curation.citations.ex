defmodule Mix.Tasks.Dd.Curation.Citations do
  @shortdoc "Read-only citation inspection: shelf, packet, sweep --dry-run, receipt (#270)"
  @moduledoc """
  Run with DD_NO_OBAN=1 and PHX_SERVER unset. These commands only read:

      mix dd.curation.citations shelf --slug love
      mix dd.curation.citations packet --slug love [--shelf news]
      mix dd.curation.citations sweep --dry-run [--limit 500]
      mix dd.curation.citations receipt --slug love --version 2

  Sweep also works before the additive migration. It resolves legacy observations
  logically without binding them or updating metadata. Counts describe this
  snapshot; the live sweep rechecks under canonical locks. Packet prints only
  identities and hashes. None of these commands requests discovery or a model.
  """
  use Mix.Task
  alias DevilsDictionary.{Repo, Lexicon}
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Curation.{DiscoveryRetention, Receipt}
  alias DevilsDictionary.Curation.Runtime.Packet

  @impl Mix.Task
  def run(args) do
    unless System.get_env("DD_NO_OBAN") == "1",
      do: Mix.raise("Set DD_NO_OBAN=1; citation inspection starts no jobs.")

    if System.get_env("PHX_SERVER"),
      do: Mix.raise("Unset PHX_SERVER; citation inspection starts no server.")

    {opts, commands, invalid} =
      OptionParser.parse(args,
        strict: [
          slug: :string,
          shelf: :string,
          version: :integer,
          dry_run: :boolean,
          limit: :integer
        ]
      )

    unless invalid == [] and length(commands) == 1,
      do:
        Mix.raise(
          "Use shelf, packet, sweep --dry-run, or receipt; see mix help dd.curation.citations"
        )

    Mix.Task.run("app.start")

    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
        inspect_command(hd(commands), opts)
      end)

    Mix.shell().info(Jason.encode!(plain(result), pretty: true))
  end

  defp inspect_command("sweep", opts) do
    unless opts[:dry_run],
      do: Mix.raise("Sweep inspection requires --dry-run; this command never executes cleanup.")

    limit =
      opts[:limit] || Application.fetch_env!(:devils_dictionary, :discovery)[:cleanup_batch_size]

    unless is_integer(limit) and limit > 0, do: Mix.raise("--limit must be positive")
    DiscoveryRetention.dry_run(limit)
  end

  defp inspect_command("shelf", opts) do
    page = page!(opts)

    Enum.flat_map(page.headword.lexemes, fn lexeme ->
      DevilsDictionary.Discovery.citable(lexeme.id)
      |> Enum.map(fn o ->
        %{
          result: o.result.id,
          run: o.run.id,
          revision: o.revision && o.revision.id,
          checksum: o.revision && o.revision.checksum,
          source: o.source.slug,
          kind: o.kind,
          status: o.status,
          expires_at: o.expires_at
        }
      end)
    end)
  end

  defp inspect_command("packet", opts) do
    case Packet.for_page(page!(opts), shelf: opts[:shelf]) do
      {:ok, packet} ->
        {:ok, frozen} = Packet.freeze(packet)
        Packet.summary(frozen)

      {:error, reason} ->
        Mix.raise("Packet unavailable: #{inspect(reason)}")
    end
  end

  defp inspect_command("receipt", opts) do
    case Receipt.read(opts[:slug] || "", opts[:version]) do
      {:ok, receipt} -> receipt
      _ -> Mix.raise("No published receipt for --slug and --version")
    end
  end

  defp inspect_command(_, _), do: Mix.raise("Unknown citation inspection command")

  defp page!(opts) do
    unless is_binary(opts[:slug]), do: Mix.raise("--slug is required")
    opts[:slug] |> Lexicon.lookup() |> WordPage.build(viewer: :public)
  end

  defp plain(%DateTime{} = date), do: DateTime.to_iso8601(date)
  defp plain(%NaiveDateTime{} = date), do: NaiveDateTime.to_iso8601(date)
  defp plain(%_{} = value), do: value |> Map.from_struct() |> Map.delete(:__meta__) |> plain()

  defp plain(value) when is_map(value),
    do: Map.new(value, fn {key, value} -> {key, plain(value)} end)

  defp plain(value) when is_list(value), do: Enum.map(value, &plain/1)
  defp plain(value) when is_tuple(value), do: value |> Tuple.to_list() |> plain()
  defp plain(value), do: value
end
