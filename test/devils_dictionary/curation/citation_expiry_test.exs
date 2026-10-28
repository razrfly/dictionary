defmodule DevilsDictionary.Curation.CitationExpiryTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.CitationFixtures
  import DevilsDictionary.CurationFixtures, only: [content_spec: 2, key: 1]

  alias DevilsDictionary.Curation.{
    Shelf,
    Compositions,
    Reviews,
    Publications,
    Receipt,
    ShelfCitation
  }

  alias DevilsDictionary.Repo
  setup do: editor_world!()

  @namespaces %{
    "guardian" => "guardian_article",
    "bing-news" => "news_article",
    "spotify" => "spotify_track",
    "pexels" => "pexels_photo",
    "unsplash" => "unsplash_photo",
    "openverse" => "openverse_media",
    "commons" => "commons_file",
    "met" => "met_object",
    "cinegraph" => "tmdb_movie",
    "open-library" => "olid",
    "poetrydb" => "poetrydb_poem",
    "wikiquote" => "wikiquote_item"
  }
  for provider <- Shelf.providers() do
    test "#{provider}: expiry hides reader fields and actual retained rows contain only permitted payload",
         world do
      slug = unquote(provider)
      o = observation!(world, slug, namespace: @namespaces[slug])

      spec = %{
        kind: :work,
        shelf: o.spec,
        source_record_revision_id: o.revision.id,
        meaning: {:lexeme, world.love.object_id},
        note: %{text: "A relevant source item illustrates the meaning."}
      }

      assert {:ok, v} =
               Compositions.create_version(world.reviewer, world.composition.id, %{
                 lead: content_spec(world.bierce, world.love),
                 highlights: [spec],
                 reason: "A relevant choice for this page.",
                 expected_parent: world.published.version.id
               })

      assert {:ok, _} =
               Reviews.decide(world.reviewer, v.id, :accepted,
                 reason: "The choice fits this meaning.",
                 idempotency_key: key("review")
               )

      assert {:ok, _} =
               Publications.publish(world.reviewer, v.id,
                 reason: "Publish the reviewed choice.",
                 idempotency_key: key("publish"),
                 expected_pointer: world.published.version.id
               )

      assert {:ok, r} = Receipt.read("love", v.version)
      item = Enum.find(r.items, & &1.citation)
      assert item.status == :shown
      original_expiry = item.citation.expires_at
      config = Application.fetch_env!(:devils_dictionary, :discovery)
      policies = Keyword.get(config, :source_policies, %{})

      Application.put_env(
        :devils_dictionary,
        :discovery,
        Keyword.put(
          config,
          :source_policies,
          Map.put(policies, slug, Keyword.put(Map.get(policies, slug, []), :retention_seconds, 0))
        )
      )

      on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, config) end)
      assert {:ok, expired} = Receipt.read("love", v.version)
      hidden = Enum.find(expired.items, & &1.citation)
      assert hidden.status == :withheld and hidden.status_reason == :retention_expired
      assert hidden.provider_metadata == nil
      assert %{expired_results: 1} = DevilsDictionary.Discovery.cleanup()
      assert {:ok, after_sweep} = Receipt.read("love", v.version)
      assert Enum.find(after_sweep.items, & &1.citation).status_reason == :retention_expired
      assert Repo.get!(ShelfCitation, item.citation.id).expires_at == original_expiry

      for table <-
            ~w(discovery_results source_record_revisions source_records curation_shelf_citations curation_item_bases inference_attempts editorial_composition_items editorial_composition_versions editorial_composition_reviews editorial_composition_publications) do
        %{rows: rows} = Repo.query!("SELECT row_to_json(t)::text FROM #{table} t")

        if slug not in ~w(commons met open-library poetrydb wikiquote),
          do:
            refute(
              Enum.any?(rows, fn [json] ->
                String.contains?(json, o.raw["preview_metadata"]["title"])
              end),
              "#{slug} retained its headline in #{table}"
            )

        if slug not in ~w(commons met poetrydb wikiquote),
          do:
            refute(
              Enum.any?(rows, fn [json] ->
                String.contains?(json, "A distinctive discovery snippet for this fixture.")
              end),
              "#{slug} retained its snippet in #{table}"
            )
      end

      assert {:ok, _} =
               Publications.withdraw(world.reviewer, world.composition.id,
                 reason: "withdrawn_by_owner",
                 idempotency_key: key("withdraw"),
                 expected_pointer: v.id
               )
    end
  end
end
