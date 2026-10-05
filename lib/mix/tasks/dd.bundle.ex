defmodule Mix.Tasks.Dd.Bundle do
  @shortdoc "Capture a working installation into a verified bundle; verify or copy one"

  @moduledoc """
  Captures the working installation into one directory that carries it to
  another cluster or machine (#130, #211). Read-only on the source.

      mix dd.bundle --source devils_dictionary_v2 \\
        --out "/Volumes/LLM Models/dictionary/bundles/2026-10-06-v2" \\
        --volume "/Volumes/LLM Models" --volume-uuid F7FDE75A-3FE9-43D9-AC1E-71FDDEDBAF31

      mix dd.bundle --verify "/Volumes/LLM Models/dictionary/bundles/2026-10-06-v2"

      mix dd.bundle --transfer "/Volumes/LLM Models/dictionary/bundles/2026-10-06-v2" \\
        --out /Volumes/Other/dictionary/bundles/2026-10-06-v2 --volume /Volumes/Other \\
        --expect-manifest-sha256 <digest>

  ## Capturing

  `--source` names the database: a name on the configured server
  (`DD_DATABASE_PORT` picks the server), or an `ecto://` URL. It is never
  defaulted: a capture of the corpus is deliberate. The bundle holds a
  `pg_dump` (owners and privileges kept), the state that dump contains —
  taken under the same exported snapshot — the archived inputs git does not
  carry (pinned by `priv/sources/MANIFEST.json`) and the replay archive.
  `MANIFEST.json` is written last; its SHA-256 is printed, and is what the
  owner approves and `mix dd.bootstrap` pins.

  The source must be quiet: the capture refuses while other sessions are
  connected, and refuses to finish if its write counters moved during the
  window (`--allow-unquiet` records an unquiet window instead, for a
  rehearsal; such a bundle is not a baseline).

  `--out` must be on the mounted external volume `--volume` names (and
  `--volume-uuid`, when given): nothing is written anywhere else, and a
  finished bundle is never overwritten. An interrupted capture resumes
  when run again with the same arguments.

  The bundle is private: a full working database. `.env` is never read.

  ## Options

    * `--source NAME|URL`, `--out DIR`, `--volume MOUNT` — capture
    * `--volume-uuid UUID` — the volume's expected UUID
    * `--no-inputs` — leave out the archived inputs and the replay archive
    * `--models-root DIR` — inventory the pinned model artifacts there
    * `--allow-unquiet` — see above
    * `--verify DIR` — verify a finished bundle (sizes and SHA-256)
    * `--quick` — with `--verify`, sizes only
    * `--transfer FROM` — copy a finished bundle to `--out`, resumably
    * `--expect-manifest-sha256 HEX` — with `--transfer`, the approved digest
  """

  use Mix.Task

  import Mix.Tasks.Dd.Report

  alias DevilsDictionary.Installation.Bundle

  @requirements ["app.config"]

  @switches [
    source: :string,
    out: :string,
    volume: :string,
    volume_uuid: :string,
    inputs: :boolean,
    models_root: :string,
    allow_unquiet: :boolean,
    verify: :string,
    quick: :boolean,
    transfer: :string,
    expect_manifest_sha256: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] or rest != [],
      do: Mix.raise("unknown arguments: #{inspect(invalid ++ rest)}; see `mix help dd.bundle`")

    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)

    cond do
      opts[:verify] -> verify(opts[:verify], opts)
      opts[:transfer] -> transfer(opts[:transfer], opts)
      true -> create(opts)
    end
  end

  defp create(opts) do
    for key <- [:source, :out, :volume],
        is_nil(opts[key]),
        do: Mix.raise("--#{key} is required; see `mix help dd.bundle`")

    result =
      Bundle.create(
        source: opts[:source],
        out: opts[:out],
        volume: opts[:volume],
        uuid: opts[:volume_uuid],
        inputs: Keyword.get(opts, :inputs, true),
        models_root: opts[:models_root],
        require_quiet: not Keyword.get(opts, :allow_unquiet, false),
        log: &say("  " <> &1)
      )

    case result do
      {:ok, %{manifest: manifest, digest: digest, path: path}} ->
        say("")
        row("bundle", path)

        row(
          "source",
          "#{manifest["source"]["endpoint"]} (cluster #{manifest["source"]["system_identifier"]})"
        )

        row("schema head", manifest["schema"]["head"])
        row("files", length(manifest["files"]))
        row("bytes", fmt(Enum.sum(for f <- manifest["files"], do: f["bytes"])))
        row("window quiet", manifest["quiescence"]["quiet"])
        row("MANIFEST.json sha256", digest)
        say("")
        say("  Verify it with `mix dd.bundle --verify #{path}`, and pin the digest above")
        say("  when restoring: `mix dd.bootstrap --expect-manifest-sha256 #{digest} …`.")

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp verify(path, opts) do
    case Bundle.verify(path, deep: not Keyword.get(opts, :quick, false)) do
      {:ok, report} ->
        for row <- report.rows, do: row("✅ #{row.path}", row.detail, 60)
        say("")
        say("  #{length(report.rows)} files verified; MANIFEST.json sha256 #{report.digest}")

      {:error, report} ->
        for row <- report.rows do
          if row.status == :ok,
            do: row("✅ #{row.path}", row.detail, 60),
            else: warn("  ❌ #{String.pad_trailing(row.path, 60)} #{row.detail}")
        end

        for problem <- report.problems, do: warn("  ❌ #{problem}")
        Mix.raise("the bundle at #{path} does not verify")
    end
  end

  defp transfer(from, opts) do
    for key <- [:out, :volume],
        is_nil(opts[key]),
        do: Mix.raise("--#{key} is required with --transfer")

    case Bundle.transfer(from, opts[:out],
           volume: opts[:volume],
           uuid: opts[:volume_uuid],
           expect_manifest_sha256: opts[:expect_manifest_sha256],
           log: &say("  " <> &1)
         ) do
      {:ok, report} -> say("\n  copied and verified; MANIFEST.json sha256 #{report.digest}")
      {:error, message} -> Mix.raise(message)
    end
  end
end
