defmodule DevilsDictionary.Absorb.GzipLinesTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Absorb.GzipLines

  @moduletag :tmp_dir

  defp gz!(dir, content) do
    path = Path.join(dir, "sample.gz")
    File.write!(path, :zlib.gzip(content))
    path
  end

  test "reads every line of a small file", %{tmp_dir: dir} do
    path = gz!(dir, "one\ntwo\nthree\n")
    assert GzipLines.stream!(path) |> Enum.to_list() == ["one", "two", "three"]
  end

  test "emits a final line with no trailing newline", %{tmp_dir: dir} do
    path = gz!(dir, "one\ntwo")
    assert GzipLines.stream!(path) |> Enum.to_list() == ["one", "two"]
  end

  test "an empty file yields nothing", %{tmp_dir: dir} do
    path = gz!(dir, "")
    assert GzipLines.stream!(path) |> Enum.to_list() == []
  end

  test "reassembles lines split across read chunks", %{tmp_dir: dir} do
    # Each line is ~10 KB and the read chunk is 256 KB, so lines straddle
    # boundaries repeatedly.
    lines = for i <- 1..500, do: "#{i}:" <> String.duplicate("x", 10_000)
    path = gz!(dir, Enum.join(lines, "\n") <> "\n")

    assert GzipLines.stream!(path) |> Enum.to_list() == lines
  end

  test "handles a single line larger than the read chunk", %{tmp_dir: dir} do
    line = String.duplicate("y", 1_000_000)
    path = gz!(dir, line <> "\n")

    assert GzipLines.stream!(path) |> Enum.to_list() == [line]
  end

  test "streams lazily rather than materialising the file", %{tmp_dir: dir} do
    lines = for i <- 1..10_000, do: "line-#{i}"
    path = gz!(dir, Enum.join(lines, "\n") <> "\n")

    assert GzipLines.stream!(path) |> Enum.take(3) == ["line-1", "line-2", "line-3"]
  end
end
