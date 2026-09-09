defmodule DevilsDictionary.Sources.Manifest do
  @moduledoc """
  The input manifest: one entry per archived file the rebuild reads, pinned by
  SHA-256.

  Issue #74 asks for this before anything is dropped, and the reason is narrow.
  `File.exists?` says a file is there. `dump_bytes` says it is the right size.
  Neither says it is the same bytes, and one of our five inputs —
  `data/raw-wiktextract-data.jsonl.gz`, 2.6 GB — is served from a **rolling**
  URL that returns a different extract every week. Only 22,534 of its records
  ever reach `source_records`; the 1.5 M-row lexeme index is written straight
  to `lexemes` by the index pass. So that file is not a convenience, it is a
  required recovery input, and a digest is the only thing that identifies it.

  What a digest does and does not prove: it pins **what was actually used**, so
  a later run either reads the same bytes or fails. It does not authenticate a
  publisher — anyone who can replace the file can replace the manifest. That is
  a supply-chain question and this is not its answer.

  Johnson already worked this way (`Johnson.verify!/2`, pinned in `Catalog`).
  This generalises it to all five inputs; the two agree on Johnson's digest,
  which is how the mechanism was checked.
  """

  @path "priv/sources/MANIFEST.json"

  @doc "Where the manifest lives, relative to the project root."
  def path, do: @path

  @doc """
  The manifest, decoded. Raises when it is missing or malformed.

  `path` is an argument rather than a constant so tests can point at a fixture
  manifest. The alternative — running the test inside a tmp directory — needs
  `File.cd!`, which changes the working directory of the whole OS process and
  so cannot be `async: true`.
  """
  def read!(path \\ @path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  @doc "Every input entry, in file order."
  def inputs(path \\ @path), do: read!(path)["inputs"]

  @doc """
  The entry for one archive locator, or `nil`.

  Keyed on the locator rather than the source slug because Bierce has two
  files — the HTML we parse and the plain text we keep as a cross-check.
  """
  def input(locator, path \\ @path),
    do: Enum.find(inputs(path), &(&1["archive_locator"] == locator))

  @doc """
  Verifies every entry, or the ones whose `source` matches `opts[:source]`.

  Returns `{:ok, results}` when all pass and `{:error, results}` when any does
  not, where each result is a map with `:locator`, `:status` and a `:detail`.
  Statuses:

    * `:ok` — the file is present and its digest matches
    * `:missing` — no such file
    * `:mismatch` — present, digest differs; `:detail` names expected and actual
    * `:unpinned` — the entry carries no `sha256` (nothing in the manifest today)

  Digests are computed by streaming the file in 1 MB chunks: the largest input
  is 2.6 GB and `File.read!` on it would be 2.6 GB of binary.
  """
  def verify(opts \\ []) do
    slug = opts[:source]
    root = opts[:root] || "."

    results =
      opts
      |> Keyword.get(:path, @path)
      |> inputs()
      |> Enum.filter(&(is_nil(slug) or &1["source"] == slug))
      |> Enum.map(&verify_one(&1, root, opts[:quick] == true))

    if Enum.all?(results, &(&1.status == :ok)), do: {:ok, results}, else: {:error, results}
  end

  # `quick: true` checks presence and byte count and stops there. Hashing 2.6 GB
  # is the right thing for `mix dd.manifest --verify` and the wrong thing for a
  # scorecard row that runs on every page load: the cheap check still catches a
  # missing or truncated archive, and it says which check it did rather than
  # implying the strong one.
  defp verify_one(%{"archive_locator" => locator} = entry, root, quick?) do
    expected = entry["sha256"]
    full = Path.join(root, locator)

    cond do
      is_nil(expected) ->
        %{locator: locator, source: entry["source"], status: :unpinned, detail: "no sha256"}

      not File.exists?(full) ->
        %{locator: locator, source: entry["source"], status: :missing, detail: acquire(entry)}

      quick? ->
        compare_size(entry, locator, full)

      true ->
        compare(entry, locator, full, expected)
    end
  end

  defp compare_size(entry, locator, full) do
    expected = entry["byte_count"]
    actual = File.stat!(full).size

    if is_nil(expected) or actual == expected do
      %{locator: locator, source: entry["source"], status: :ok, detail: "#{actual} bytes"}
    else
      %{
        locator: locator,
        source: entry["source"],
        status: :mismatch,
        detail: "expected #{expected} bytes, found #{actual}"
      }
    end
  end

  defp compare(entry, locator, full, expected) do
    actual = digest(full)

    if actual == expected do
      %{locator: locator, source: entry["source"], status: :ok, detail: short(actual)}
    else
      %{
        locator: locator,
        source: entry["source"],
        status: :mismatch,
        detail: "expected #{short(expected)}, read #{short(actual)}"
      }
    end
  end

  @chunk 1_048_576

  @doc "The SHA-256 of a file, streamed, lowercase hex."
  def digest(path) do
    path
    |> File.stream!(@chunk)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp short(<<head::binary-size(12), _::binary>>), do: head <> "…"
  defp short(other), do: to_string(other)

  defp acquire(%{"acquisition_url" => url}) when is_binary(url), do: "fetch from #{url}"
  defp acquire(_), do: "no acquisition url recorded"
end
