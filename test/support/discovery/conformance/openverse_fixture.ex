defmodule DevilsDictionary.Discovery.Conformance.OpenverseFixture do
  @moduledoc """
  Conformance for `DevilsDictionary.Discovery.Providers.Openverse`.

  The rows are real ones, trimmed: what
  `https://api.openverse.org/v1/images/?q="war"` answered on 2026-09-19, cut
  to the fields the provider reads
  (`docs/integrations/photos-probe-2026-09-19.md`). Every field that is there
  is spelled the way Openverse spells it — `license` without its `cc-` prefix,
  `license_version` apart from it, `attribution` already composed, `thumbnail`
  a proxy URL on `api.openverse.org` and `url` the upstream file.

  Three rows are here to be more than a row:

    * **`086e0224-…`** is `by-nc-nd`, a real result for *soldier*. The search
      narrows `license` to `cc0,pdm,by,by-sa`, so this row is one the API
      should never send — and the provider drops it anyway, because the gate
      belongs on the object and not on the query that found it. A provider
      that started trusting the parameter would still pass its own suite; it
      would not pass this one.

    * **`da6a88c7-…`** is a real `source: "wikimedia"` result, with one edit:
      its `curid` is **1001**, which is the pageid
      `DevilsDictionary.Discovery.Conformance.CommonsFixture` gives its first
      kept file. That is the shared file M3 needs on real fixtures, and it is
      constructed rather than found — the Commons fixture's files are
      synthetic, so there is no live pageid the two could share. Its *shape*
      is real, which is the part the fold depends on: Openverse writes a
      Commons file's landing page as `…/w/index.php?curid=<pageid>` and that
      pageid is exactly the `commons_file` external id Commons registers.
      `openverse_commons_fold_test.exs` asserts the two copies become one item.

    * **`0ea589cc-…` and `30f952b5-…`** are two real results on one page that
      share a creator and a title: two frames of one evening, uploaded by one
      photographer, with different ids and different Flickr URLs. `Shelf`
      cannot fold them — they are not the same file — so the provider does,
      one card per upload. Measured on `/define/war`, where eight of the
      twelve Openverse items were this photographer's *War Horse*.

  The external ids are written as literals rather than computed, so that
  changing how an item is identified breaks this suite instead of quietly
  agreeing with itself.
  """

  use DevilsDictionary.Discovery.Conformance.Fixture

  alias DevilsDictionary.Discovery.Providers.Openverse

  @doc "The Commons pageid the shared row names, which `CommonsFixture` also holds."
  def shared_commons_pageid, do: "1001"

  @doc "The Openverse id of the item that aggregates that Commons file."
  def shared_openverse_id, do: "da6a88c7-a13d-4194-abcc-33df99e352c6"

  # `config/test.exs` sets `result_limit: 3`, so a page of this pipeline is
  # three rows asked for and however many survive the licence gate.
  @page1_ids ~w(c80387bb-2dd9-489e-a748-75a1be138f5a da6a88c7-a13d-4194-abcc-33df99e352c6)
  @page2_ids ~w(0a8fdfa0-b192-45a8-a0a8-cb6e1be4e649 0ea589cc-1be1-41ff-a45b-fa9f05dd8d23)

  @impl true
  def provider, do: Openverse

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
    # A word Openverse has nothing for: `200` with an empty list and a zero
    # count. A negative cache, not a failure — and a search provider declines
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
    # the licence gate, the second to the upload fold.
    respond(rows())
    %{pages: [@page1_ids, @page2_ids]}
  end

  # Openverse's own envelope: `result_count`, `page_count`, `page`, `results`.
  # The stub honours `page` and `page_size` the way the API does, and reports
  # the page count the rows it holds would make.
  defp respond(rows) do
    Req.Test.stub(Openverse, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      page_size = String.to_integer(conn.params["page_size"])
      page = String.to_integer(conn.params["page"] || "1")
      window = Enum.slice(rows, (page - 1) * page_size, page_size)

      Req.Test.json(conn, %{
        "result_count" => length(rows),
        "page_count" => ceil(length(rows) / page_size),
        "page" => page,
        "page_size" => page_size,
        "results" => window
      })
    end)
  end

  defp rows do
    [
      flickr(
        "c80387bb-2dd9-489e-a748-75a1be138f5a",
        "war",
        "zbigphotography (1M+ views)",
        "45098669@N06",
        "5925721278",
        "6144/5925721278_13ba42c54d_b.jpg",
        "by-sa",
        "2.0"
      ),
      # The shared file: real row, `curid` set to the Commons fixture's 1001.
      wikimedia(
        "da6a88c7-a13d-4194-abcc-33df99e352c6",
        "Libyan Civil War",
        "Ali Zifan (vectorized map)",
        "https://commons.wikimedia.org/wiki/User:Ali_Zifan",
        shared_commons_pageid(),
        "a/ad/Libyan_Civil_War.svg",
        "by-sa",
        "4.0"
      ),
      # Gated out on its own licence, although the search asked for four others.
      flickr(
        "086e0224-d94a-4f8d-b567-f9e656ecc999",
        "Israel soldiers beat journalists to transfer real",
        "` ³ok_qa³ `",
        "34984457@N08",
        "4466779316",
        "4055/4466779316_4056aca1a8_b.jpg",
        "by-nc-nd",
        "2.0"
      ),
      flickr(
        "0a8fdfa0-b192-45a8-a0a8-cb6e1be4e649",
        "war",
        "Gorod - SKY",
        "77837276@N00",
        "3219099545",
        "3304/3219099545_898b0e49f0_b.jpg",
        "by",
        "2.0"
      ),
      # Two frames of one evening by one photographer, which the shelf cannot
      # tell apart and the provider can.
      flickr(
        "0ea589cc-1be1-41ff-a45b-fa9f05dd8d23",
        "War Horse",
        "Eva Rinaldi Celebrity Photographer",
        "58820009@N05",
        "8571125136",
        "8233/8571125136_dae35de4eb_b.jpg",
        "by-sa",
        "2.0"
      ),
      flickr(
        "30f952b5-31f6-4a33-9e26-3769ef51a3c1",
        "War Horse",
        "Eva Rinaldi Celebrity Photographer",
        "58820009@N05",
        "8570054371",
        "8369/8570054371_00b7dd95ef_b.jpg",
        "by-sa",
        "2.0"
      )
    ]
  end

  defp flickr(id, title, creator, account, photo, path, license, version) do
    row(
      id,
      title,
      creator,
      "https://www.flickr.com/photos/#{account}",
      "flickr",
      license,
      version
    )
    |> Map.merge(%{
      "foreign_landing_url" => "https://www.flickr.com/photos/#{account}/#{photo}",
      # `live.staticflickr.com/<server>/<id>_<secret>_b.jpg` — the "large" size,
      # which is what Openverse hands back as the upstream URL.
      "url" => "https://live.staticflickr.com/#{path}"
    })
  end

  defp wikimedia(id, title, creator, creator_url, pageid, path, license, version) do
    row(id, title, creator, creator_url, "wikimedia", license, version)
    |> Map.merge(%{
      "foreign_landing_url" => "https://commons.wikimedia.org/w/index.php?curid=#{pageid}",
      "url" => "https://upload.wikimedia.org/wikipedia/commons/#{path}"
    })
  end

  defp row(id, title, creator, creator_url, source, license, version) do
    %{
      "id" => id,
      "title" => title,
      "creator" => creator,
      "creator_url" => creator_url,
      "source" => source,
      "provider" => source,
      "license" => license,
      "license_version" => version,
      "license_url" => "https://creativecommons.org/licenses/#{license}/#{version}/",
      "thumbnail" => "https://openverse.test/v1/images/#{id}/thumb/",
      "attribution" =>
        ~s("#{title}" by #{creator} is licensed under ) <>
          "#{license |> String.upcase() |> then(&"CC #{&1}")} #{version}. " <>
          "To view a copy of this license, visit https://creativecommons.org/licenses/#{license}/#{version}/.",
      "fields_matched" => ["title"],
      "mature" => false
    }
  end
end
