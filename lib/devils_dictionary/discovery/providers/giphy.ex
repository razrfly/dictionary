defmodule DevilsDictionary.Discovery.Providers.Giphy do
  @moduledoc "Automatic, direct-browser GIPHY discovery; no persistent results."

  @behaviour DevilsDictionary.Discovery.Provider

  @operation "gif_search"
  @adapter_version "giphy.browser.v2"

  @doc "The identity namespace one GIPHY result would be registered under: its id."
  def namespace, do: "giphy_gif"

  @impl true
  def slug, do: "giphy"

  @impl true
  def adapter_version, do: @adapter_version

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
      logo: "/images/sources/giphy.png",
      url_template: "https://giphy.com/gifs/{id}",
      attribution: "Powered by GIPHY",
      active: true,
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
    config = config()

    config[:enabled] != false and is_binary(config[:api_key]) and
      String.trim(config[:api_key]) != ""
  end

  @impl true
  def browser_config(target) do
    source = DevilsDictionary.Sources.get_source_by_slug(slug())

    if target && enabled?() && source && source.active do
      config = config()

      %{
        provider: slug(),
        provider_name: source_attrs().name,
        # From the row, as a server state's is: the badge's ring and the
        # stack's order read it (#152).
        tier: source.tier,
        logo: source.logo,
        content_type: :gif,
        hook: "GiphyShelf",
        term: target.term,
        language: target.language,
        api_key: config[:api_key],
        note:
          "Search matches, not reviewed interpretations. " <>
            "Hover, focus or press Play to animate.",
        # A licence obligation and not decoration: the GIPHY API Terms require
        # the mark on any surface showing their results. It travels with the
        # config so the shared renderer can honour it without knowing whose it
        # is (#144 Phase 3), in the one shape every mark takes — the same map
        # a server provider returns from `attribution_mark/0`, read by the
        # same `Culture.mark/1` and drawn by the same component.
        attribution_mark: attribution_mark()
      }
    end
  end

  @impl true
  def attribution_mark do
    %{
      light: "/images/giphy-powered-by.png",
      dark: nil,
      alt: "Powered by GIPHY",
      href: "https://giphy.com/",
      # The file GIPHY publishes is 200 px wide; the byline column is 80, so
      # that is what it is drawn at, as the shelf drew it before this.
      width: 80,
      # The terms ask for the mark on any surface showing GIPHY results, and
      # a browser shelf is one surface however many cards its hook draws.
      placement: :shelf
    }
  end

  # No pacing keys, deliberately, where CineGraph and the Met gained them in
  # the same phase: `Discovery.Transport` issues none of this provider's
  # requests — they leave the reader's browser — so a `request_interval_ms`
  # here would be a rate declared to something that will never read it. The
  # hook keeps its own client-side accounting (K10).
  defp config, do: DevilsDictionary.Discovery.Provider.Helpers.config(:giphy)
end
