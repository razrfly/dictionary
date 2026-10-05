defmodule DevilsDictionary.Installation.Files do
  @moduledoc """
  Files described by size and SHA-256, and a copy that resumes.

  A transfer of several gigabytes is interrupted sometimes. `copy/3` writes
  to `DEST.partial`, appends to whatever a previous attempt left there, and
  renames into place only once the whole file's SHA-256 equals the digest it
  was asked to produce. A partial file that does not lead to that digest — a
  different source, or a corrupted tail — is discarded and the copy starts
  over once; a second failure is reported, never renamed into place.

  An existing destination is never overwritten. If it already has the
  expected digest the copy is a no-op (a repeated setup); otherwise it is
  refused as conflicting state.
  """

  @chunk 8 * 1024 * 1024

  @doc "`%{\"bytes\" => size, \"sha256\" => hex}` of a file, streamed."
  def fingerprint(path) do
    %{"bytes" => File.stat!(path).size, "sha256" => sha256(path)}
  end

  @doc "The SHA-256 of a file, streamed, lowercase hex."
  def sha256(path) do
    path
    |> File.stream!(@chunk)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Whether `path` is the file `expected` describes. `deep: false` compares
  only the size — a truncated or missing file, cheaply — and says so.

  `:ok`, or `{:error, :missing | {:size, expected, actual} | {:sha256, expected, actual}}`.
  """
  def check(path, %{"bytes" => bytes, "sha256" => sha}, opts \\ []) do
    case File.stat(path) do
      {:error, _} ->
        {:error, :missing}

      {:ok, %{type: type}} when type != :regular ->
        {:error, :missing}

      {:ok, %{size: ^bytes}} ->
        if Keyword.get(opts, :deep, true) do
          actual = sha256(path)
          if actual == sha, do: :ok, else: {:error, {:sha256, sha, actual}}
        else
          :ok
        end

      {:ok, %{size: actual}} ->
        {:error, {:size, bytes, actual}}
    end
  end

  @doc "A `check/3` failure as an operator reads it."
  def describe(:missing), do: "missing"
  def describe(:outside_bundle), do: "a path outside the bundle"
  def describe({:size, expected, actual}), do: "#{actual} bytes, expected #{expected}"

  def describe({:sha256, expected, actual}),
    do: "SHA-256 #{String.slice(actual, 0, 12)}…, expected #{String.slice(expected, 0, 12)}…"

  @doc """
  Copies `source` to `dest` so that `dest` ends up exactly `expected`
  (`%{"bytes", "sha256"}`), resuming a partial copy. The source is checked
  first, so a damaged source is never copied.

  Returns `{:ok, :copied | :resumed | :present}` or `{:error, message}`.
  """
  def copy(source, dest, expected) do
    partial = dest <> ".partial"

    cond do
      File.exists?(dest) ->
        case check(dest, expected) do
          :ok ->
            {:ok, :present}

          {:error, reason} ->
            {:error,
             "#{dest} already exists and is not the expected file (#{describe(reason)}); " <>
               "refusing to overwrite it"}
        end

      true ->
        with :ok <- source_ok(source, expected) do
          File.mkdir_p!(Path.dirname(dest))
          resumed? = File.exists?(partial)
          attempt(source, dest, partial, expected, resumed?, 2)
        end
    end
  end

  defp source_ok(source, expected) do
    case check(source, expected, deep: false) do
      :ok -> :ok
      {:error, reason} -> {:error, "#{source} is not the file to copy (#{describe(reason)})"}
    end
  end

  defp attempt(_source, dest, _partial, _expected, _resumed?, 0),
    do: {:error, "#{dest}: the copy does not reproduce the expected SHA-256; nothing was renamed"}

  defp attempt(source, dest, partial, expected, resumed?, tries) do
    append(source, partial)

    case check(partial, expected) do
      :ok ->
        File.rename!(partial, dest)
        {:ok, if(resumed?, do: :resumed, else: :copied)}

      {:error, _reason} ->
        # A partial from another source, or a corrupted tail: start over.
        File.rm!(partial)
        attempt(source, dest, partial, expected, false, tries - 1)
    end
  end

  # Appends whatever of `source` lies beyond `partial`'s current length.
  defp append(source, partial) do
    offset =
      case File.stat(partial) do
        {:ok, %{size: size}} -> size
        _ -> 0
      end

    {:ok, input} = File.open(source, [:read, :binary, :raw])
    {:ok, output} = File.open(partial, [:append, :binary, :raw])

    try do
      {:ok, _} = :file.position(input, offset)
      pump(input, output)
    after
      File.close(input)
      File.close(output)
    end
  end

  defp pump(input, output) do
    case :file.read(input, @chunk) do
      :eof ->
        :ok

      {:error, reason} ->
        raise "read failed: #{inspect(reason)}"

      {:ok, data} ->
        :ok = :file.write(output, data)
        pump(input, output)
    end
  end

  @doc """
  Writes `content` to `path` atomically: a partial file renamed into place,
  so a reader sees the old file or the whole new one.
  """
  def write_atomic!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    partial = path <> ".partial"
    File.write!(partial, content)
    File.rename!(partial, path)
    path
  end
end
