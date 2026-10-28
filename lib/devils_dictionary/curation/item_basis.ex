defmodule DevilsDictionary.Curation.ItemBasis do
  @moduledoc "Original-choice evidence, preserved independently of later review and FK nulling."
  use Ecto.Schema
  import Ecto.Query
  alias DevilsDictionary.Repo

  alias DevilsDictionary.Curation.{
    CompositionItem,
    Compositions,
    Digest,
    ShelfCitations,
    Shelf,
    LinkedClaims
  }

  alias DevilsDictionary.Curation.Runtime.Attempt
  alias DevilsDictionary.Registry.{ContentRevision, SenseRevision}
  @primary_key {:item_id, :id, autogenerate: false}
  schema "curation_item_bases" do
    field :origin, :string
    field :origin_item_id, :id
    field :original_reference, :map
    field :attempt_id, :id
    field :evidence_kind, :string
    field :fields_version, :string
    field :supplied_sha256, :string
    field :representation, :map
    field :witness_assertion_revision_id, :id
    field :reviewed_by_actor_id, :id
    field :reason_rewritten, :boolean, default: false
  end

  def get(id), do: Repo.get(__MODULE__, id)

  def virtual(nil), do: nil

  def virtual(basis),
    do: %{
      "representation" => basis.representation,
      "witness_assertion_revision_id" => basis.witness_assertion_revision_id,
      "shown_object_id" => basis.original_reference["shown_object_id"]
    }

  def record!(item, version, opts \\ []) do
    source = source(item, opts)
    original = source && get(source.id)

    attributes =
      cond do
        original ->
          original |> Map.from_struct() |> Map.drop([:__meta__, :item_id])

        source ->
          %{
            origin: "legacy_unknown",
            origin_item_id: legacy_original(source, MapSet.new()).id,
            original_reference: reference(legacy_original(source, MapSet.new()))
          }

        version.origin == :model ->
          model(item, version)

        true ->
          owner(item)
      end

    attributes = attributes |> Map.put(:item_id, item.id)

    attributes =
      cond do
        source && version.origin == :manual ->
          Map.merge(attributes, %{
            reviewed_by_actor_id: version.created_by_actor_id,
            reason_rewritten: attributes[:reason_rewritten] || source.note != item.note
          })

        source && version.origin == :model ->
          composition = Repo.get!(DevilsDictionary.Curation.Composition, version.composition_id)
          ref = Compositions.reference(source)

          mark =
            Enum.find(composition.kept_items, &(Compositions.reference(&1["reference"]) == ref))

          if mark,
            do:
              Map.merge(attributes, %{
                reviewed_by_actor_id: mark["marked_by_actor_id"],
                reason_rewritten: attributes[:reason_rewritten] || false
              }),
            else: attributes

        true ->
          attributes
      end

    Repo.insert!(struct(__MODULE__, attributes))
  end

  defp legacy_original(source, seen) do
    if source.copied_from_item_id && not MapSet.member?(seen, source.id) do
      case Repo.get(CompositionItem, source.copied_from_item_id) do
        nil -> source
        parent -> legacy_original(parent, MapSet.put(seen, source.id))
      end
    else
      source
    end
  end

  defp source(%{copied_from_item_id: id}, _opts) when is_integer(id),
    do: Repo.get!(CompositionItem, id)

  defp source(item, opts) do
    if version_id = opts[:review_source] do
      Compositions.items(version_id)
      |> Enum.find(&(Compositions.reference(&1) == Compositions.reference(item)))
    end
  end

  defp model(item, version) do
    attempt = Repo.get!(Attempt, version.attempt_id)

    candidate =
      Enum.find(
        attempt.packet_summary["candidates"] || [],
        &(matches?(&1, item) and
            meaning_matches?(&1, item, attempt.packet_summary["meanings"] || []))
      )

    if is_nil(candidate), do: raise(ArgumentError, "model choice has no frozen evidence basis")

    choice =
      Enum.find(
        List.wrap(attempt.result["lead"]) ++ (attempt.result["highlights"] || []),
        &(&1["candidate_id"] == candidate["candidate_id"])
      )

    ref =
      reference(item)
      |> Map.put("packet_candidate_id", candidate["candidate_id"])
      |> Map.put("reason_withheld", choice && choice["reason_withheld"])

    %{
      origin: "model",
      origin_item_id: item.id,
      original_reference: ref,
      attempt_id: attempt.id,
      evidence_kind: candidate["kind"],
      fields_version: attempt.packet_summary["fields_version"] || "packet-fields-v1",
      supplied_sha256: candidate["excerpt_sha256"] || candidate["label_sha256"],
      representation: item.basis && item.basis["representation"],
      witness_assertion_revision_id: item.basis && item.basis["witness_assertion_revision_id"]
    }
  end

  defp owner(item) do
    %{
      origin: "owner",
      origin_item_id: item.id,
      original_reference: reference(item),
      evidence_kind: kind(item),
      fields_version: "screen-fields-v1",
      supplied_sha256: Digest.sha256(supplied(item)),
      representation: item.basis && item.basis["representation"],
      witness_assertion_revision_id: item.basis && item.basis["witness_assertion_revision_id"]
    }
  end

  def reference(item) do
    Map.merge(
      Compositions.reference(item),
      Map.take(item, [:meaning_sense_revision_id, :meaning_lexeme_id])
    )
    |> Map.put(
      :content_date,
      if(is_nil(item.shelf_citation_id) and is_nil(item.shelf),
        do: DevilsDictionary.Curation.ContentDate.of(item),
        else: nil
      )
    )
    |> Map.put(:source_edition, source_edition(item))
    |> Map.put(:shown_object_id, item.basis && item.basis["shown_object_id"])
    |> Map.new(fn {k, v} ->
      {to_string(k), if(is_atom(v) and not is_nil(v), do: to_string(v), else: v)}
    end)
  end

  defp source_edition(%{shelf_citation_id: id}) when is_integer(id), do: nil

  defp source_edition(item) do
    object = item.item_object_id

    row =
      if object,
        do:
          Repo.get(DevilsDictionary.Registry.ContentItem, object) ||
            Repo.get(DevilsDictionary.Registry.Sense, object)

    source = row && Repo.get(DevilsDictionary.Sources.Source, row.source_id)
    if(source && source.access in [:static, :dump], do: source.era_year)
  end

  defp kind(%{shelf_citation_id: id}) when is_integer(id), do: "shelf"
  defp kind(item), do: to_string(item.item_kind)

  defp meaning_matches?(candidate, item, meanings) do
    case Enum.find(meanings, &(&1["meaning_id"] == candidate["required_meaning"])) do
      %{"kind" => "lexeme", "lexeme_id" => id} ->
        id == item.meaning_lexeme_id

      %{"kind" => "sense_revision", "sense_revision_id" => id} ->
        id == item.meaning_sense_revision_id

      nil ->
        true
    end
  end

  defp matches?(c, item) do
    cond do
      c["kind"] == "shelf" and item.shelf_citation_id ->
        c["shelf"]["result"] == ShelfCitations.get(item.shelf_citation_id).discovery_result_id

      c["kind"] != to_string(item.item_kind) ->
        false

      item.item_kind == :content ->
        c["content_revision_id"] == item.content_revision_id

      item.item_kind in [:sense_quotation, :sense_definition] ->
        c["sense_revision_id"] == item.sense_revision_id and c["locator"] == item.locator

      item.item_kind == :claim ->
        c["assertion_revision_id"] == item.assertion_revision_id and
          c["witness_assertion_revision_id"] ==
            (item.basis && item.basis["witness_assertion_revision_id"]) and
          c["representation_sha256"] == Digest.term(item.basis["representation"])

      item.item_kind == :exemplar ->
        c["assertion_revision_id"] == item.assertion_revision_id

      true ->
        c["catalog"] && c["catalog"]["identity"] == item.catalog_identity
    end
  end

  defp supplied(%{item_kind: :content} = item) do
    r = Repo.get!(ContentRevision, item.content_revision_id)

    case DevilsDictionary.Curation.Excerpt.sentences(r.body, r.body_format, 1000) do
      {:ok, %{text: text}} -> text
      _ -> r.body
    end
  end

  defp supplied(%{item_kind: :sense_definition} = item),
    do: Repo.get!(SenseRevision, item.sense_revision_id).gloss

  defp supplied(%{item_kind: :sense_quotation} = item) do
    r = Repo.get!(SenseRevision, item.sense_revision_id)
    "quotation:" <> n = item.locator
    Enum.at(r.examples, String.to_integer(n))["text"]
  end

  defp supplied(%{shelf_citation_id: id}) when is_integer(id) do
    c = ShelfCitations.get(id)
    payload = ShelfCitations.payload(c)

    Shelf.label(
      Repo.get!(DevilsDictionary.Sources.Source, c.source_id).slug,
      payload["preview_metadata"]
    )
  end

  defp supplied(%{item_kind: :claim, basis: basis}),
    do:
      Enum.join(
        [
          basis["representation"]["subject_label"],
          basis["representation"]["predicate_phrase"],
          basis["representation"]["object_label"]
        ],
        " "
      )

  defp supplied(%{item_kind: :work, catalog_manifest: manifest, catalog_identity: identity})
       when is_binary(manifest) do
    row = DevilsDictionary.Artworks.Corpus.Manifest.committed_row(manifest, identity) || %{}

    creator =
      if is_list(row["creators"]),
        do: Enum.map_join(row["creators"], ", ", & &1["term"]),
        else: row["artist"] || row["author"]

    [row["title"], creator, row["date"] || row["year"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.join(" · ")
  end

  defp supplied(%{item_kind: :exemplar} = item) do
    case Repo.get(DevilsDictionary.Registry.Entity, item.item_object_id) do
      nil ->
        revision = Repo.get!(ContentRevision, item.content_revision_id)
        "Passage: " <> (revision.headword || "##{item.item_object_id}")

      entity ->
        kind =
          if entity.entity_kind,
            do:
              entity.entity_kind |> to_string() |> String.replace("_", " ") |> String.capitalize(),
            else: "Thing"

        label =
          entity.preferred_label ||
            Repo.one(
              from x in DevilsDictionary.Registry.ExternalIdentifier,
                where:
                  x.object_id == ^item.item_object_id and x.namespace == "wikidata" and
                    x.status == :verified,
                order_by: x.external_id,
                limit: 1,
                select: x.external_id
            ) || "##{item.item_object_id}"

        kind <> ": " <> label
    end
  end

  defp supplied(%{item_object_id: id}) when is_integer(id), do: LinkedClaims.label(id)
  defp supplied(item), do: Jason.encode!(reference(item))
end
