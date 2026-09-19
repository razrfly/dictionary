defmodule DevilsDictionary.Discovery.Conformance.PexelsFixture do
  @moduledoc """
  Conformance for `DevilsDictionary.Discovery.Providers.Pexels`.

  The rows are real ones, trimmed: what
  `https://api.pexels.com/v1/search?query=war` and `?query=soldier` answered
  on 2026-09-19, cut to the fields the provider reads
  (`docs/integrations/photos-probe-2026-09-19.md`). Every field that is there
  is spelled the way Pexels spells it — a numeric `id`, one `alt` sentence
  and no title, `photographer` and `photographer_url` at the top level, the
  `src` ladder as a map, and the malformed `next_page` the provider ignores.
  The image host is rewritten to `.test` so nothing in the suite can resolve;
  the paths and query strings are the real ones.

  Two rows are here to be more than a row:

    * **`99000001`** carries an empty `alt`. Pexels publishes no title and no
      description, so `alt` is the only thing a card could print and an item
      without one is an item the provider drops. `alt` was present on all 120
      live results measured, so the shape is constructed and the gate is real.

    * **`99000002`** carries a `src` of relative paths. A URL that is not an
      absolute `http(s)` one is not a picture that can be hotlinked (D14), and
      the provider drops it rather than rendering a broken frame.

  A same-photographer, same-title fold is **not** here, and its absence is
  the measurement: Pexels generates `alt` per photo, so one photographer's
  several frames on a page carry several different sentences and
  `Enum.uniq_by/2` on `{creator, title}` never fires. The rule stays in the
  provider because it belongs to the shelf's promise; the fixture does not
  pretend to exercise it.

  The external ids are written as literals rather than computed, so that
  changing how an item is identified breaks this suite instead of quietly
  agreeing with itself.
  """

  use DevilsDictionary.Discovery.Conformance.Fixture

  alias DevilsDictionary.Discovery.Providers.Pexels

  # `config/test.exs` sets `result_limit: 3`, so a page of this pipeline is
  # three rows asked for and however many survive the two gates.
  @page1_ids ~w(32230027 32955728)
  @page2_ids ~w(10932512 15957199)

  @impl true
  def provider, do: Pexels

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
    # No live word produced this: Pexels answered thousands of results for all
    # six probed words, `nepotism` included. `200` with an empty list is what
    # the API does return when it has nothing, and the pipeline's negative
    # cache is entitled to be tested against it.
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
    # the empty `alt`, the second to the unusable `src`.
    respond(rows())
    %{pages: [@page1_ids, @page2_ids]}
  end

  # Pexels's own envelope: `page`, `per_page`, `total_results`, `photos`, and
  # a `next_page` whose path segment is doubled. The stub reproduces the
  # malformed link on purpose — the provider must not follow it.
  defp respond(rows) do
    Req.Test.stub(Pexels, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      per_page = String.to_integer(conn.params["per_page"])
      page = String.to_integer(conn.params["page"] || "1")
      window = Enum.slice(rows, (page - 1) * per_page, per_page)

      Req.Test.json(conn, %{
        "page" => page,
        "per_page" => per_page,
        "total_results" => length(rows),
        "next_page" =>
          "https://api.pexels.test/v1/v1/search?page=#{page + 1}&per_page=#{per_page}",
        "photos" => window
      })
    end)
  end

  defp rows do
    [
      photo(
        32_230_027,
        "Desolate war-damaged building in Homs, Syria, with a truck in foreground.",
        "Waseem Istanbuli",
        "waseem-istanbuli-2149205866",
        "war-torn-building-in-homs-syria"
      ),
      photo(
        32_955_728,
        "A glimpse into life amid the ruins of war-torn Damascus, Syria, showing resilience and survival.",
        "Noor Aldin  Alwan",
        "noor-aldin-alwan-193019921",
        "war-torn-streets-of-damascus-syria"
      ),
      # Nothing a card could print.
      photo(99_000_001, "", "No Caption", "no-caption-1", "untitled"),
      photo(
        10_932_512,
        "View of destroyed buildings on a deserted street in Homs, Syria under a clear blue sky.",
        "ali Saleh",
        "ali-saleh-167142549",
        "dirt-road-between-ruined-buildings-under-a-blue-sky"
      ),
      photo(
        15_957_199,
        "Soldiers in uniform during a ceremonial march showcasing precision and discipline.",
        "Barış  Karagöz",
        "baris",
        "soldiers-in-uniforms-marching"
      ),
      # Nothing that can be hotlinked.
      99_000_002
      |> photo("A photo whose files are not absolute URLs", "Relative", "relative-1", "relative")
      |> Map.put("src", %{"medium" => "/photos/99000002/medium.jpeg", "original" => "not a url"})
    ]
  end

  defp photo(id, alt, photographer, handle, slug) do
    file = "https://images.pexels.test/photos/#{id}/pexels-photo-#{id}.jpeg"

    %{
      "id" => id,
      "alt" => alt,
      "width" => 2268,
      "height" => 4032,
      "avg_color" => "#68757B",
      "photographer" => photographer,
      "photographer_url" => "https://www.pexels.com/@#{handle}",
      "url" => "https://www.pexels.com/photo/#{slug}-#{id}/",
      "src" => %{
        "original" => file,
        "large2x" => "#{file}?auto=compress&cs=tinysrgb&dpr=2&h=650&w=940",
        "large" => "#{file}?auto=compress&cs=tinysrgb&h=650&w=940",
        "medium" => "#{file}?auto=compress&cs=tinysrgb&h=350",
        "small" => "#{file}?auto=compress&cs=tinysrgb&h=130",
        "tiny" => "#{file}?auto=compress&cs=tinysrgb&dpr=1&fit=crop&h=200&w=280"
      }
    }
  end
end
