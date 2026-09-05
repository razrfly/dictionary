defmodule DevilsDictionary.Absorb.Sources.WikipediaAbsorbTest do
  @moduledoc """
  `absorb/2` end to end against stubbed responses: batching, absent markers,
  reason order, and the one thing that silently corrupts a feed — a `changed_at`
  stamp for a change the source never made.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.Clients
  alias DevilsDictionary.Absorb.Sources.Wikipedia
  alias DevilsDictionary.{Fixtures, Repo, Sources}
  alias DevilsDictionary.Encyclopedia.Concept
  alias DevilsDictionary.Lexicon.{Entry, Lexeme, ScopeLexeme}
  alias DevilsDictionary.Sources.SourceRecord

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{source: sources["wikipedia"], animals: scopes["animals"]}
  end

  defp scoped!(ctx, lemma, reasons) do
    lexeme =
      Repo.insert!(%Lexeme{lang: "en", lemma: lemma, pos: "noun", slug: Lexeme.slug(lemma)})

    Repo.insert!(%ScopeLexeme{
      scope_id: ctx.animals.id,
      lexeme_id: lexeme.id,
      reasons: reasons
    })

    lexeme
  end

  defp records(ctx) do
    Repo.all(from r in SourceRecord, where: r.source_id == ^ctx.source.id, order_by: r.id)
  end

  # One stub for all three endpoints, dispatched on the query the client sent.
  defp stub_api(pages, opts \\ []) do
    counter = :counters.new(1, [])

    Req.Test.stub(Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      :counters.add(counter, 1, 1)
      params = conn.query_params
      titles = String.split(params["titles"] || "", "|", trim: true)

      cond do
        params["prop"] == "links" ->
          Req.Test.json(conn, %{
            "query" => %{"pages" => [%{"title" => hd(titles), "links" => opts[:links] || []}]}
          })

        true ->
          found = for t <- titles, page = pages[t], do: page
          missing = for t <- titles, is_nil(pages[t]), do: %{"title" => t, "missing" => true}

          # The real API answers under the resolved title and reports the
          # rename separately; a stub that skips this tests nothing.
          normalized =
            for t <- titles,
                page = pages[t],
                page["title"] != t,
                do: %{"from" => t, "to" => page["title"]}

          Req.Test.json(conn, %{
            "query" => %{"pages" => found ++ missing, "normalized" => normalized}
          })
      end
    end)

    counter
  end

  defp page(title, attrs \\ %{}) do
    Map.merge(
      %{
        "title" => title,
        "pageid" => :erlang.phash2(title),
        "ns" => 0,
        "extract" => "#{title} is a thing.",
        "description" => "A #{title}",
        "fullurl" => "https://en.wikipedia.org/wiki/#{title}",
        "pageprops" => %{"wikibase_item" => "Q#{:erlang.phash2(title)}"}
      },
      attrs
    )
  end

  test "probes every scope lemma and materializes what it finds", ctx do
    scoped!(ctx, "cat", ["wordnet_closure"])
    scoped!(ctx, "aardvark", ["wiktionary_category"])
    stub_api(%{"cat" => page("cat"), "aardvark" => page("aardvark")})

    assert {:ok, stats} = Wikipedia.absorb(ctx.animals, rate_limit_ms: 0)

    assert stats.lemmas == 2
    assert stats.hits == 2
    assert stats.misses == 0
    assert stats.records == 2
    # Two lemmas, one request: the whole reason for using the Action API.
    assert stats.requests == 1
    assert stats.concepts == 2
    assert stats.entries == 2
  end

  test "a lemma with no article becomes an absent marker, not a gap", ctx do
    scoped!(ctx, "prophaethontid", ["wiktionary_category"])
    stub_api(%{})

    assert {:ok, %{misses: 1, records: 1}} = Wikipedia.absorb(ctx.animals, rate_limit_ms: 0)

    assert [record] = records(ctx)
    assert record.absent_until
    assert Sources.raw(record) == %{}
    # #69 §5's terminal states: absent is a verdict with an expiry, not forever.
    assert DateTime.compare(record.absent_until, DateTime.utc_now()) == :gt
  end

  test "probes in reason order: the WordNet closure first", ctx do
    scoped!(ctx, "zebra", ["wiktionary_category"])
    scoped!(ctx, "cat", ["wordnet_closure"])
    stub_api(%{"cat" => page("cat"), "zebra" => page("zebra")})

    Wikipedia.absorb(ctx.animals, rate_limit_ms: 0, limit: 1)

    # Only one lemma was probed, and it is the flagship one.
    assert [%{external_id: "cat"}] = records(ctx)
  end

  test "the disambiguation pass reads candidates without restamping changed_at", ctx do
    scoped!(ctx, "seal", ["wordnet_closure"])

    stub_api(
      %{
        "seal" =>
          page("Seal", %{
            "pageprops" => %{"wikibase_item" => "Q257102", "disambiguation" => ""}
          }),
        "Fur seal" => page("Fur seal")
      },
      links: [%{"title" => "Fur seal"}]
    )

    assert {:ok, %{disambiguations: 1, candidates: 1}} =
             Wikipedia.absorb(ctx.animals, rate_limit_ms: 0)

    assert [record] = records(ctx)
    assert [%{"title" => "Fur seal"}] = Sources.raw(record)["_candidates"]

    # `_candidates` is our annotation, like `_probe`. Stamping `changed_at` for
    # it would tell the "changed this week" feed that Wikipedia edited the page.
    assert is_nil(record.changed_at)
  end

  test "a second run adds no rows and still stamps no change", ctx do
    scoped!(ctx, "seal", ["wordnet_closure"])

    counter =
      stub_api(
        %{
          "seal" =>
            page("Seal", %{
              "pageprops" => %{"wikibase_item" => "Q257102", "disambiguation" => ""}
            }),
          "Fur seal" => page("Fur seal")
        },
        links: [%{"title" => "Fur seal"}]
      )

    Wikipedia.absorb(ctx.animals, rate_limit_ms: 0)
    first = :counters.get(counter, 1)

    Wikipedia.absorb(ctx.animals, rate_limit_ms: 0)
    second = :counters.get(counter, 1) - first

    assert length(records(ctx)) == 1
    # The payload did not change, so neither did `changed_at` — which is the
    # whole contract the "changed this week" feed will be built on.
    assert is_nil(hd(records(ctx)).changed_at)
    # And the second run asks nothing at all: the lemma is probed and the page's
    # candidates are already read. Re-reading them was what restamped 1,352
    # records in S2, and it answers the same list.
    assert second == 0

    # `--refresh` still re-reads both.
    Wikipedia.absorb(ctx.animals, refresh: true, rate_limit_ms: 0)
    assert :counters.get(counter, 1) > first
    assert is_nil(hd(records(ctx)).changed_at)
  end

  test "reads a long disambiguation page in 50-title chunks", ctx do
    scoped!(ctx, "seal", ["wordnet_closure"])

    candidates = for n <- 1..60, do: "Candidate #{n}"
    pages = Map.new(candidates, &{&1, page(&1)})

    pages =
      Map.put(
        pages,
        "seal",
        page("Seal", %{"pageprops" => %{"wikibase_item" => "Q257102", "disambiguation" => ""}})
      )

    stub_api(pages, links: Enum.map(candidates, &%{"title" => &1}))

    # `pageprops` carries no extract, so its limit is the API's 50 — one chunk
    # short and the last ten candidates would silently have no QID and vanish.
    assert {:ok, %{candidates: 60}} = Wikipedia.absorb(ctx.animals, rate_limit_ms: 0)
  end

  test "a lemma already probed is not probed again", ctx do
    scoped!(ctx, "cat", ["wordnet_closure"])
    scoped!(ctx, "gone", ["wordnet_closure"])

    counter = stub_api(%{"Cat" => page("Cat"), "cat" => page("Cat")})

    assert {:ok, %{lemmas: 2, requests: 1}} = Wikipedia.absorb(ctx.animals, rate_limit_ms: 0)
    first = :counters.get(counter, 1)

    # `cat` was answered and `gone` got an absent marker. Neither is a question
    # worth asking twice, so the second run does no work at all.
    assert {:ok, %{lemmas: 0, requests: 0}} = Wikipedia.absorb(ctx.animals, rate_limit_ms: 0)
    assert :counters.get(counter, 1) == first

    assert {:ok, %{lemmas: 2}} = Wikipedia.absorb(ctx.animals, refresh: true, rate_limit_ms: 0)
  end

  test "an expired absent marker is probed again", ctx do
    scoped!(ctx, "gone", ["wordnet_closure"])
    stub_api(%{})

    assert {:ok, %{lemmas: 1, misses: 1}} = Wikipedia.absorb(ctx.animals, rate_limit_ms: 0)

    Repo.update_all(
      from(r in SourceRecord, where: r.source_id == ^ctx.source.id),
      set: [absent_until: DateTime.add(DateTime.utc_now(), -1, :day)]
    )

    assert {:ok, %{lemmas: 1}} = Wikipedia.absorb(ctx.animals, rate_limit_ms: 0)
  end

  test "the concept pass does not re-fetch a page that yielded no entry", ctx do
    # A disambiguation page is fetched, stored, and produces no entry by design.
    # The skip rule tested only "has an entry" and "has a live absent marker", so
    # every `--concepts` run asked about all ~3,800 of them again.
    Repo.insert!(%Concept{
      qid: "Q_disambig",
      label: "Seal",
      kind: :thing,
      wikipedia_title: "Seal"
    })

    counter =
      stub_api(%{
        "Seal" => page("Seal", %{"pageprops" => %{"disambiguation" => ""}, "extract" => nil})
      })

    assert {:ok, %{requests: 1}} = Wikipedia.absorb(ctx.animals, concepts: true, rate_limit_ms: 0)
    assert Repo.aggregate(from(e in Entry, where: e.source_id == ^ctx.source.id), :count) == 0

    # Second run: nothing left to ask about.
    assert {:ok, %{requests: 0, concepts_probed: 0}} =
             Wikipedia.absorb(ctx.animals, concepts: true, rate_limit_ms: 0)

    assert :counters.get(counter, 1) == 1

    # `--refresh` is still the way back in.
    assert {:ok, %{requests: 1}} =
             Wikipedia.absorb(ctx.animals, concepts: true, refresh: true, rate_limit_ms: 0)
  end

  test "refuses to run without a scope, rather than probing 1.5M lemmas", ctx do
    _ = ctx

    assert_raise RuntimeError, ~r/absorbed against a scope/, fn ->
      Wikipedia.absorb(nil, [])
    end
  end
end
