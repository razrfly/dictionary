defmodule DevilsDictionary.Absorb.GzipLines do
  @moduledoc """
  Streams a gzipped, line-delimited file as decompressed lines in constant
  memory.

  The Wiktionary dump is 2.6 GB compressed and ~23 GB expanded against 27 GB of
  free disk, so #70 requires streaming it and never decompressing it to disk.
  This is `:zlib` in-process rather than a port to `gzip -dc` so that tests stay
  hermetic; Bierce and any later dump reuse it.

  Two traps are handled here so callers do not have to think about them:

    * **Partial lines.** A line almost never ends on a read-chunk boundary, so
      the incomplete tail is carried into the next chunk.
    * **Sub-binary retention.** `:binary.split/3` returns sub-binaries pointing
      into the ~2 MB parent chunk. Retaining one short lemma out of a batch pins
      the whole parent, which turns into gigabytes across a batched load. Decode
      with `Jason.decode!(line, strings: :copy)`, or copy the fields you keep.

  `:zlib.setBufSize/2` was removed in OTP 28; do not reach for it.
  """

  @read_chunk 256 * 1024

  @doc """
  Streams the decompressed lines of a gzip file, without their newlines.
  """
  @spec stream!(Path.t()) :: Enumerable.t()
  def stream!(path) do
    path
    |> File.stream!(@read_chunk)
    |> inflate()
    |> lines()
  end

  # 31 = 15 window bits + 16, which tells zlib to expect a gzip header.
  defp inflate(chunks) do
    Stream.transform(
      chunks,
      fn ->
        z = :zlib.open()
        :ok = :zlib.inflateInit(z, 31)
        z
      end,
      fn chunk, z -> {[drain(z, chunk, [])], z} end,
      fn z -> {[], z} end,
      fn z -> :zlib.close(z) end
    )
  end

  # safeInflate yields bounded slices; feed it "" to pull the rest of a chunk.
  defp drain(z, input, acc) do
    case :zlib.safeInflate(z, input) do
      {:continue, out} -> drain(z, "", [out | acc])
      {:finished, out} -> Enum.reverse([out | acc])
    end
  end

  defp lines(iodatas) do
    Stream.transform(
      iodatas,
      fn -> "" end,
      fn iodata, carry ->
        # n newlines always yield n+1 parts, so the last part is exactly the
        # incomplete tail.
        parts = :binary.split(IO.iodata_to_binary([carry, iodata]), "\n", [:global])
        {complete, [tail]} = Enum.split(parts, -1)
        {complete, tail}
      end,
      fn
        "" -> {[], ""}
        tail -> {[tail], ""}
      end,
      fn _ -> :ok end
    )
  end
end
