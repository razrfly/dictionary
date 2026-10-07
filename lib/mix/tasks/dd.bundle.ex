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

      mix dd.bundle --transfer "/Volumes/LLM Models/dictionary/bundles/2026-10-06-v2" \\
        --out ~/Backups/dictionary/bundles/2026-10-06-v2 --internal \\
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
    * `--root DIR` — the checkout the installation runs from, whose `data/`
      and `priv/replay` are bundled and whose revision is recorded (default:
      the current directory). The task's own revision is recorded beside it
    * `--no-inputs` — leave out the archived inputs and the replay archive
    * `--models-root DIR` — inventory the pinned model artifacts there
    * `--allow-unquiet` — see above
    * `--verify DIR` — verify a finished bundle (sizes and SHA-256)
    * `--quick` — with `--verify`, sizes only
    * `--transfer FROM` — copy a finished bundle to `--out`, resumably
    * `--expect-manifest-sha256 HEX` — with `--transfer`, the approved digest
    * `--internal` — with `--transfer` and `--expect-manifest-sha256`, instead
      of `--volume`: the destination is on the internal disk. This is for the
      second copy that is still there when the external drive is lost (#211
      D14). So the bundle must be on an external volume, and the destination
      on a volume diskutil reports internal (not a directory under `/Volumes`
      standing in for a drive), outside every git repository, leaving 10 GiB
      free after the copy. Without it, an internal destination is refused
    * `--reserve-gib N` — with `--internal`: the free space the copy must
      leave, when the operator decides on another floor than 10 GiB
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
    expect_manifest_sha256: :string,
    root: :string,
    internal: :boolean,
    reserve_gib: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] or rest != [],
      do: Mix.raise("unknown arguments: #{inspect(invalid ++ rest)}; see `mix help dd.bundle`")

    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)

    if opts[:internal] && is_nil(opts[:transfer]),
      do: Mix.raise("--internal is for --transfer only: the second copy of a finished bundle")

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
        root: opts[:root] || ".",
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

        row("schema head", to_string(manifest["schema"]["head"]))
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
    internal = Keyword.get(opts, :internal, false)

    if is_nil(opts[:out]), do: Mix.raise("--out is required with --transfer")

    cond do
      internal and (opts[:volume] || opts[:volume_uuid]) ->
        Mix.raise("--internal names the internal disk; it cannot be given with --volume")

      opts[:reserve_gib] && not internal ->
        Mix.raise("--reserve-gib is for --internal only")

      opts[:reserve_gib] && opts[:reserve_gib] < 0 ->
        Mix.raise("--reserve-gib must not be negative")

      internal and is_nil(opts[:expect_manifest_sha256]) ->
        Mix.raise(
          "--internal needs --expect-manifest-sha256: the second copy is of an approved bundle"
        )

      not internal and is_nil(opts[:volume]) ->
        Mix.raise("--volume is required with --transfer (or --internal, for the second copy)")

      true ->
        :ok
    end

    case Bundle.transfer(from, opts[:out],
           volume: opts[:volume],
           uuid: opts[:volume_uuid],
           internal: internal,
           reserve_bytes: reserve_bytes(opts),
           expect_manifest_sha256: opts[:expect_manifest_sha256],
           log: &say("  " <> &1)
         ) do
      {:ok, report} -> say("\n  copied and verified; MANIFEST.json sha256 #{report.digest}")
      {:error, message} -> Mix.raise(message)
    end
  end

  # The internal disk's floor: Volume's default unless the operator names
  # another, which the command line then records.
  defp reserve_bytes(opts) do
    case opts[:reserve_gib] do
      nil -> nil
      gib -> gib * 1_073_741_824
    end
  end
end
