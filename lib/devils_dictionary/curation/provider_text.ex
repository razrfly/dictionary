defmodule DevilsDictionary.Curation.ProviderText do
  @moduledoc "Deterministic copied-provider-text rule for retained annotations (#270 L14)."
  alias DevilsDictionary.Curation.{Digest, Shelf, ShelfCitations}
  alias DevilsDictionary.Repo
  def copied?(text, fields), do: not is_nil(match(text, fields))

  def match(text, fields) when is_binary(text) do
    normalized = normalize(text)

    Enum.find_value(fields, fn field ->
      value = field[:value] || field["value"]
      source_name = field[:source_name] || field["source_name"]
      value = if is_binary(value), do: normalize(value), else: ""
      words = String.split(value)

      five =
        if length(words) >= 5,
          do: Enum.chunk_every(words, 5, 1, :discard) |> Enum.map(&Enum.join(&1, " ")),
          else: []

      if String.length(value) >= 12 and value != normalize(source_name || "") and
           (String.contains?(normalized, value) or
              Enum.any?(five, &String.contains?(normalized, &1))) do
        %{
          "field" => field[:field] || field["field"],
          "policy" => field[:policy] || field["policy"] || "shelf-fields-v1",
          "sha256" => Digest.sha256(text)
        }
      end
    end)
  end

  def match(_, _), do: nil

  def normalize(text),
    do:
      text
      |> :unicode.characters_to_nfkc_binary()
      |> String.to_charlist()
      |> :string.casefold()
      |> List.to_string()
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

  def validate(texts, items, opts \\ []) do
    texts = flatten(texts) |> Enum.reject(&(String.trim(&1) == ""))

    case fields(items) do
      {:error, :provider_text_unverifiable} ->
        if texts == [] or
             (opts[:fixed_reason] &&
                Enum.all?(texts, &(&1 in ["dismissed_by_owner", "withdrawn_by_owner"]))),
           do: :ok,
           else: {:error, :provider_text_unverifiable}

      {:ok, fields} ->
        case Enum.find_value(texts, &match(&1, fields)) do
          nil -> :ok
          marker -> {:error, {:copies_provider_text, marker["field"]}}
        end
    end
  end

  def fields(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      cond do
        item.shelf_citation_id ->
          c = ShelfCitations.get(item.shelf_citation_id)

          source = Repo.get!(DevilsDictionary.Sources.Source, c.source_id)

          case if(Shelf.expiring_provider?(source.slug),
                 do: ShelfCitations.payload(c),
                 else: :durable
               ) do
            :durable ->
              {:cont, {:ok, acc}}

            nil ->
              {:halt, {:error, :provider_text_unverifiable}}

            payload ->
              source = Repo.get!(DevilsDictionary.Sources.Source, c.source_id)

              {:cont, {:ok, acc ++ Shelf.expiring_fields(source.slug, payload)}}
          end

        item.shelf ->
          id = item.shelf[:result] || item.shelf["result"]

          case Repo.get(DevilsDictionary.Discovery.Result, id) do
            nil ->
              {:halt, {:error, :provider_text_unverifiable}}

            result ->
              run = Repo.get!(DevilsDictionary.Discovery.Run, result.run_id)
              o = ShelfCitations.observation(result, run)

              if o.status == :ok,
                do: {:cont, {:ok, acc ++ Shelf.expiring_fields(o.source.slug, o.payload)}},
                else: {:halt, {:error, :provider_text_unverifiable}}
          end

        true ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp flatten(value) when is_binary(value), do: [value]
  defp flatten(value) when is_list(value), do: Enum.flat_map(value, &flatten/1)
  defp flatten(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&flatten/1)
  defp flatten(_), do: []
end
