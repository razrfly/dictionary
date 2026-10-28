defmodule DevilsDictionary.Curation.ContentDate do
  @moduledoc "Dates of the selected native record, distinct from fetch and publication."
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Registry.ContentRevision
  alias DevilsDictionary.Artworks.Corpus.Manifest

  def of(%{shelf_citation_id: id}) when is_integer(id),
    do: %{value: nil, precision: nil, meaning: nil}

  def of(%{shelf: shelf}) when is_map(shelf), do: %{value: nil, precision: nil, meaning: nil}

  def of(%{item_kind: kind, content_revision_id: id})
      when kind in [:content, :exemplar] and is_integer(id) do
    case Repo.get(ContentRevision, id) do
      nil ->
        unknown()

      revision ->
        %{
          value: revision.year,
          precision: "year",
          meaning: if(kind == :content, do: "the entry's year", else: "the passage's year")
        }
    end
  end

  def of(%{item_kind: :work, catalog_manifest: manifest, catalog_identity: identity})
      when is_binary(manifest) do
    row = Manifest.committed_row(manifest, identity) || %{}

    cond do
      row["date"] -> %{value: row["date"], precision: "free_text", meaning: "the work's date"}
      row["year"] -> %{value: row["year"], precision: "year", meaning: "the work's year"}
      true -> unknown()
    end
  end

  def of(_), do: unknown()
  defp unknown, do: %{value: nil, precision: nil, meaning: nil}
  def text(%{value: nil}), do: "not supplied"
  def text(%{"value" => nil}), do: "not supplied"
  def text(%{value: v, meaning: m, precision: p}), do: "#{v} · #{m} (#{p})"
  def text(%{"value" => v, "meaning" => m, "precision" => p}), do: "#{v} · #{m} (#{p})"
end
