defmodule Mix.Tasks.Dd.Quotes.Corpus.Build do
  @shortdoc "Builds the public-domain Wikiquote corpus manifest (#174), refusing on drift"

  @moduledoc """
  Builds `priv/quotes/manifests/wikiquote-pd-v1.json`: Wikiquote lines that
  build 5's checks call *Verified* against a Gutenberg text their credited
  author wrote before 1931 (`DevilsDictionary.Quotations.Corpus.Build`).

      mix dd.quotes.corpus.build
      mix dd.quotes.corpus.build --reselect
      mix dd.quotes.corpus.build --page-limit 20 --output tmp/sample.json

  **With a committed manifest** (the default path exists), the build is a
  **re-run from its `selection` block**. The same pages are read at the same
  revisions, with the same credits, works and author facts, and the resulting
  set is compared with the committed one:

    * the same set: nothing is written, and the task says so
    * a different set: the task **refuses**, names what moved and writes
      nothing. A corpus that changed underneath its checksum is a different
      corpus, and it gets a new version (`--output …-v2.json`), not an
      overwrite.

  `--reselect` makes a fresh selection from the registry and the current
  pages, and holds the result to the same rule. **Without a manifest** at the
  output path, a fresh selection is built and written.

  The task reads the registry and writes nothing to the database. Only the
  Repo is started: no endpoint and no Oban node, so a build cannot run
  anybody's jobs. Answers are cached under `tmp/quotes-corpus-cache` (disable
  with `--no-cache`), so a second run of one selection costs no requests.
  """

  use Mix.Task

  require Logger

  alias DevilsDictionary.Artworks.Corpus.Manifest
  alias DevilsDictionary.Quotations.Corpus.Build

  @default_output "priv/quotes/manifests/wikiquote-pd-v1.json"
  @default_cache "tmp/quotes-corpus-cache"

  @switches [
    output: :string,
    reselect: :boolean,
    page_limit: :integer,
    cache: :boolean,
    cache_dir: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [],
      do: Mix.raise("invalid arguments (run `mix help dd.quotes.corpus.build`)")

    start_repo()

    path = opts[:output] || @default_output
    committed = if File.exists?(path), do: load!(path)

    selection =
      if committed && not Keyword.get(opts, :reselect, false),
        do: committed["selection"]

    Mix.shell().info(
      if selection,
        do: "Re-running #{path} from its selection block (#{length(selection["pages"])} pages)",
        else: "Making a fresh selection from the registry"
    )

    cache_dir = if Keyword.get(opts, :cache, true), do: opts[:cache_dir] || @default_cache

    case Build.run(
           selection: selection,
           page_limit: opts[:page_limit],
           cache_dir: cache_dir,
           progress: fn message -> Mix.shell().info(message) end
         ) do
      {:ok, rows, selection, ledger} ->
        manifest = manifest(rows, selection, ledger)
        Mix.shell().info("Ledger: " <> inspect(ledger, pretty: true))
        conclude(manifest, committed, path)

      {:error, reason} ->
        Mix.raise("corpus build failed: #{reason}")
    end
  end

  @doc false
  def manifest(rows, selection, ledger) do
    Build.kind()
    |> Manifest.new(rows, Map.put(selection, "ledger", ledger))
    |> Map.put("set_checksum", Build.set_checksum(rows))
  end

  @doc false
  # The rule the issue asks for, apart from the task so it can be tested.
  def conclude(manifest, nil, path) do
    manifest = Manifest.save!(manifest, path)

    Mix.shell().info(
      "Wrote #{path}: #{manifest["row_count"]} lines, set checksum #{manifest["set_checksum"]}"
    )

    {:written, manifest}
  end

  def conclude(manifest, committed, path) do
    if manifest["set_checksum"] == committed["set_checksum"] do
      Mix.shell().info(
        "Unchanged: #{path} rebuilds to the same #{committed["row_count"]} lines " <>
          "(set checksum #{committed["set_checksum"]}). Nothing written."
      )

      {:unchanged, committed}
    else
      Mix.raise(drift(committed, manifest, path))
    end
  end

  defp drift(committed, manifest, path) do
    before = Map.new(committed["rows"], &{&1["fingerprint"], &1})
    now = Map.new(manifest["rows"], &{&1["fingerprint"], &1})
    gone = Map.keys(before) -- Map.keys(now)
    new = Map.keys(now) -- Map.keys(before)

    changed =
      for {fingerprint, row} <- now, old = before[fingerprint], old && old != row, do: fingerprint

    sample = fn keys, rows ->
      keys |> Enum.take(5) |> Enum.map_join("", &"\n    #{String.slice(rows[&1]["text"], 0, 80)}")
    end

    """
    refusing to write #{path}: the rebuilt set differs from the committed one.
      committed set checksum #{committed["set_checksum"]}, #{committed["row_count"]} lines
      rebuilt   set checksum #{manifest["set_checksum"]}, #{manifest["row_count"]} lines
      #{length(gone)} gone, #{length(new)} new, #{length(changed)} changed#{sample.(gone, before)}#{sample.(new, now)}
    A corpus that moved is a new version: pass --output with a new file name.
    """
  end

  defp load!(path) do
    manifest = Manifest.load!(path)

    unless manifest["kind"] == Build.kind() and is_binary(manifest["set_checksum"]) and
             manifest["set_checksum"] == Build.set_checksum(manifest["rows"]) do
      Mix.raise("#{path} is not a #{Build.kind()} manifest with a valid set checksum")
    end

    manifest
  rescue
    error in [ArgumentError, Jason.DecodeError] -> Mix.raise(Exception.message(error))
  end

  # The registry is read and never written, and nothing else is needed: no
  # endpoint, no PubSub and above all no Oban node on a shared database.
  defp start_repo do
    Mix.Task.run("app.config")
    Logger.configure(level: :info)
    {:ok, _} = Application.ensure_all_started([:req, :floki, :ecto_sql, :postgrex])
    {:ok, _} = DevilsDictionary.Repo.start_link()
  end
end
