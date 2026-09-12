defmodule DevilsDictionary.SourceIdentity.Display do
  @moduledoc "Applies current source visibility to images copied onto durable identities."
  import Ecto.Query
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{MaterializedOutput, SourceRecord}

  def image_url(%{metadata: %{"image_url" => image}} = entity) when is_binary(image) do
    record_id = get_in(entity.metadata, ["source_identity_evidence", "image_url"])

    outputs =
      Repo.all(
        from output in MaterializedOutput,
          join: record in SourceRecord,
          on: record.id == output.source_record_id,
          join: source in assoc(record, :source),
          where:
            output.output_object_id == ^entity.object_id and
              like(output.output_key, "source_identity:%"),
          select: %{
            record_id: record.id,
            allowed: record.display_allowed,
            active: source.active,
            retired_at: output.retired_at
          }
      )

    cond do
      is_nil(image) ->
        nil

      is_integer(record_id) ->
        if Enum.any?(outputs, &(&1.record_id == record_id and allowed?(&1))), do: image

      outputs == [] ->
        image

      true ->
        # Legacy projections have no field provenance. Only retain a poster
        # when an allowed record independently supplies that exact URL.
        ids = outputs |> Enum.filter(&allowed?/1) |> Enum.map(& &1.record_id)

        Enum.find_value(ids, fn id ->
          raw = DevilsDictionary.Sources.raw(Repo.get!(SourceRecord, id)) || %{}
          if get_in(raw, ["preview_metadata", "poster_url"]) == image, do: image
        end)
    end
  end

  def image_url(_entity), do: nil

  defp allowed?(output), do: output.allowed and output.active and is_nil(output.retired_at)
end
