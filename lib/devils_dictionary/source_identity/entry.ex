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
  """

  @entity_kinds DevilsDictionary.Registry.Entity.kinds()

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
            relationships: []

  @doc "Builds and validates one adapter proposal."
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    entry = struct(__MODULE__, attrs)

    with {:ok, stable} <- normalize_optional_identifier(entry.stable_identifier),
         {:ok, identifiers} <- normalize_identifiers(entry.identifiers, stable),
         :ok <- validate_shape(entry, stable, identifiers),
         :ok <- validate_relationships(entry.relationships) do
      {:ok, %{entry | stable_identifier: stable, identifiers: identifiers}}
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

  defp validate_relationships(relationships) when is_list(relationships) do
    if Enum.all?(relationships, &valid_relationship?/1),
      do: :ok,
      else: {:error, :invalid_relationship}
  end

  defp validate_relationships(_relationships), do: {:error, :invalid_relationships}

  defp valid_relationship?(%{} = relationship) do
    role = relationship[:role] || relationship["role"]
    target_object_id = relationship[:target_object_id] || relationship["target_object_id"]
    target_identifiers = relationship[:target_identifiers] || relationship["target_identifiers"]
    certainty = relationship[:certainty] || relationship["certainty"]

    present?(to_string(role || "")) and
      certainty in [:verified, :candidate, "verified", "candidate"] and
      (is_integer(target_object_id) or valid_target_identifiers?(target_identifiers))
  end

  defp valid_relationship?(_relationship), do: false

  defp valid_target_identifiers?(identifiers) when is_list(identifiers) and identifiers != [] do
    Enum.all?(identifiers, fn identifier -> match?({:ok, _}, normalize_identifier(identifier)) end)
  end

  defp valid_target_identifiers?(_identifiers), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
