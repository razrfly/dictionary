defmodule DevilsDictionary.Quotations.Corpus.BuildTest do
  @moduledoc """
  The corpus build (#174) against captured answers
  (`QuotesCorpusFixtures`). No network and no database writes.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias DevilsDictionary.Quotations.Corpus.Build
  alias DevilsDictionary.QuotesCorpusFixtures, as: Fixtures
  alias DevilsDictionary.WikiquoteFixtures
  alias Mix.Tasks.Dd.Quotes.Corpus.Build, as: Task

  @candide Fixtures.candide()
  @voltaire WikiquoteFixtures.body("voltaire")
  @endpoints Fixtures.endpoints()

  defp stub(pid, candide \\ @candide), do: Fixtures.stub(pid, candide)
  defp build(opts), do: Fixtures.build(opts)

  defp uri(qid), do: %{"type" => "uri", "value" => "http://www.wikidata.org/entity/#{qid}"}
  defp lit(value), do: %{"type" => "literal", "value" => value}

  defp drain(acc \\ []) do
    receive do
      {:request, url} -> drain([url | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "keeps only Verified lines, each with its work, year, locator and revision" do
    {:ok, rows, selection, ledger} = build([])

    assert rows != []
    assert Enum.all?(rows, &(&1["badge"] == "verified"))
    assert Enum.all?(rows, &(&1["author_qid"] == "Q9068" and &1["author_label"] == "Voltaire"))

    assert Enum.all?(rows, fn row ->
             row["work_qid"] == "Q215894" and row["work_label"] == "Candide" and
               row["work_year"] == 1759 and row["work_year_basis"] == "P577" and
               row["gutenberg"]["ebook"] == "19942" and
               row["gutenberg"]["locator"] =~ "Candide (Gutenberg #19942), line" and
               row["revision_id"] == 4_009_931 and row["page"] == "Voltaire"
           end)

    # Two agreements, one of them the text: the corpus's claim and Gutenberg.
    for row <- rows do
      assert "gutenberg" in row["sources"] and "wikiquote-pd-v1" in row["sources"]
      assert Enum.any?(row["checks"], &(&1["kind"] == "primary"))

      assert row["fingerprint"] ==
               DevilsDictionary.Quotations.Fingerprint.fingerprint(row["text"])

      # The page is a concept a sense refers to, so the line reaches that page.
      assert row["concept_qids"] == ["Q9068"]
    end

    # The fingerprint is the identity: one row per line.
    assert length(Enum.uniq_by(rows, & &1["fingerprint"])) == length(rows)

    # A work dated after the line is never fetched.
    assert selection["works"] |> Enum.map(& &1["ebook"]) == ["19942"]
    refute Enum.any?(drain(), &(&1 =~ "77777"))

    assert %{"pages" => [%{"title" => "Voltaire", "revision_id" => 4_009_931}]} = selection
    assert %{"Q9068" => %{"claims" => %{"P31" => [%{"mainsnak" => snak}]}}} = selection["authors"]
    refute Map.has_key?(snak, "hash")
    assert ledger["gutenberg"]["requests"] == 1
  end

  test "a line in the page's own register is never kept" do
    {:ok, rows, _selection, _ledger} = build([])
    parsed = DevilsDictionary.Discovery.Providers.Wikiquote.Parser.parse(@voltaire)

    register =
      parsed.register
      |> Enum.map(&DevilsDictionary.Quotations.Fingerprint.fingerprint(&1.text))
      |> MapSet.new()

    refute Enum.any?(rows, &MapSet.member?(register, &1["fingerprint"]))
  end

  test "rebuilds the same set from its selection block, asking only for the pinned bytes" do
    {:ok, rows, selection, _ledger} = build([])
    drain()

    {:ok, again, _selection, ledger} =
      Build.run(endpoints: @endpoints, selection: selection, get: stub(self()))

    assert Build.set_checksum(again) == Build.set_checksum(rows)

    urls = drain()
    # No selection, credit, author or label request: only the page at its
    # revision and the text.
    refute Enum.any?(urls, &(&1 =~ "sparql.test" or &1 =~ "wikidata.test" or &1 =~ "api.php"))
    assert "https://wikiquote.test/page/html/Voltaire/4009931" in urls
    assert Map.keys(ledger) |> Enum.sort() == ["gutenberg", "parsoid"]
  end

  @tag :tmp_dir
  test "writes once, then refuses a rebuild that differs, and writes nothing", %{tmp_dir: dir} do
    path = Path.join(dir, "wikiquote-pd-v1.json")
    {:ok, rows, selection, ledger} = build([])
    manifest = Task.manifest(rows, selection, ledger)

    capture_io(fn -> send(self(), {:concluded, Task.conclude(manifest, nil, path)}) end)
    assert_received {:concluded, {:written, written}}
    assert written["manifest"] == "wikiquote-pd-v1"
    assert written["source"] == "wikiquote-pd-v1"
    assert written["identity"] == "fingerprint"
    assert written["set_checksum"] == Build.set_checksum(rows)
    committed = DevilsDictionary.Artworks.Corpus.Manifest.load!(path)
    before = File.read!(path)

    # The same selection, the same bytes: unchanged, nothing written.
    {:ok, same, sel, led} =
      Build.run(endpoints: @endpoints, selection: committed["selection"], get: stub(self()))

    assert capture_io(fn ->
             assert {:unchanged, _} =
                      Task.conclude(Task.manifest(same, sel, led), committed, path)
           end) =~ "Nothing written"

    # Gutenberg's text lost its last third: the set moved, and the task says no.
    shorter = binary_part(@candide, 0, div(byte_size(@candide) * 2, 3))

    {:ok, moved, sel, led} =
      Build.run(
        endpoints: @endpoints,
        selection: committed["selection"],
        get: stub(self(), shorter)
      )

    assert length(moved) < length(rows)

    assert_raise Mix.Error, ~r/refusing to write .* gone/s, fn ->
      Task.conclude(Task.manifest(moved, sel, led), committed, path)
    end

    assert File.read!(path) == before
  end

  test "an edition or translation takes its original's date" do
    works =
      Build.works_from(
        %{
          "results" => %{
            "bindings" => [
              %{
                "work" => uri("Q1"),
                "author" => uri("Q2"),
                "pg" => lit("10"),
                "date" => lit("1956-01-01T00:00:00Z")
              },
              %{"work" => uri("Q3"), "author" => uri("Q2"), "pg" => lit("11")}
            ]
          }
        },
        %{
          "results" => %{
            "bindings" => [%{"work" => uri("Q1"), "origDate" => lit("-0457-01-01T00:00:00Z")}]
          }
        }
      )

    # The 1956 translation is Aeschylus's, 458 BC; the undated work is not read.
    assert [%{"work" => "Q1", "year" => -457, "year_basis" => "P629 P577"}] = works
  end

  describe "the concept hop (#172 build A)" do
    # coward's item has no page; it has as its characteristic cowardice,
    # whose page is Cowardice. A second concept's characteristic is, by a bad
    # edit, Voltaire: a person, whose page the hop must not take.
    @hop_items %{
      "Q104605901" => %{"title" => nil, "claims" => %{"P1552" => ["Q1401607"]}},
      "Q1401607" => %{"title" => "Cowardice", "claims" => %{}},
      "Q900802" => %{"title" => nil, "claims" => %{"P1552" => ["Q9068"]}}
    }

    # Cowardice, as a theme page with one line on it: a line of Candide the
    # plain build verifies, cited to Voltaire by a link, the way a theme page
    # credits (the first page its citation links).
    defp cowardice(text) do
      escaped = text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

      ~s(<html about="//en.wikiquote.org/wiki/Special:Redirect/revision/3927892">) <>
        ~s(<head><title>Cowardice</title></head><body><section><h2>Quotes</h2><ul><li>) <>
        escaped <>
        ~s(<ul><li><a rel="mw:WikiLink" href="./Voltaire">Voltaire</a>, ) <>
        ~s[<i>Candide</i> (1759)</li></ul></li></ul></section></body></html>]
    end

    defp hop_stub(text) do
      stub = Fixtures.stub(self(), @candide, @hop_items)
      page = cowardice(text)

      fn request ->
        case URI.parse(request[:url]) do
          %{host: "wikiquote.test", path: "/page/html/Cowardice" <> _} ->
            send(self(), {:request, request[:url]})
            {:ok, 200, page, %{}}

          %{host: "wikiquote.test", path: "/w/api.php"} ->
            send(self(), {:request, request[:url]})

            {:ok, 200,
             %{
               "query" => %{
                 "pages" => [
                   %{"title" => "Voltaire", "pageprops" => %{"wikibase_item" => "Q9068"}}
                 ]
               }
             }, %{}}

          _ ->
            stub.(request)
        end
      end
    end

    test "a line on a page the hop reached is filed under the concept that reached it" do
      {:ok, [line | _], _selection, _ledger} = build([])
      drain()

      {:ok, rows, selection, ledger} =
        build(
          concept_qids: ["Q104605901", "Q900802", "Q9068"],
          get: hop_stub(line["text"])
        )

      assert selection["hop"] == DevilsDictionary.Discovery.ConceptHop.rule()

      # Cowardice joins the selection as no concept of its own, reached from
      # coward; Voltaire is not reached from Q900802.
      assert %{"concept" => false, "kind" => "concept", "via_from" => from} =
               Enum.find(selection["pages"], &(&1["title"] == "Cowardice"))

      assert from == [
               %{
                 "qid" => "Q104605901",
                 "via" => [%{"property" => "P1552", "qid" => "Q1401607"}]
               }
             ]

      assert %{"via_from" => []} = Enum.find(selection["pages"], &(&1["qid"] == "Q9068"))

      # One request for the three concepts' sitelinks and claims, one for the
      # hop's first step; none further.
      assert ledger["wikidata:sitelinks+claims"]["requests"] == 1
      assert ledger["wikidata:hop"]["requests"] == 1

      # The same words on Voltaire's page and on Cowardice fold to one row,
      # which reaches coward's page by the path and Voltaire's by his own.
      row = Enum.find(rows, &(&1["fingerprint"] == line["fingerprint"]))
      assert row["concept_qids"] == ["Q104605901", "Q9068"]

      assert row["concept_qids_via"] == %{
               "Q104605901" => [%{"property" => "P1552", "qid" => "Q1401607"}]
             }

      # Every row of a selection made with the hop says what reached it.
      assert Enum.all?(rows, &is_map(&1["concept_qids_via"]))
    end

    test "a selection made before the hop re-runs to the same rows, with no paths" do
      {:ok, rows, selection, _ledger} = build([])

      v1 =
        selection
        |> Map.delete("hop")
        |> Map.update!("pages", fn pages -> Enum.map(pages, &Map.delete(&1, "via_from")) end)

      {:ok, again, _selection, _ledger} =
        Build.run(endpoints: @endpoints, selection: v1, get: stub(self()))

      refute Enum.any?(again, &Map.has_key?(&1, "concept_qids_via"))
      assert Enum.map(again, & &1["fingerprint"]) == Enum.map(rows, & &1["fingerprint"])
    end
  end
end
