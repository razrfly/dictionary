defmodule DevilsDictionary.Discovery.Providers.Giphy do
  @moduledoc "Automatic, direct-browser GIPHY discovery; no persistent results."

  @behaviour DevilsDictionary.Discovery.Provider

  @operation "gif_search"

  @impl true
  def slug, do: "giphy"

  @impl true
  def adapter_version, do: "giphy.browser.v2"

  @impl true
  def source_attrs do
    %{
      slug: slug(),
      name: "GIPHY",
      tier: :plebs,
      kind: :media_provider,
      access: :api,
      era_year: 2013,
      license: "GIPHY API Terms",
      license_url:
        "https://support.giphy.com/hc/en-us/articles/360028134111-GIPHY-API-Terms-of-Service",
      homepage: "https://giphy.com/",
      url_template: "https://giphy.com/gifs/{id}",
      attribution: "Powered by GIPHY",
      config: %{
        "operation" => @operation,
        "shared_cache" => "not used by direct browser discovery",
        "ingestion" => "direct browser only; no server ingestion",
        "media_delivery" => "must remain direct from GIPHY; media is never rehosted"
      }
    }
  end

  @impl true
  def capabilities do
    %{
      background: false,
      transport: :browser,
      persistence: :transient,
      pagination: :offset,
      operations: [@operation],
      content_types: [:gif]
    }
  end

  @impl true
  def enabled? do
    config = Application.get_env(:devils_dictionary, :giphy, [])

    config[:enabled] != false and is_binary(config[:api_key]) and
      String.trim(config[:api_key]) != ""
  end

  def browser_config(target) do
    source = DevilsDictionary.Sources.get_source_by_slug(slug())

    if target && enabled?() && source && source.active do
      config = Application.get_env(:devils_dictionary, :giphy, [])
      %{term: target.term, language: target.language, api_key: config[:api_key]}
    end
  end
end
