defmodule DevilsDictionary.Curation.Receipt do
  @moduledoc "Public, read-only version receipt for the published default lexical composition."
  import Ecto.Query
  alias DevilsDictionary.{Repo, Lexicon}
  alias DevilsDictionary.Lexicon.WordPage

  alias DevilsDictionary.Curation.{
    Configurations,
    Compositions,
    CompositionVersion,
    CompositionPublication,
    CompositionItem,
    ItemBasis,
    Eligibility,
    ShelfCitations,
    Shelf,
    ContentDate
  }

  alias DevilsDictionary.Curation.Runtime.{Attempt, ModelConfig}
  alias DevilsDictionary.Sources.{Actor, Source}

  def read(slug, number) when is_binary(slug) and is_integer(number) do
    page = slug |> Lexicon.lookup() |> WordPage.build(viewer: :public)

    with {:ok, %{configuration: configuration}} <- Configurations.resolve_default(),
         [lexeme | _] = lexemes <- page.headword.lexemes,
         composition when not is_nil(composition) <-
           Compositions.active(
             configuration.id,
             :lexical_page,
             lexeme.language,
             Compositions.signature(Enum.map(lexemes, & &1.id))
           ),
         %CompositionVersion{} = version <-
           Repo.get_by(CompositionVersion, composition_id: composition.id, version: number),
         %CompositionPublication{} = publication <-
           Repo.one(
             from p in CompositionPublication,
               where: p.published_version_id == ^version.id and p.action == :publish,
               order_by: [desc: p.committed_at, desc: p.id],
               limit: 1
           ) do
      ending =
        Repo.one(
          from p in CompositionPublication,
            where:
              p.composition_id == ^composition.id and p.previous_version_id == ^version.id and
                p.id > ^publication.id,
            order_by: [asc: p.committed_at, asc: p.id],
            limit: 1
        )

      published =
        Repo.all(
          from v in CompositionVersion,
            where: v.composition_id == ^composition.id,
            join: p in CompositionPublication,
            on: p.published_version_id == v.id and p.action == :publish,
            distinct: true,
            select: v.version,
            order_by: v.version
        )

      members = Enum.map(lexemes, & &1.id)

      {:ok,
       %{
         slug: slug,
         version: version,
         publication: publication,
         publication_actor: Repo.get(Actor, publication.actor_id),
         review_actor:
           Repo.get(
             Actor,
             Repo.get!(
               DevilsDictionary.Curation.CompositionReview,
               publication.authorizing_review_id
             ).reviewer_actor_id
           ),
         composition: composition,
         published_versions: published,
         window:
           Configurations.refresh_window(
             Repo.get!(
               DevilsDictionary.Curation.ConfigurationVersion,
               version.configuration_version_id
             )
           ),
         items:
           Enum.map(
             Enum.sort_by(Compositions.items(version.id), &{&1.role != :lead, &1.position}),
             &item(&1, version, composition, ending, members)
           )
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  def read(_, _), do: {:error, :not_found}

  defp publication_eligibility(item, version, composition, eligibility) do
    if version.id == composition.current_published_version_id,
      do: current_publication_eligibility(item, composition, eligibility),
      else: eligibility
  end

  defp current_publication_eligibility(item, composition, eligibility) do
    case DevilsDictionary.Curation.Published.current(composition.id) do
      {:ok, arrangement} ->
        case Enum.find(
               arrangement.withheld,
               &(&1.role == item.role and &1.position == item.position)
             ) do
          nil -> eligibility
          held -> {:error, held.reason}
        end

      {:withheld, reasons} ->
        {:error, {:publication_withheld, reasons}}

      _ ->
        eligibility
    end
  end

  defp item(item, version, composition, latest, members) do
    basis = ItemBasis.get(item.id)
    original = item_for_origin(item, basis)
    origin_version = Repo.get(CompositionVersion, original.composition_version_id)

    attempt_id =
      (basis && basis.attempt_id) ||
        (origin_version && origin_version.origin == :model && origin_version.attempt_id)

    attempt = if is_integer(attempt_id), do: Repo.get(Attempt, attempt_id)
    actor = origin_version && Repo.get(Actor, origin_version.created_by_actor_id)
    config = attempt && Repo.get(ModelConfig, attempt.model_config_id)

    cv =
      origin_version &&
        Repo.get(
          DevilsDictionary.Curation.ConfigurationVersion,
          origin_version.configuration_version_id
        )

    citation = item.shelf_citation_id && ShelfCitations.get(item.shelf_citation_id)
    source = citation && Repo.get!(Source, citation.source_id)
    eligibility = Eligibility.check(item, members)
    eligibility = publication_eligibility(item, version, composition, eligibility)
    payload = if citation && eligibility == :ok, do: ShelfCitations.payload(citation), else: nil

    status =
      cond do
        composition.current_published_version_id == version.id and eligibility == :ok -> :shown
        composition.current_published_version_id == version.id -> :withheld
        latest && latest.action == :withdraw -> :withdrawn
        true -> :replaced
      end

    content_date =
      cond do
        citation && payload ->
          Shelf.date(source.slug, payload["preview_metadata"] || %{})

        citation ->
          %{
            value: nil,
            precision: citation.content_date_precision,
            meaning: citation.content_date_meaning
          }

        basis && basis.original_reference["content_date"] ->
          basis.original_reference["content_date"]

        true ->
          ContentDate.of(item)
      end

    %{
      id: item.id,
      role: item.role,
      position: item.position,
      kind: item.item_kind,
      status: status,
      status_reason:
        case eligibility do
          :ok -> nil
          {:error, r} -> r
        end,
      replacement:
        if(latest,
          do: %{
            version_id: latest.published_version_id,
            version:
              latest.published_version_id &&
                Repo.get!(CompositionVersion, latest.published_version_id).version,
            at: latest.committed_at,
            reason: latest.reason
          }
        ),
      reference: if(basis, do: basis.original_reference, else: ItemBasis.reference(item)),
      citation: citation,
      provider_metadata: payload && payload["preview_metadata"],
      provider_match:
        if(payload,
          do: DevilsDictionary.Discovery.MatchReason.from_result(payload["match_details"], nil)
        ),
      chooser: %{
        kind: if(attempt, do: :model, else: :owner),
        actor_id: actor && actor.id,
        label: actor && actor.label,
        model: config && config.model_name,
        model_config_id: config && config.id,
        model_config_hash: config && config.config_hash,
        attempt_id: attempt && attempt.id,
        request_key: attempt && attempt.request_key,
        profile: cv && cv.manifest["editor"],
        at:
          if(attempt,
            do: attempt.finished_at || attempt.admitted_at,
            else: origin_version && origin_version.inserted_at
          )
      },
      basis: basis,
      later_owner: basis && basis.reviewed_by_actor_id,
      reason: item.note,
      reason_author: %{
        kind: item.note_author_kind,
        label: item.note_author_label,
        actor_id: item.note_author_actor_id
      },
      content_date: content_date,
      source_edition: (basis && basis.original_reference["source_edition"]) || edition(item),
      current_label: if(item.item_kind == :claim, do: current_claim_label(item), else: nil),
      fetched: citation && citation.observed_at,
      representation: basis && basis.representation,
      payload_state: payload_state(citation),
      provider_status:
        if(citation,
          do:
            if(payload,
              do: :available,
              else:
                case eligibility do
                  {:error, reason} -> reason
                  :ok -> ShelfCitations.check(citation)
                end
            )
        )
    }
  end

  defp edition(item) do
    object = item.item_object_id

    row =
      if object,
        do:
          Repo.get(DevilsDictionary.Registry.ContentItem, object) ||
            Repo.get(DevilsDictionary.Registry.Sense, object)

    source = row && Repo.get(Source, row.source_id)
    if(source && source.access in [:static, :dump], do: source.era_year)
  end

  defp current_claim_label(item) do
    case Repo.get(DevilsDictionary.Claims.AssertionRevision, item.assertion_revision_id)
         |> Repo.preload(:predicate) do
      nil ->
        nil

      claim ->
        Enum.join(
          [
            DevilsDictionary.Curation.LinkedClaims.label(claim.subject_object_id),
            String.replace(claim.predicate.key, "_", " "),
            DevilsDictionary.Curation.LinkedClaims.label(claim.object_object_id)
          ],
          " "
        )
    end
  end

  defp payload_state(nil), do: nil
  defp payload_state(%{source_record_revision_id: nil}), do: :deleted

  defp payload_state(c) do
    case Repo.query!(
           "SELECT payload ? '_discovery_redaction' FROM source_record_revisions WHERE id=$1",
           [c.source_record_revision_id]
         ).rows do
      [[true]] -> :redacted
      [[false]] -> :stored
      _ -> :deleted
    end
  end

  defp item_for_origin(item, %{origin_item_id: id}), do: Repo.get(CompositionItem, id) || item
  defp item_for_origin(item, nil), do: ancestry(item, MapSet.new())

  defp ancestry(item, seen) do
    if item.copied_from_item_id && not MapSet.member?(seen, item.id) do
      case Repo.get(CompositionItem, item.copied_from_item_id) do
        nil -> item
        source -> ancestry(source, MapSet.put(seen, item.id))
      end
    else
      item
    end
  end
end
