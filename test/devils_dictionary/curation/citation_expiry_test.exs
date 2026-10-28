defmodule DevilsDictionary.Curation.CitationExpiryTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.ProviderCitationFixtures
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

  for provider <- Shelf.providers() do
    test "#{provider}: expiry hides reader fields and actual retained rows contain only permitted payload",
         world do
      slug = unquote(provider)
      o = provider_observation!(world, slug)

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
      assert %{expired_results: expired_results} = DevilsDictionary.Discovery.cleanup()
      assert expired_results >= 1
      assert {:ok, after_sweep} = Receipt.read("love", v.version)
      assert Enum.find(after_sweep.items, & &1.citation).status_reason == :retention_expired
      assert Repo.get!(ShelfCitation, item.citation.id).expires_at == original_expiry

      %{rows: [[retained_payload]]} =
        Repo.query!("SELECT payload FROM source_record_revisions WHERE id=$1", [o.revision.id])

      case slug do
        s when s in ~w(commons met poetrydb wikiquote) ->
          assert retained_payload == o.raw

        "open-library" ->
          refute retained_payload["match_details"]

          assert Map.keys(retained_payload["preview_metadata"]) --
                   ~w(title year author author_keys olid ia source_url read_url cover_url) == []

        _ ->
          refute retained_payload["preview_metadata"]
      end

      for table <-
            ~w(discovery_results source_record_revisions source_records curation_shelf_citations curation_item_bases inference_attempts editorial_composition_items editorial_composition_versions editorial_composition_reviews editorial_composition_publications) do
        %{rows: rows} = Repo.query!("SELECT row_to_json(t)::text FROM #{table} t")

        allowed =
          if slug == "open-library",
            do:
              retained_strings(
                Map.take(
                  o.raw["preview_metadata"],
                  ~w(title year author author_keys olid ia source_url read_url cover_url)
                )
              ),
            else: []

        stored = Enum.flat_map(rows, fn [json] -> retained_strings(Jason.decode!(json)) end)

        for %{value: value} <- Shelf.expiring_fields(slug, o.raw),
            byte_size(value) >= 20,
            not Enum.any?(allowed, &String.contains?(&1, value)) do
          refute Enum.any?(stored, &String.contains?(&1, value)),
                 "#{slug} retained an expiring adapter field in #{table}: #{inspect(value)}"
        end
      end

      assert {:ok, _} =
               Publications.withdraw(world.reviewer, world.composition.id,
                 reason: "withdrawn_by_owner",
                 idempotency_key: key("withdraw"),
                 expected_pointer: v.id
               )
    end
  end

  # Hash-typed identity fields are permitted digests, even if a provider's own
  # shortened hash id is a substring of the full URL digest. Open Library's
  # explicit bibliographic values likewise have independent retention permission.
  defp retained_strings(value) when is_map(value),
    do:
      Enum.flat_map(value, fn {key, value} ->
        if String.ends_with?(to_string(key), "sha256") or
             key in ~w(checksum cited_checksum content_hash),
           do: [],
           else: retained_strings(value)
      end)

  defp retained_strings(value) when is_list(value), do: Enum.flat_map(value, &retained_strings/1)
  defp retained_strings(value) when is_binary(value), do: [value]
  defp retained_strings(_), do: []
end
