defmodule DevilsDictionaryWeb.UrbanDictionaryCardTest do
  @moduledoc """
  The 📱 Crowd card's server half (#136).

  What the server renders is a *shell*: a header, a hook, three data attributes
  and a plaque. Everything that makes it a definition arrives in the reader's
  browser, so what a LiveView test can assert is exactly the contract between
  the two — that the shell is there when it should be, that it carries what the
  hook needs, that it carries no key because there is none, and that either
  kill switch removes it rather than hiding it.

  The other half is `node --test assets/js/urban_dictionary.test.mjs`.
  """

  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.WordFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Discovery.RequestAttempt
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.UrbanDictionary

  setup %{conn: conn} do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    Map.merge(catalog, %{conn: conn, animals: catalog.scopes["animals"]})
  end

  defp rizz!(ctx) do
    word = word!(ctx, "rizz", ~w(wiktionary))
    sense!(ctx, word, "wiktionary", gloss: "charisma")
    word
  end

  defp switch(value) do
    original = Application.get_env(:devils_dictionary, :urban_dictionary)
    Application.put_env(:devils_dictionary, :urban_dictionary, value)
    on_exit(fn -> Application.put_env(:devils_dictionary, :urban_dictionary, original) end)
  end

  describe "the shell, when the source is on" do
    test "renders with the hook and everything the browser needs", ctx do
      rizz!(ctx)

      {:ok, view, html} = live(ctx.conn, ~p"/define/rizz")

      assert has_element?(view, ~s([phx-hook="UrbanDictionary"][data-term="rizz"]))

      assert has_element?(
               view,
               ~s([phx-hook="UrbanDictionary"][data-endpoint="https://api.urbandictionary.com/v0/define"])
             )

      assert has_element?(view, ~s([phx-hook="UrbanDictionary"][data-define-path="/define"]))

      # `phx-update="ignore"` for the same reason the definitions slab has it:
      # what the hook wrote is DOM state the server does not model.
      assert has_element?(view, ~s([phx-hook="UrbanDictionary"][phx-update="ignore"]))

      # The real 📱 header, not the demo's dashed sample chrome.
      assert html =~ "📱"
      refute render(element(view, ~s([phx-hook="UrbanDictionary"]))) =~ "border-dashed"
    end

    test "the plaque is server-rendered, so it cannot go missing with the script", ctx do
      rizz!(ctx)

      {:ok, view, _html} = live(ctx.conn, ~p"/define/rizz")

      card = view |> element(~s([phx-hook="UrbanDictionary"])) |> render()
      assert card =~ "Crowd-sourced and unreviewed."
      assert card =~ "Fetched by your browser; nothing is stored here."
      assert card =~ "Read on Urban Dictionary" or card =~ "urbandictionary.com/define.php"
    end

    test "nothing secret is in the assign: the endpoint is keyless", ctx do
      rizz!(ctx)

      {:ok, _view, html} = live(ctx.conn, ~p"/define/rizz")

      config = UrbanDictionary.browser_config(%{term: "rizz", language: "en", object_id: 1})
      assert Map.keys(config) |> Enum.sort() == [:endpoint, :permalink_host, :term]
      refute html =~ "api_key"
      refute html =~ "api-key"
    end

    test "it sits after the definitions and before the culture shelves", ctx do
      word = rizz!(ctx)
      entry!(ctx, word, "bierce", body: "A modern charm.")

      {:ok, _view, html} = live(ctx.conn, ~p"/define/rizz")

      definitions = :binary.match(html, "Definitions") |> elem(0)
      card = :binary.match(html, ~s(phx-hook="UrbanDictionary")) |> elem(0)

      assert definitions < card
    end

    test "the server makes no request of its own", ctx do
      rizz!(ctx)

      {:ok, _view, _html} = live(ctx.conn, ~p"/define/rizz")

      # The discovery ledger is where every server-side outbound request in
      # this app is written down. This card spends none, because the request
      # that fetches it has not happened on this machine.
      assert Repo.aggregate(from(a in RequestAttempt), :count) == 0
    end
  end

  describe "the kill switches" do
    test "URBAN_DICTIONARY_ENABLED=false renders no shell at all", ctx do
      rizz!(ctx)
      switch(endpoint: "https://api.urbandictionary.com/v0/define", enabled: false)

      {:ok, view, html} = live(ctx.conn, ~p"/define/rizz")

      refute has_element?(view, ~s([phx-hook="UrbanDictionary"]))
      refute html =~ "UrbanDictionary"
      refute html =~ "api.urbandictionary.com"
      refute html =~ "Crowd-sourced and unreviewed"
    end

    test "active: false on the source row renders no shell at all", ctx do
      rizz!(ctx)

      "urban-dictionary"
      |> Sources.get_source_by_slug!()
      |> Ecto.Changeset.change(active: false)
      |> Repo.update!()

      {:ok, view, html} = live(ctx.conn, ~p"/define/rizz")

      refute has_element?(view, ~s([phx-hook="UrbanDictionary"]))
      refute html =~ "Crowd-sourced and unreviewed"
    end

    test "a re-seed does not undo active: false", ctx do
      rizz!(ctx)

      "urban-dictionary"
      |> Sources.get_source_by_slug!()
      |> Ecto.Changeset.change(active: false)
      |> Repo.update!()

      DevilsDictionary.Sources.OnDemand.seed!()

      refute Sources.get_source_by_slug!("urban-dictionary").active
    end

    test "a re-seed refreshes the managed fields, so a config change reaches the row", ctx do
      rizz!(ctx)
      before = Application.get_env(:devils_dictionary, :urban_dictionary, [])

      "urban-dictionary"
      |> Sources.get_source_by_slug!()
      |> Ecto.Changeset.change(active: false)
      |> Repo.update!()

      try do
        Application.put_env(
          :devils_dictionary,
          :urban_dictionary,
          Keyword.put(before, :permission_requested_on, "2026-09-22")
        )

        %{"urban-dictionary" => seeded} = DevilsDictionary.Sources.OnDemand.seed!()
        source = Sources.get_source_by_slug!("urban-dictionary")

        assert seeded.config["permission_requested_on"] == "2026-09-22"
        assert source.config["permission_requested_on"] == "2026-09-22"
        # The kill switch survives the same re-seed that carried the date.
        refute source.active
      after
        Application.put_env(:devils_dictionary, :urban_dictionary, before)
      end
    end

    test "browser_config/1 is nil with no target: a miss page has no card", _ctx do
      assert UrbanDictionary.browser_config(nil) == nil
    end
  end

  describe "the row" do
    test "exists, is 📱, and says on its face that nothing is stored", _ctx do
      source = Sources.get_source_by_slug!("urban-dictionary")

      assert source.tier == :plebs
      assert source.access == :api
      assert source.license_url == "https://urbandictionary.help/tos/"
      assert source.config["transport"] == "browser only"
      assert source.config["ingestion"] == "none; nothing is stored"
      assert source.config["permission_status"] == "requested"

      # The owner's email is the owner's step. Until it is sent this reads
      # "pending", and the PR says so rather than inventing a date.
      assert source.config["permission_requested_on"] == UrbanDictionary.permission_requested_on()
    end

    test "is not in the absorb catalog, so A1 never asks it for a finished run", _ctx do
      slugs = Enum.map(DevilsDictionary.Sources.Catalog.sources(), & &1.slug)

      refute "urban-dictionary" in slugs
    end

    test "is not a discovery provider, so conformance never asks it for a shelf", _ctx do
      slugs = Enum.map(DevilsDictionary.Discovery.Providers.all(), & &1.slug())

      refute "urban-dictionary" in slugs
    end

    test "never gains a source_record: there is nothing to store", ctx do
      rizz!(ctx)
      source = Sources.get_source_by_slug!("urban-dictionary")

      {:ok, _view, _html} = live(ctx.conn, ~p"/define/rizz")

      assert Repo.aggregate(
               from(r in DevilsDictionary.Sources.SourceRecord, where: r.source_id == ^source.id),
               :count
             ) == 0
    end
  end
end
