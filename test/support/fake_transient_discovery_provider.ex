defmodule DevilsDictionary.FakeTransientDiscoveryProvider do
  @moduledoc "A second provider shape used only to prove transient, non-film capability handling."

  @behaviour DevilsDictionary.Discovery.Provider

  def slug, do: "transient-fixture"
  def adapter_version, do: "transient.fixture.v1"
  def enabled?, do: true

  def source_attrs do
    %{
      slug: slug(),
      name: "Transient fixture",
      tier: :middle,
      kind: :media_provider,
      access: :api,
      license: "Test fixture only",
      homepage: "https://fixture.invalid/",
      url_template: "https://fixture.invalid/",
      attribution: "Controlled fixture; not a live provider",
      active: true,
      config: %{}
    }
  end

  def capabilities do
    %{
      background: true,
      transport: :server,
      persistence: :transient,
      pagination: :none,
      operations: ["search"],
      content_types: [:art]
    }
  end

  def automatic_mapping(target) do
    {"search",
     %{
       "term" => String.trim(target.term),
       "language" => target.language,
       "resolution_strategy" => "literal_search_v1",
       "relevance" => target.relevance
     }}
  end

  def request_options(_payload), do: []

  def validate_mapping("search", %{"term" => term}) when is_binary(term) and term != "", do: :ok
  def validate_mapping(_operation, _mapping), do: {:error, :invalid_mapping}

  def retrieve("search", mapping, request, _request_fun) do
    cond do
      String.starts_with?(mapping["term"], "fixture-failure") ->
        {:error, "fixture_failure"}

      String.starts_with?(mapping["term"], "fixture-empty") ->
        success(request, [])

      true ->
        success(request, [
          %{
            external_namespace: "fixture_art",
            external_id: "one",
            position: 0,
            match_details: %{"kind" => "query", "evidence" => "query", "query" => mapping["term"]},
            preview_metadata: %{
              "title" => "Transient work",
              "content_type" => "art",
              "provider" => "Transient fixture"
            },
            display_allowed: true
          }
        ])
    end
  end

  defp success(request, items) do
    {:ok,
     %{
       request_parameters: request,
       next_cursor: nil,
       completion_reason: if(items == [], do: :no_results, else: :results),
       items: items
     }}
  end
end
