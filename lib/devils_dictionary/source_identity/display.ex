defmodule DevilsDictionary.SourceIdentity.Display do
  @moduledoc "Applies current source visibility to images copied onto durable identities."
  import Ecto.Query
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Registry.Entity
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Sources.{MaterializedOutput, SourceRecord}

  @doc "Loads image visibility evidence for a collection in one query."
  def preload(entities) when is_list(entities) do
    object_ids =
      entities
      |> Enum.filter(&image_entity?/1)
      |> Enum.map(& &1.object_id)
      |> Enum.uniq()

    if object_ids == [] do
      %{}
    else
      MaterializedOutput
      |> join(:inner, [output], record in SourceRecord, on: record.id == output.source_record_id)
      |> join(:inner, [_output, record], source in assoc(record, :source))
      |> join(:left, [_output, record, _source], revision in SourceRecordRevision,
        on:
          revision.source_record_id == record.id and
            revision.revision_key == record.content_hash
      )
      |> where(
        [output],
        output.output_object_id in ^object_ids and
          like(output.output_key, "source_identity:%")
      )
      |> select([output, record, source, revision], %{
        object_id: output.output_object_id,
        record_id: record.id,
        allowed: record.display_allowed,
        active: source.active,
        retired_at: output.retired_at,
        raw: revision.payload
      })
      |> Repo.all()
      |> Enum.group_by(& &1.object_id)
    end
  end

  @doc "Returns an image only while its retained source evidence remains displayable."
  def image_url(%Entity{} = entity), do: image_url(entity, preload([entity]))
  def image_url(_entity), do: nil

  def image_url(%{metadata: %{"image_url" => image}} = entity, evidence)
      when is_binary(image) and is_map(evidence) do
    record_id = get_in(entity.metadata, ["source_identity_evidence", "image_url"])
    outputs = Map.get(evidence, entity.object_id, [])

    cond do
      is_integer(record_id) ->
        if Enum.any?(outputs, &(&1.record_id == record_id and allowed?(&1))), do: image

      outputs == [] ->
        image

      true ->
        # Legacy projections have no field provenance. Only retain a poster
        # when an allowed record independently supplies that exact URL.
        if Enum.any?(outputs, fn output ->
             allowed?(output) and
               get_in(output.raw || %{}, ["preview_metadata", "poster_url"]) == image
           end),
           do: image
    end
  end

  def image_url(_entity, _evidence), do: nil

  defp allowed?(output), do: output.allowed and output.active and is_nil(output.retired_at)

  defp image_entity?(%{metadata: %{"image_url" => image}}), do: is_binary(image)
  defp image_entity?(_entity), do: false
end
