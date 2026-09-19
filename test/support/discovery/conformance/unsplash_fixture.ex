defmodule DevilsDictionary.Discovery.Conformance.UnsplashFixture do
  @moduledoc """
  Conformance for `DevilsDictionary.Discovery.Providers.Unsplash`.

  The rows are real ones, trimmed: what
  `https://api.unsplash.com/search/photos?query=war` and `?query=soldier`
  answered on 2026-09-19, cut to the fields the provider reads
  (`docs/integrations/photos-probe-2026-09-19.md`). Every field that is there
  is spelled the way Unsplash spells it — `description` and
  `alt_description` apart, the `urls` ladder as a map, `links.html` and
  `links.download_location` under `links`, the photographer under `user`.
  The image hosts are rewritten to `.test` so nothing in the suite can
  resolve; the paths and query strings are the real ones, because the query
  string is what `Shelf.canonical_media_url/1` is supposed to ignore.

  Three rows are here to be more than a row:

    * **`noTitle00000`** carries neither `description` nor `alt_description`.
      Unsplash publishes no title, so those two fields are the only thing a
      card could print, and an item with neither is an item the provider
      drops. No such row was found in 120 live results — the shape is
      constructed, the gate is real, and a provider that started printing a
      slug instead would fail this suite.

    * **`ExxuYNsViC4` and `0q90Mumo-xE`** are two real results on one page of
      *soldier* that share a photographer and an identical `description`
      (trailing tab and all): two frames of one shoot with different ids and
      different files. `Shelf.dedup/2` cannot fold them — they are not the
      same file — so the provider does, one card per upload.

    * **`LheHIV3XpGM`** carries the `links.download_location` the licence's
      download trigger uses. `unsplash_test.exs` asserts that
      `track_download/2` will call that URL and refuses anything outside
      `https://api.unsplash.com/photos/`, and that nothing on a page calls it.

  The external ids are written as literals rather than computed, so that
  changing how an item is identified breaks this suite instead of quietly
  agreeing with itself.
  """

  use DevilsDictionary.Discovery.Conformance.Fixture

  alias DevilsDictionary.Discovery.Providers.Unsplash

  @doc "The photo whose `download_location` the trigger test drives."
  def download_trigger_id, do: "LheHIV3XpGM"

  # `config/test.exs` sets `result_limit: 3`, so a page of this pipeline is
  # three rows asked for and however many survive the title gate and the fold.
  @page1_ids ~w(LheHIV3XpGM aO9nGw9Cbk0)
  @page2_ids ~w(dP5ZbhnVIFo ExxuYNsViC4)

  @impl true
  def provider, do: Unsplash

  @impl true
  def covered_target(context) do
    word = word!(context, "war", ~w(wordnet))

    %{
      object_id: word.object_id,
      term: word.lemma,
      language: word.language_tag,
      relevance: "term"
    }
  end

  @impl true
  def stub(:empty, _context) do
    # A word Unsplash has nothing for: `200` with an empty list and a zero
    # total. A negative cache, not a failure — and a search provider declines
    # nothing, so this is the only empty it has.
    respond([])
    %{pages: [[]]}
  end

  def stub(:results, _context) do
    # Two rows against a `result_limit` of three: a short page, so pagination
    # ends rather than promising a page with nothing behind it.
    respond(Enum.take(rows(), 2))
    %{pages: [Enum.take(@page1_ids, 2)]}
  end

  def stub(:paged, _context) do
    # Six rows, two windows of three, and each window loses one: the first to
    # the title gate, the second to the upload fold.
    respond(rows())
    %{pages: [@page1_ids, @page2_ids]}
  end

  # Unsplash's own envelope: `total`, `total_pages`, `results`. The stub
  # honours `page` and `per_page` the way the API does, and reports the page
  # count the rows it holds would make.
  defp respond(rows) do
    Req.Test.stub(Unsplash, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      per_page = String.to_integer(conn.params["per_page"])
      page = String.to_integer(conn.params["page"] || "1")
      window = Enum.slice(rows, (page - 1) * per_page, per_page)

      Req.Test.json(conn, %{
        "total" => length(rows),
        "total_pages" => ceil(length(rows) / per_page),
        "results" => window
      })
    end)
  end

  defp rows do
    [
      photo(
        "LheHIV3XpGM",
        "1580922110301-a666f6745565",
        "Ruined side-street in Shingal (Sinjar) following war with the Islamic State.",
        "A narrow street in Sinjar lined with ruined stone buildings and piles of rubble",
        "2020-02-05T17:15:19Z",
        "ruined-street-in-sinjar",
        "Levi Meir Clancy",
        "levimeirclancy"
      ),
      photo(
        "aO9nGw9Cbk0",
        "1643275590906-e44bbef1a543",
        "There is nothing left in this place",
        "a man walking down a dirt road between two buildings",
        "2022-01-27T09:28:28Z",
        "a-man-walking-down-a-dirt-road-between-two-buildings",
        "Mahmoud Sulaiman",
        "mahmoud_ms1"
      ),
      # Nothing a card could print: Unsplash has no title, and both fields
      # that stand in for one are absent.
      photo(
        "noTitle00000",
        "1580000000000-000000000000",
        nil,
        nil,
        "2021-03-03T00:00:00Z",
        "untitled",
        "No Caption",
        "nocaption"
      ),
      photo(
        "dP5ZbhnVIFo",
        "1541872703-74c5e44368f9",
        "Soldiers dressed in army camouflage march in formation.",
        "a group of soldiers marching in formation",
        "2018-10-10T12:20:00Z",
        "soldiers-marching-in-formation",
        "Filip Andrejevic",
        "filipandrejevic"
      ),
      # Two frames of one shoot by one photographer, which the shelf cannot
      # tell apart and the provider can. The trailing tab is Unsplash's.
      photo(
        "ExxuYNsViC4",
        "flagged/photo-1560177776-55a762c5c000",
        "special forces soldier police, swat team member\t",
        "A person in black tactical gear and a face mask holding a rifle",
        "2019-06-10T14:43:11Z",
        "person-in-black-tactical-gear",
        "HIZIR KAYA",
        "santoelia"
      ),
      photo(
        "0q90Mumo-xE",
        "flagged/photo-1560177776-295b9cd779de",
        "special forces soldier police, swat team member\t",
        "man holding rifle wallpaper",
        "2019-06-10T14:43:11Z",
        "man-holding-rifle-wallpaper",
        "HIZIR KAYA",
        "santoelia"
      )
    ]
  end

  defp photo(id, file, description, alt, created_at, slug, name, username) do
    # The real shape: `flagged/photo-…` files keep their prefix, ordinary ones
    # are `photo-…` under the CDN root.
    path = if String.starts_with?(file, "flagged/"), do: file, else: "photo-#{file}"
    ixid = "M3w3MjU0ODR8MHwxfHNlYXJjaHwxfHx3YXJ8ZW58MHx8fHwxNzg5ODA3MzUxfDA"

    %{
      "id" => id,
      "slug" => "#{slug}-#{id}",
      "description" => description,
      "alt_description" => alt,
      "created_at" => created_at,
      "asset_type" => "photo",
      "sponsorship" => nil,
      "urls" => %{
        "small" =>
          "https://images.unsplash.test/#{path}?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=#{ixid}&ixlib=rb-4.1.0&q=80&w=400",
        "regular" =>
          "https://images.unsplash.test/#{path}?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=#{ixid}&ixlib=rb-4.1.0&q=80&w=1080",
        "full" =>
          "https://images.unsplash.test/#{path}?crop=entropy&cs=srgb&fm=jpg&ixid=#{ixid}&ixlib=rb-4.1.0&q=85",
        "raw" => "https://images.unsplash.test/#{path}?ixid=#{ixid}&ixlib=rb-4.1.0"
      },
      "links" => %{
        "html" => "https://unsplash.com/photos/#{slug}-#{id}",
        "download_location" => "https://api.unsplash.com/photos/#{id}/download?ixid=#{ixid}"
      },
      "user" => %{
        "name" => name,
        "username" => username,
        "links" => %{"html" => "https://unsplash.com/@#{username}"}
      }
    }
  end
end
