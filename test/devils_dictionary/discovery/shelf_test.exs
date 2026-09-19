defmodule DevilsDictionary.Discovery.ShelfTest do
  @moduledoc """
  The two rules a many-source shelf needs and the artworks shelf got for free
  from identity (#116 M2, M3): the order across sources and the duplicates
  between them, content-type-neutral and computed at read time.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Discovery.Shelf

  describe "interleave/3 — turns across sources within a group" do
    test "takes item 1 from every source, then item 2, sources by tier then slug" do
      items =
        [
          # Registered plebs-first with the alphabetically earlier slug, so
          # neither arrival order nor slug order can be what wins.
          {:live, {2, "aa"}, "p1"},
          {:live, {2, "aa"}, "p2"},
          {:live, {2, "aa"}, "p3"},
          {:live, {1, "zz"}, "m1"},
          {:live, {1, "zz"}, "m2"},
          {:live, {0, "kk"}, "a1"}
        ]
        |> Enum.map(fn {group, source, id} -> %{group: group, source: source, id: id} end)

      assert Shelf.interleave(items, & &1.group, & &1.source) |> Enum.map(& &1.id) ==
               ~w(a1 m1 p1 m2 p2 p3)
    end

    test "keeps live before corpus, and each source's own order within its turns" do
      items =
        [
          {1, {1, "met"}, "c-met-1"},
          {1, {1, "wikidata"}, "c-wd-1"},
          {1, {1, "met"}, "c-met-2"},
          {1, {1, "wikidata"}, "c-wd-2"},
          {0, {1, "met"}, "live-1"},
          {0, {1, "met"}, "live-2"}
        ]
        |> Enum.map(fn {group, source, id} -> %{group: group, source: source, id: id} end)

      assert Shelf.interleave(items, & &1.group, & &1.source) |> Enum.map(& &1.id) ==
               ~w(live-1 live-2 c-met-1 c-wd-1 c-met-2 c-wd-2)
    end

    test "one source is its own order, and no sources is no shelf" do
      one = Enum.map(~w(x y z), &%{id: &1})
      assert Shelf.interleave(one, fn _ -> 0 end, fn _ -> {1, "one"} end) == one
      assert Shelf.interleave([], fn _ -> 0 end, fn _ -> {1, "one"} end) == []
    end

    test "an unnamed tier sorts after every named one" do
      assert Shelf.tier_rank(:aristocracy) < Shelf.tier_rank(:middle)
      assert Shelf.tier_rank(:middle) < Shelf.tier_rank(:plebs)
      assert Shelf.tier_rank(:plebs) < Shelf.tier_rank(nil)
      assert Shelf.tier_rank(nil) == Shelf.tier_rank(:unknown)
    end
  end

  describe "dedup/2 — one item per identity, first wins" do
    test "a shared identifier namespace folds two providers' copies into one" do
      commons = %{
        external_namespace: "commons_file",
        external_id: "123",
        identifiers: [%{namespace: "commons_file", external_id: "123"}],
        preview_metadata: %{"image_url" => "https://upload.wikimedia.org/a/b/File.jpg"}
      }

      # An aggregator that names the file it came from, under a different id
      # of its own and a thumbnail of its own. The identifiers it proposed come
      # back string-keyed from the source record's payload.
      openverse = %{
        external_namespace: "openverse_media",
        external_id: "uuid-1",
        identifiers: [%{"namespace" => "commons_file", "external_id" => "123"}],
        preview_metadata: %{"image_url" => "https://api.openverse.org/v1/images/uuid-1/thumb/"}
      }

      assert Shelf.dedup([commons, openverse]) == [commons]
      assert Shelf.dedup([openverse, commons]) == [openverse]
    end

    test "a shared canonical media URL folds two ids with no identity in common" do
      a = %{
        external_namespace: "a",
        external_id: "1",
        preview_metadata: %{"image_url" => "https://cdn.example.org/photos/1.jpg"}
      }

      b = %{
        external_namespace: "b",
        external_id: "9",
        preview_metadata: %{"image_url" => "HTTP://CDN.example.org/photos/1.jpg?w=640#top"}
      }

      assert Shelf.dedup([a, b]) == [a]
    end

    test "a resolved registry object is an identity too" do
      live = %{external_namespace: "met_object", external_id: "11417", object_id: 77}
      catalog = %{external_namespace: "catalog_artwork", external_id: "c77", object_id: 77}
      other = %{external_namespace: "catalog_artwork", external_id: "c78", object_id: 78}

      assert Shelf.dedup([live, catalog, other]) == [live, other]
    end

    test "the thumbnail is never a join key" do
      # Two different works can share a provider's placeholder thumbnail; two
      # copies of one work never share a thumbnail across providers. Neither
      # is what the media rule is for.
      a = %{
        external_namespace: "a",
        external_id: "1",
        preview_metadata: %{"thumbnail_url" => "https://x/t.jpg"}
      }

      b = %{
        external_namespace: "a",
        external_id: "2",
        preview_metadata: %{"thumbnail_url" => "https://x/t.jpg"}
      }

      assert Shelf.dedup([a, b]) == [a, b]
    end

    test "a dropped duplicate's keys join the kept item's" do
      a = %{
        external_namespace: "a",
        external_id: "1",
        identifiers: [%{namespace: "up", external_id: "s"}]
      }

      b = %{
        external_namespace: "b",
        external_id: "1",
        identifiers: [%{namespace: "up", external_id: "s"}],
        preview_metadata: %{"image_url" => "https://cdn/x.jpg"}
      }

      c = %{
        external_namespace: "c",
        external_id: "1",
        preview_metadata: %{"image_url" => "https://cdn/x.jpg"}
      }

      assert Shelf.dedup([a, b, c]) == [a]
    end

    test "an item with no keys at all is always kept, and a caller may key however it likes" do
      assert Shelf.dedup([%{}, %{}]) == [%{}, %{}]

      candidates = [%{artwork: %{object_id: 1}, sense: 1}, %{artwork: %{object_id: 1}, sense: 2}]

      assert Shelf.dedup(candidates, &[{:object, &1.artwork.object_id}]) ==
               [%{artwork: %{object_id: 1}, sense: 1}]
    end
  end

  describe "canonical_media_url/1" do
    test "lower-cases the host, drops scheme, port, query, fragment and a trailing slash" do
      assert Shelf.canonical_media_url("HTTPS://Upload.Example.org:443/a/B.jpg?w=1#x") ==
               "upload.example.org/a/B.jpg"

      assert Shelf.canonical_media_url("http://upload.example.org/a/B.jpg/") ==
               "upload.example.org/a/B.jpg"
    end

    test "is nil for anything without a host" do
      assert Shelf.canonical_media_url("/relative/path.jpg") == nil
      assert Shelf.canonical_media_url("not a url") == nil
      assert Shelf.canonical_media_url(nil) == nil
      assert Shelf.canonical_media_url("") == nil
    end
  end

  describe "compose/4" do
    test "sorts, dedups in that order so the better-tiered copy survives, then takes turns" do
      shared = %{"image_url" => "https://cdn/shared.jpg"}

      entries = [
        %{
          group: 0,
          source: {2, "plebs"},
          item: %{external_namespace: "p", external_id: "1", preview_metadata: shared}
        },
        %{
          group: 0,
          source: {2, "plebs"},
          item: %{external_namespace: "p", external_id: "2", preview_metadata: %{}}
        },
        %{
          group: 0,
          source: {1, "middle"},
          item: %{external_namespace: "m", external_id: "1", preview_metadata: shared}
        },
        %{
          group: 0,
          source: {1, "middle"},
          item: %{external_namespace: "m", external_id: "2", preview_metadata: %{}}
        }
      ]

      assert Shelf.compose(entries, & &1.group, & &1.source, &Shelf.keys(&1.item))
             |> Enum.map(&"#{&1.item.external_namespace}#{&1.item.external_id}") ==
               ~w(m1 p2 m2)
    end
  end
end
