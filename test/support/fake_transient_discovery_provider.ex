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
    {:ok,
     %{
       request_parameters: request,
       next_cursor: nil,
       completion_reason: :results,
       items: [
         %{
           external_namespace: "fixture_art",
           external_id: "one",
           position: 0,
           match_details: %{"kind" => "search", "query" => mapping["term"]},
           preview_metadata: %{
             "title" => "Transient work",
             "content_type" => "art",
             "provider" => "Transient fixture"
           },
           display_allowed: true
         }
       ]
     }}
  end
end
