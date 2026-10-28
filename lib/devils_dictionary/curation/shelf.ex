defmodule DevilsDictionary.Curation.Shelf do
  @moduledoc "The declared provider fields, date meanings and bounded metadata labels (#270)."
  alias DevilsDictionary.Curation.Digest

  @providers %{
    "guardian" => {"news", "published_at", "second", "published"},
    "bing-news" => {"news", "published_at", "second", "published"},
    "spotify" => {"music", "year", "year", "album released"},
    "pexels" => {"images", nil, nil, nil},
    "openverse" => {"images", nil, nil, nil},
    "unsplash" => {"images", "year", "year", "uploaded"},
    "commons" => {"images", "year", "year", "created"},
    "met" => {"images", "year", "free_text", "object date"},
    "cinegraph" => {"films", "release_date", "day", "released"},
    "open-library" => {"books", "year", "year", "first published"},
    "poetrydb" => {"poems", nil, nil, nil},
    "wikiquote" => {"quotes", "year", "year", "earliest citation year"}
  }
  def providers, do: Map.keys(@providers)
  def kinds, do: ~w(news images films music books poems quotes)
  def kind(slug), do: @providers |> Map.fetch!(slug) |> elem(0)

  def date(slug, metadata) do
    {_kind, key, precision, meaning} = Map.fetch!(@providers, slug)
    %{value: key && metadata[key], precision: precision, meaning: meaning}
  end

  def creator(metadata),
    do:
      metadata["creator"] || metadata["author"] || metadata["artist"] || metadata["masthead"] ||
        metadata["attribution"]

  def label(slug, metadata) do
    date = date(slug, metadata)
    source = DevilsDictionary.Sources.get_source_by_slug(slug)

    [
      kind(slug) <> ": " <> text(metadata["title"] || "untitled"),
      creator(metadata) || (source && source.name),
      date.value && "#{date.value} (#{date.meaning})"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&text/1)
    |> Enum.join(" · ")
    |> String.slice(0, 300)
  end

  def expiring_provider?(slug), do: slug not in ["commons", "met", "poetrydb", "wikiquote"]

  def expiring_text(slug, metadata) do
    if slug in ["commons", "met", "open-library", "poetrydb", "wikiquote"] do
      []
    else
      {_kind, date_key, _precision, _meaning} = Map.fetch!(@providers, slug)
      source = DevilsDictionary.Sources.get_source_by_slug(slug)

      keys =
        Enum.uniq(~w(title creator author artist masthead attribution) ++ List.wrap(date_key))

      for key <- keys,
          is_binary(metadata[key]),
          do: %{
            field: key,
            value: metadata[key],
            source_name: source && source.name,
            policy: "shelf-fields-v1"
          }
    end
  end

  @bibliographic ~w(title year author author_keys olid ia source_url read_url cover_url)
  def expiring_fields(slug, payload) do
    source = DevilsDictionary.Sources.get_source_by_slug(slug)

    expired =
      cond do
        not expiring_provider?(slug) ->
          %{}

        slug == "cinegraph" ->
          Map.take(payload, ["preview_metadata", "match_details"])

        slug == "open-library" ->
          payload
          |> Map.take(["preview_metadata", "match_details"])
          |> Map.update("preview_metadata", %{}, &Map.drop(&1, @bibliographic))

        true ->
          Map.drop(payload, ["external_namespace", "external_ref_sha256", "_discovery_redaction"])
      end

    for {field, value} <- field_values(expired, []),
        do: %{
          field: field,
          value: value,
          source_name: source && source.name,
          policy: "shelf-fields-v1"
        }
  end

  defp field_values(value, path) when is_binary(value),
    do: [{Enum.join(Enum.reverse(path), "."), value}]

  defp field_values(value, path) when is_map(value),
    do: Enum.flat_map(value, fn {k, v} -> field_values(v, [to_string(k) | path]) end)

  defp field_values(value, path) when is_list(value),
    do:
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {v, i} -> field_values(v, [to_string(i) | path]) end)

  defp field_values(_, _), do: []

  def policy_hash(policy), do: Digest.term(policy)
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_list(value), do: Enum.map_join(value, ", ", &text/1)
  defp text(value), do: to_string(value)
end
