defmodule DevilsDictionary.SourceIdentity.Entry do
  @moduledoc """
  A provider-neutral proposal for one encyclopedia identity.

  `stable_identifier` is the provider's durable key and `identifiers` contains
  exact, namespaced crosswalks. Titles and dates are display facts only: they
  are never consulted for identity resolution. An eligible durable entity must
  have a credible source, stable identifier, supported subtype and label.

  Relationships are references, not embedded identities. A quotation can
  therefore remain ineligible while its independently identified author is
  resolved, and a reproduction can point at an artwork without becoming the
  artwork.

  ## Relationships (#164)

  Each is `%{role, target_identifiers | target_object_id, certainty}`, and
  `new/1` returns them normalised: `role` a string (it names a predicate in
  `priv/predicates/*.json`), `certainty` an atom, `target_identifiers` in the
  same shape as `identifiers`, and `register: true` when the provider read the
  target out of a misattribution register. A register target is never
  `authored_by` (#164 C4) and `new/1` refuses the combination rather than
  trusting every provider to remember it. The order is the provider's own and is
  kept: a coauthor's origin key is its position (#164 C3).

  ## Content (#164 C2)

  An entry of `object_kind: :content` carries the text it proposes in a
  `content` map — `body`, `body_format`, `canonical_url`, `headword`, `year`,
  `rights_metadata` — and its `content_kind` must be one of
  `Registry.ContentItem.kinds/0`. The map is required for content and refused
  for anything else, so an entity proposal cannot smuggle a body in and a
  quotation cannot arrive without one.
  """

  alias DevilsDictionary.Registry.{ContentItem, ContentRevision}

  @entity_kinds DevilsDictionary.Registry.Entity.kinds()
  @content_kinds ContentItem.kinds()
  @body_formats ContentRevision.formats()

  @type external_identifier :: %{
          required(:namespace) => String.t(),
          required(:external_id) => String.t(),
          optional(:metadata) => map(),
          optional(:exclusive) => boolean()
        }

  @type t :: %__MODULE__{}

  defstruct source_slug: nil,
            source_id: nil,
            source_record_id: nil,
            source_record_revision_id: nil,
            import_run_id: nil,
            object_kind: :entity,
            entity_kind: nil,
            work_kind: nil,
            content_kind: nil,
            stable_identifier: nil,
            identifiers: [],
            label: nil,
            description: nil,
            year: nil,
            original_language: nil,
            metadata: %{},
            eligibility: :eligible,
            eligibility_reason: nil,
            retention: :durable,
            relationships: [],
            content: nil

  @doc "Builds and validates one adapter proposal."
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    entry = struct(__MODULE__, attrs)

    with {:ok, stable} <- normalize_optional_identifier(entry.stable_identifier),
         {:ok, identifiers} <- normalize_identifiers(entry.identifiers, stable),
         :ok <- validate_shape(entry, stable, identifiers),
         {:ok, content} <- normalize_content(entry),
         {:ok, relationships} <- normalize_relationships(entry.relationships) do
      {:ok,
       %{
         entry
         | stable_identifier: stable,
           identifiers: identifiers,
           content: content,
           relationships: relationships
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_entry}

  defp validate_shape(entry, stable, identifiers) do
    cond do
      entry.object_kind not in [:entity, :content] ->
        {:error, :unsupported_object_kind}

      entry.object_kind == :entity and entry.entity_kind not in @entity_kinds ->
        {:error, :unsupported_entity_kind}

      entry.object_kind == :entity and entry.entity_kind == :work and
          not present?(entry.work_kind) ->
        {:error, :work_kind_required}

      entry.object_kind == :content and entry.content_kind not in @content_kinds ->
        {:error, :unsupported_content_kind}

      entry.eligibility not in [:eligible, :insufficient_evidence, :restricted] ->
        {:error, :invalid_eligibility}

      entry.retention not in [:durable, :transient] ->
        {:error, :invalid_retention}

      entry.eligibility == :eligible and entry.retention != :durable ->
        {:error, :eligible_entry_must_be_durable}

      entry.eligibility == :eligible and not present?(entry.source_slug) ->
        {:error, :source_required}

      entry.eligibility == :eligible and is_nil(stable) ->
        {:error, :stable_identifier_required}

      entry.eligibility == :eligible and not present?(entry.label) ->
        {:error, :label_required}

      stable && stable not in identifiers ->
        {:error, :stable_identifier_not_supported}

      true ->
        :ok
    end
  end

  defp normalize_identifiers(identifiers, stable) when is_list(identifiers) do
    identifiers = if stable, do: [stable | identifiers], else: identifiers

    identifiers
    |> Enum.reduce_while({:ok, []}, fn identifier, {:ok, acc} ->
      case normalize_identifier(identifier) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} ->
        {:ok,
         normalized
         |> Enum.reverse()
         |> Enum.uniq_by(&{&1.namespace, &1.external_id})}

      error ->
        error
    end
  end

  defp normalize_identifiers(_, _stable), do: {:error, :invalid_identifiers}

  defp normalize_optional_identifier(nil), do: {:ok, nil}
  defp normalize_optional_identifier(identifier), do: normalize_identifier(identifier)

  defp normalize_identifier({namespace, external_id}),
    do: normalize_identifier(%{namespace: namespace, external_id: external_id})

  defp normalize_identifier(%{} = identifier) do
    namespace = identifier[:namespace] || identifier["namespace"]
    external_id = identifier[:external_id] || identifier["external_id"]
    metadata = identifier[:metadata] || identifier["metadata"] || %{}
    exclusive = Map.get(identifier, :exclusive, Map.get(identifier, "exclusive", true))

    cond do
      not present?(namespace) or not Regex.match?(~r/\A[a-z0-9_]{2,80}\z/, namespace) ->
        {:error, :invalid_identifier_namespace}

      not present?(external_id) or byte_size(external_id) > 255 ->
        {:error, :invalid_external_identifier}

      not is_map(metadata) or not is_boolean(exclusive) ->
        {:error, :invalid_identifier_metadata}

      true ->
        {:ok,
         %{
           namespace: namespace,
           external_id: external_id,
           metadata: metadata,
           exclusive: exclusive
         }}
    end
  end

  defp normalize_identifier(_identifier), do: {:error, :invalid_identifier}

  defp normalize_content(%{object_kind: :content, content: content}) when is_map(content) do
    body = content[:body] || content["body"]
    format = content[:body_format] || content["body_format"] || :text
    url = content[:canonical_url] || content["canonical_url"]
    headword = content[:headword] || content["headword"]
    year = content[:year] || content["year"]
    rights = content[:rights_metadata] || content["rights_metadata"] || %{}

    cond do
      not present?(body) ->
        {:error, :content_body_required}

      format not in @body_formats ->
        {:error, :unsupported_body_format}

      not (is_nil(url) or is_binary(url)) ->
        {:error, :invalid_canonical_url}

      not (is_nil(headword) or is_binary(headword)) ->
        {:error, :invalid_headword}

      not (is_nil(year) or is_integer(year)) ->
        {:error, :invalid_content_year}

      not is_map(rights) ->
        {:error, :invalid_rights_metadata}

      true ->
        {:ok,
         %{
           body: body,
           body_format: format,
           canonical_url: url,
           headword: headword,
           year: year,
           rights_metadata: rights
         }}
    end
  end

  defp normalize_content(%{object_kind: :content}), do: {:error, :content_required}
  defp normalize_content(%{content: nil}), do: {:ok, nil}
  defp normalize_content(_entry), do: {:error, :content_only_for_content_objects}

  defp normalize_relationships(relationships) when is_list(relationships) do
    relationships
    |> Enum.reduce_while({:ok, []}, fn relationship, {:ok, acc} ->
      case normalize_relationship(relationship) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_relationships(_relationships), do: {:error, :invalid_relationships}

  defp normalize_relationship(%{} = relationship) do
    role = relationship[:role] || relationship["role"]
    target_object_id = relationship[:target_object_id] || relationship["target_object_id"]
    target_identifiers = relationship[:target_identifiers] || relationship["target_identifiers"]
    certainty = relationship[:certainty] || relationship["certainty"]
    register = Map.get(relationship, :register, Map.get(relationship, "register", false))
    role = if is_atom(role) and not is_nil(role), do: Atom.to_string(role), else: role

    with true <- present?(role) || {:error, :invalid_relationship},
         {:ok, certainty} <- certainty(certainty),
         true <- is_boolean(register) || {:error, :invalid_relationship},
         true <-
           not (register and role == "authored_by") ||
             {:error, :register_target_cannot_be_authored_by},
         {:ok, targets} <- relationship_targets(target_object_id, target_identifiers) do
      {:ok, Map.merge(targets, %{role: role, certainty: certainty, register: register})}
    end
  end

  defp normalize_relationship(_relationship), do: {:error, :invalid_relationship}

  defp certainty(value) when value in [:verified, "verified"], do: {:ok, :verified}
  defp certainty(value) when value in [:candidate, "candidate"], do: {:ok, :candidate}
  defp certainty(_value), do: {:error, :invalid_relationship}

  defp relationship_targets(id, _identifiers) when is_integer(id),
    do: {:ok, %{target_object_id: id, target_identifiers: []}}

  defp relationship_targets(_id, identifiers) when is_list(identifiers) and identifiers != [] do
    identifiers
    |> Enum.reduce_while({:ok, []}, fn identifier, {:ok, acc} ->
      case normalize_identifier(identifier) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        _error -> {:halt, {:error, :invalid_relationship}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        {:ok, %{target_object_id: nil, target_identifiers: Enum.reverse(normalized)}}

      error ->
        error
    end
  end

  defp relationship_targets(_id, _identifiers), do: {:error, :invalid_relationship}

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
