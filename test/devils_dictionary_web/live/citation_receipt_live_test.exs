defmodule DevilsDictionaryWeb.CitationReceiptLiveTest do
  use DevilsDictionaryWeb.ConnCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.CitationFixtures
  import DevilsDictionary.RefreshFixtures, only: [page: 1]
  import DevilsDictionary.CurationFixtures, only: [content_spec: 2, key: 1]
  alias DevilsDictionary.Curation.{Candidates, Compositions, Reviews, Publications}
  alias DevilsDictionary.Repo

  test "all groups and native/news tiles lead to a public noindex receipt; drafts are404", %{
    conn: conn
  } do
    world = editor_world!()
    news = observation!(world)
    entity = DevilsDictionary.WordFixtures.concept!("Q270900", "A fixture entity")
    DevilsDictionary.WordFixtures.link!(world.love, entity, sense: world.profound)
    candidates = Candidates.for_page(page("love"))
    sense = Enum.find(candidates.highlights, &(&1.kind == :sense_definition))
    claim = Enum.find(candidates.highlights, &(&1.kind == :claim and &1.status == :ok))
    shelf = Enum.find(candidates.highlights, &(&1.kind == :shelf))
    assert shelf.spec.shelf.result == news.result.id

    picks =
      Enum.map(
        [sense, claim, shelf],
        &Map.put(&1.spec, :note, %{text: "A relevant source choice illustrates this meaning."})
      )

    assert {:ok, v} =
             Compositions.create_version(world.reviewer, world.composition.id, %{
               lead: content_spec(world.bierce, world.love),
               highlights: picks,
               reason: "A transparent fixture arrangement.",
               expected_parent: world.published.version.id
             })

    assert_error_sent 404, fn -> get(build_conn(), ~p"/on/love/receipt/#{v.version}") end

    assert {:ok, _} =
             Reviews.decide(world.reviewer, v.id, :accepted,
               reason: "These references stand.",
               idempotency_key: key("review")
             )

    assert {:ok, _} =
             Publications.publish(world.reviewer, v.id,
               reason: "Publish these choices.",
               idempotency_key: key("publish"),
               expected_pointer: world.published.version.id
             )

    before =
      {Repo.aggregate(DevilsDictionary.Curation.Runtime.Attempt, :count),
       Repo.aggregate(Oban.Job, :count)}

    response = get(conn, ~p"/on/love/receipt/#{v.version}")
    html = html_response(response, 200)
    assert html =~ "noindex"
    {:ok, receipt, _} = live(conn, ~p"/on/love/receipt/#{v.version}")
    assert has_element?(receipt, "#curation-receipt")

    for item <- Compositions.items(v.id),
        do: assert(has_element?(receipt, "#receipt-item-#{item.role}-#{item.position}"))

    refute has_element?(receipt, "#curation-receipt a[href^='/ops/']")

    assert {Repo.aggregate(DevilsDictionary.Curation.Runtime.Attempt, :count),
            Repo.aggregate(Oban.Job, :count)} == before

    capture("receipt", render(receipt))
    {:ok, word, _} = live(conn, ~p"/on/love")
    for position <- 1..3, do: assert(has_element?(word, "#opening-highlight-#{position}"))
    assert has_element?(word, "a[href*='/receipt/']")
    capture("tiles", render(word))
    {:ok, editor, _} = conn |> log_in_user(world.reviewer.user) |> live(~p"/ops/curation/on/love")
    for kind <- Candidates.kinds(), do: assert(has_element?(editor, "#group-#{kind}"))
    assert has_element?(editor, "#candidate-#{sense.key}")
    capture("groups", render(editor))
  end

  defp capture(name, html) do
    if dir = System.get_env("C270_UI_OUT") do
      File.mkdir_p!(dir)
      css = File.read!(System.fetch_env!("C270_UI_CSS"))
      {:ok, tree} = Floki.parse_fragment(html)

      selector =
        case name do
          "groups" -> "#group-sense_definition, #group-claim, #group-shelf"
          "tiles" -> "#opening"
          _ -> "#curation-receipt"
        end

      html = tree |> Floki.find(selector) |> Floki.raw_html()

      html =
        Regex.replace(~r/src="(\/images\/[^"]+)"/, html, fn original, path ->
          file = Path.join("priv/static", String.trim_leading(path, "/"))

          if File.regular?(file),
            do: "src=\"data:#{MIME.from_path(file)};base64,#{Base.encode64(File.read!(file))}\"",
            else: original
        end)

      html =
        "<div class='mx-auto max-w-6xl p-5'><p class='mb-4 text-sm'>#270 fixture demonstration · #{name} · no live data</p>#{html}</div>"

      File.write!(
        Path.join(dir, name <> ".html"),
        "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'><style>#{css}</style></head><body>#{html}</body></html>"
      )
    end
  end
end
