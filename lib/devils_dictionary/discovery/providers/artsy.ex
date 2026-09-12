defmodule DevilsDictionary.Discovery.Providers.Artsy do
  @moduledoc "Artsy source registration and explicit server-side artwork discovery capabilities."

  @behaviour DevilsDictionary.Discovery.Provider

  @impl true
  def slug, do: "artsy"

  @impl true
  def adapter_version, do: "artsy.rest.v1"

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "Artsy",
      tier: :middle,
      kind: :media_provider,
      access: :api,
      era_year: 2026,
      license: "Artsy Public API Terms; removable cache, no permanent archive grant",
      license_url: "https://developers.artsy.net/v2/terms",
      homepage: "https://www.artsy.net/",
      url_template: "https://www.artsy.net/artwork/{external_id}",
      attribution: "Artwork discovery and source metadata: Artsy",
      config: %{
        "mode" => "explicit_server_search_and_selected_enrichment",
        "retention" => "disposable cache unless independently supported",
        "image_storage" => "references only; no downloads",
        "gene_traversal" => "disabled_pending_control_verification",
        "retirement_notice" => true
      }
    }
  end

  @impl true
  def capabilities do
    %{
      background: false,
      transport: :server,
      persistence: :persistent,
      pagination: :offset,
      operations: ["artwork_search"],
      content_types: [:artwork]
    }
  end

  @impl true
  def enabled? do
    config = Application.get_env(:devils_dictionary, :artsy, [])

    config[:enabled] != false and present?(config[:client_id]) and
      present?(config[:client_secret])
  end

  @impl true
  def validate_mapping("artwork_search", %{
        "query" => query,
        "language" => language,
        "match_type" => match_type
      })
      when is_binary(query) and byte_size(query) > 0 and byte_size(query) <= 200 and
             is_binary(language) and match_type in ["exact", "broader", "related"],
      do: :ok

  def validate_mapping(_operation, _parameters), do: {:error, :unsupported_filter}

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
