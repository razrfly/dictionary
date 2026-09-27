defmodule DevilsDictionary.Curation.Digest do
  @moduledoc """
  The digests curation records are identified and checked by.

  Three of them are recomputed by the database at COMMIT, so the functions
  here and the SQL functions in the curation migration must agree byte for
  byte. They do not need a test of their own: a disagreement fails the insert.

    * `scope_signature/1`: `editorial_scope_signature(composition)`, the
      sorted `role:object_id` members joined by `,`;
    * `roster_hash/1`: `curation_roster_hash(version)`, the
      `slot:profile:profile_version:weight` seats in slot order;
    * `arrangement_hash/1`: `editorial_arrangement_hash(version)`, every item
      field length-prefixed (`~` for NULL), in `(role, position)` order.

  `term/1` digests a canonical JSON encoding, with keys sorted at every
  depth, of a manifest or an eligibility record. The database never
  recomputes it.
  """

  alias DevilsDictionary.Curation.CompositionItem

  @doc "SHA-256, lower-case hex."
  def sha256(binary) when is_binary(binary),
    do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)

  @doc "The signature of a scope, from its `{role, object_id}` members."
  def scope_signature(members) do
    members
    |> Enum.map(fn {role, id} when is_integer(id) -> {to_string(role), id} end)
    |> Enum.sort()
    |> Enum.map_join(",", fn {role, id} -> "#{role}:#{id}" end)
    |> sha256()
  end

  @doc "The digest of a roster: maps with `slot`, `profile_id`, `profile_version_id` and `voting_weight`."
  def roster_hash(members) do
    members
    |> Enum.sort_by(& &1.slot)
    |> Enum.map_join(",", fn m ->
      "#{m.slot}:#{m.profile_id}:#{m.profile_version_id}:#{m.voting_weight}"
    end)
    |> sha256()
  end

  @arrangement_fields ~w(role position item_kind item_object_id content_revision_id
                         sense_revision_id source_record_revision_id catalog_manifest
                         catalog_checksum catalog_identity locator words_sha256
                         meaning_sense_revision_id meaning_lexeme_id assertion_revision_id
                         selection_origin note note_author_kind note_author_label)a

  @doc "The digest of a version's items, as `%CompositionItem{}` structs."
  def arrangement_hash(items) do
    items
    |> Enum.sort_by(&{to_string(&1.role), &1.position})
    |> Enum.map_join(fn %CompositionItem{} = item ->
      Enum.map_join(@arrangement_fields, &field(Map.fetch!(item, &1)))
    end)
    |> sha256()
  end

  defp field(nil), do: "~"
  defp field(value) when is_atom(value), do: field(Atom.to_string(value))
  defp field(value) when is_integer(value), do: field(Integer.to_string(value))
  defp field(value) when is_binary(value), do: "#{byte_size(value)}:#{value}"

  @doc "The digest of a JSON-shaped term, canonically encoded."
  def term(value), do: value |> canonical() |> Jason.encode!() |> sha256()

  defp canonical(%{__struct__: _} = struct), do: struct

  defp canonical(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value
end
