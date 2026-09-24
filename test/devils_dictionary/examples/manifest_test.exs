defmodule DevilsDictionary.Examples.ManifestTest do
  @moduledoc """
  Every committed exemplar manifest loads (its checksum is its contents) and
  every row passes the manifest's own validation, so a hand edit nobody
  stamped, or a person without evidence, is red here before it is a seed.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Examples.Manifest

  @paths Path.wildcard(Path.join(Manifest.dir(), "*.json"))

  test "there is at least one committed manifest" do
    assert Path.wildcard(Path.join(Manifest.dir(), "*.json")) != []
  end

  for path <- @paths do
    test "#{Path.basename(path)} loads and every row validates" do
      manifest = Manifest.load!(unquote(path))
      assert manifest["row_count"] == length(manifest["rows"])

      for {row, index} <- Enum.with_index(manifest["rows"], 1) do
        assert Manifest.validate_row(row) == :ok,
               "row #{index}: #{inspect(Manifest.validate_row(row))}"

        assert is_binary(row["subject"]["wikidata"]),
               "row #{index} names nobody by QID (#165 option 1)"
      end
    end
  end
end
