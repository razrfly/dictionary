defmodule DevilsDictionary.Artworks.Corpus.CommittedRowTest do
  @moduledoc """
  `Manifest.committed_row/2` is the boundary where a curated opening (#156)
  reads the catalog row a selection pinned. A committed manifest found missing,
  malformed, tampered or of an unsupported schema answers `nil` — which the
  reader withholds as `:catalog_changed` — instead of raising inside a page
  render (CodeRabbit on PR #202).

  `async: false` because the root is application config. Every test gets its
  own `tmp_dir`, and the root is part of the memo's key, so every read here is
  a cold one.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  import DevilsDictionary.OpeningFixtures, only: [committed_manifest!: 2, unreadable_manifests: 0]

  alias DevilsDictionary.Artworks.Corpus.Manifest

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: root} do
    previous = Application.get_env(:devils_dictionary, :committed_manifest_root)
    Application.put_env(:devils_dictionary, :committed_manifest_root, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:devils_dictionary, :committed_manifest_root, previous),
        else: Application.delete_env(:devils_dictionary, :committed_manifest_root)
    end)
  end

  test "an exact copy of the committed manifest answers its row", %{tmp_dir: root} do
    committed_manifest!(root, :valid)

    assert %{"qid" => "Q8777422", "title" => "Cupid and Psyche"} =
             Manifest.committed_row("wikidata-famous-v1", "Q8777422")

    assert is_nil(Manifest.committed_row("wikidata-famous-v1", "Q0"))
  end

  test "the application's own priv/ still answers when no root is configured" do
    Application.delete_env(:devils_dictionary, :committed_manifest_root)

    assert %{"qid" => "Q8777422"} = Manifest.committed_row("wikidata-famous-v1", "Q8777422")
  end

  for variant <- unreadable_manifests() do
    test "a #{variant} manifest answers nil rather than raising, on a cold read",
         %{tmp_dir: root} do
      # Warm the real priv/ first: a good memo elsewhere must not mask a bad file here.
      Application.delete_env(:devils_dictionary, :committed_manifest_root)
      assert %{"qid" => "Q8777422"} = Manifest.committed_row("wikidata-famous-v1", "Q8777422")
      Application.put_env(:devils_dictionary, :committed_manifest_root, root)

      committed_manifest!(root, unquote(variant))

      log =
        capture_log(fn ->
          assert is_nil(Manifest.committed_row("wikidata-famous-v1", "Q8777422"))
          # Asked again, the memoised answer is the same, and still no raise.
          assert is_nil(Manifest.committed_row("wikidata-famous-v1", "Q8777422"))
        end)

      # Said once, when the memo is filled — not on every render.
      assert length(String.split(log, "wikidata-famous-v1 is unusable")) == 2
    end
  end

  test "load/1 names each failure; load!/1 still raises as before", %{tmp_dir: root} do
    expected = %{
      missing: {:error, {:unreadable, :enoent}},
      malformed: {:error, :malformed},
      invalid_checksum: {:error, :checksum_mismatch},
      unsupported_schema: {:error, :unsupported},
      unsupported_shape: {:error, :unsupported}
    }

    for {variant, result} <- expected do
      path = committed_manifest!(root, variant)
      assert Manifest.load(path) == result, "#{variant}"
    end

    path = committed_manifest!(root, :invalid_checksum)
    assert_raise ArgumentError, ~r/checksum mismatch/, fn -> Manifest.load!(path) end

    path = committed_manifest!(root, :unsupported_schema)
    assert_raise ArgumentError, ~r/unsupported corpus manifest/, fn -> Manifest.load!(path) end

    path = committed_manifest!(root, :valid)
    assert {:ok, %{"manifest" => "wikidata-famous-v1"}} = Manifest.load(path)
    assert %{"manifest" => "wikidata-famous-v1"} = Manifest.load!(path)
  end
end
