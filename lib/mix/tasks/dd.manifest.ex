defmodule Mix.Tasks.Dd.Manifest do
  @moduledoc """
  Verifies every archived source input against `priv/sources/MANIFEST.json`.

      mix dd.manifest              # verify all five inputs
      mix dd.manifest --source wiktionary
      mix dd.manifest --record     # print entries for files not yet pinned

  Exits non-zero when any input is missing or its digest differs, so it can
  gate a rebuild. Reading 2.6 GB takes a few seconds; that is the price of
  knowing the dump is the one every number was measured on.

  Options:

    * `--source` — restrict to one source slug
    * `--record` — compute digests and print manifest entries instead of
      verifying, for adding a new input
  """

  @shortdoc "Verify archived source inputs against their pinned digests"

  use Mix.Task

  import Mix.Tasks.Dd.Report

  alias DevilsDictionary.Sources.Manifest

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, files, _} = OptionParser.parse(args, strict: [source: :string, record: :boolean])

    if opts[:record], do: record(files), else: verify(opts[:source])
  end

  defp verify(slug) do
    say("verifying #{Manifest.path()}#{(slug && " (#{slug})") || ""}…")
    say("")

    {result, rows} = Manifest.verify(source: slug)

    Enum.each(rows, &print/1)

    say("")
    ok = Enum.count(rows, &(&1.status == :ok))
    say("  #{ok} / #{length(rows)} inputs verified")

    if result == :error do
      warn("")
      warn("  an input is missing or has changed — do not rebuild from it")
      exit({:shutdown, 1})
    end
  end

  defp print(%{status: :ok} = r), do: row("✅ #{r.locator}", r.detail, 52)

  defp print(r),
    do: warn("  ❌ #{String.pad_trailing(r.locator, 52)} #{r.status}: #{r.detail}")

  defp record([]) do
    warn("  --record needs one or more paths: mix dd.manifest --record data/some-dump.gz")
    exit({:shutdown, 1})
  end

  defp record(files) do
    Enum.each(files, fn path ->
      unless File.exists?(path) do
        warn("  no such file: #{path}")
        exit({:shutdown, 1})
      end

      say("")
      say(~s(  "archive_locator": "#{path}",))
      say(~s(  "byte_count": #{File.stat!(path).size},))
      say(~s(  "sha256": "#{Manifest.digest(path)}",))
    end)

    say("")
    say("  paste these into #{Manifest.path()} with the source, edition, url and licence")
  end
end
