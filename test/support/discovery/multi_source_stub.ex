defmodule DevilsDictionary.Discovery.MultiSourceStub do
  @moduledoc """
  Two stub providers on one content type, for the multi-source shelf check
  (#116 Phase 1; K6 of #109).

  The single-provider suite proves that one provider behaves; it cannot prove
  that two of them on one shelf become one rail. That needs two registered
  modules declaring the same type whose answers are *coordinated* — one item
  in each carrying the same upstream identity, one in each carrying the same
  media URL — and nothing a real fixture returns is coordinated with anything.
  So the two modules under `multi_source/` are stubs, both written by this
  macro, differing only in what `use` says:

      use DevilsDictionary.Discovery.MultiSourceStub,
        slug: "zz-middle-stub", name: "Middle stub", tier: :middle,
        namespace: "stub_middle", evidence: :identity

  `evidence` is which kind of reason the stub writes — `:identity` (a `P180`
  depiction, Commons-shaped) or `:query` (a keyword search that says so,
  Openverse-shaped, M6) — so the check sees both classes the `:image` row
  admits on one shelf.

  Both stubs share one `Req.Test` plug, this module, and the stub dispatches
  on the request's host; `stub/1` installs it and returns what each provider
  will deliver.
  """

  @upstream "stub_upstream"
  @shared_identity "shared-identity"
  @shared_media "https://upload.stub.invalid/photos/shared.jpg"

  @doc "The identifier namespace both stubs' first items share."
  def upstream_namespace, do: @upstream

  @doc """
  Installs one `Req.Test` stub answering both providers, keyed by host, and
  returns `%{provider => [external_id]}` — what each will deliver.

  Each provider answers eight items. Item 1 of both carries the same upstream
  identifier; item 2 of both carries the same media URL, spelled differently
  (scheme case, host case, a sizing query string) so that only a *canonical*
  comparison sees it. The other six are that provider's own.
  """
  def stub(providers) when is_list(providers) do
    rows = Map.new(providers, &{&1, rows(&1)})

    Req.Test.stub(__MODULE__, fn conn ->
      provider = Enum.find(providers, &(&1.host() == conn.host))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"results" => rows[provider]}))
    end)

    Map.new(rows, fn {provider, rows} -> {provider, Enum.map(rows, & &1["id"])} end)
  end

  defp rows(provider) do
    slug = provider.slug()

    for index <- 1..8 do
      base = %{
        "id" => "#{slug}-#{index}",
        "title" => "#{provider.name()} item #{index}",
        "creator" => "Photographer #{index}",
        "image_url" => "https://upload.stub.invalid/photos/#{slug}/#{index}.jpg",
        "thumbnail_url" => "https://thumb.stub.invalid/#{slug}/#{index}.jpg"
      }

      case index do
        1 -> Map.put(base, "upstream", @shared_identity)
        2 -> Map.put(base, "image_url", spell(provider, @shared_media))
        _ -> base
      end
    end
  end

  # One provider spells the shared URL as it is; the other upper-cases the
  # scheme and host and appends a sizing query, which is what a CDN does.
  defp spell(provider, url) do
    if provider.tier() == :plebs do
      url
      |> String.replace("https://upload", "HTTPS://Upload")
      |> Kernel.<>("?w=640&fit=max")
    else
      url
    end
  end

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour DevilsDictionary.Discovery.Provider

      @slug Keyword.fetch!(opts, :slug)
      @name Keyword.fetch!(opts, :name)
      @tier Keyword.fetch!(opts, :tier)
      @namespace Keyword.fetch!(opts, :namespace)
      @evidence Keyword.fetch!(opts, :evidence)
      @host "#{@slug}.invalid"
      @operation "image_search"

      @impl true
      def slug, do: @slug

      @doc "The provider's display name, as its source row carries it."
      def name, do: @name

      @doc "The tier this stub declares, which is what the shelf sorts it by."
      def tier, do: @tier

      @doc "The host the shared stub answers this provider on."
      def host, do: @host

      @impl true
      def adapter_version, do: "multi-source.stub.v1"

      @impl true
      def enabled?, do: true

      @impl true
      def source_attrs do
        %{
          slug: @slug,
          name: @name,
          tier: @tier,
          kind: :media_provider,
          access: :api,
          license: "Test fixture only",
          homepage: "https://#{@host}/",
          url_template: "https://#{@host}/photos/{external_id}",
          attribution: "Controlled fixture; not a live provider",
          active: true,
          config: %{}
        }
      end

      @impl true
      def capabilities do
        %{
          background: true,
          transport: :server,
          persistence: :persistent,
          pagination: :none,
          operations: [@operation],
          content_types: [:image]
        }
      end

      @impl true
      def automatic_mapping(target) do
        {@operation,
         %{
           "term" => String.trim(target.term),
           "language" => target.language,
           "resolution_strategy" => "stub_v1",
           "relevance" => target.relevance
         }}
      end

      @impl true
      def validate_mapping(@operation, %{"term" => term}) when is_binary(term) and term != "",
        do: :ok

      def validate_mapping(_operation, _mapping), do: {:error, :invalid_mapping}

      @impl true
      def request_options(payload) do
        [method: :get, url: "https://#{@host}/search", params: %{q: payload["term"]}]
      end

      @impl true
      def retrieve(@operation, mapping, request, request_fun) do
        with :ok <- validate_mapping(@operation, mapping),
             {:ok, %{"results" => rows}} when is_list(rows) <-
               request_fun.(@operation, %{"term" => mapping["term"]}) do
          items =
            rows
            |> Enum.with_index()
            |> Enum.map(fn {row, index} -> item(row, index, mapping["term"]) end)

          {:ok,
           %{
             request_parameters: request,
             items: items,
             next_cursor: nil,
             completion_reason: if(items == [], do: :no_results, else: :results)
           }}
        else
          {:ok, _body} -> {:error, "malformed_response"}
          {:error, code} when is_binary(code) -> {:error, code}
          {:error, _reason} -> {:error, "invalid_mapping"}
          {:deferred, code, seconds} -> {:deferred, code, seconds, request}
        end
      end

      def retrieve(_operation, _mapping, _request, _request_fun), do: {:error, "invalid_mapping"}

      defp item(row, index, term) do
        upstream =
          case row["upstream"] do
            id when is_binary(id) ->
              [
                %{
                  namespace: DevilsDictionary.Discovery.MultiSourceStub.upstream_namespace(),
                  external_id: id,
                  exclusive: false
                }
              ]

            _none ->
              []
          end

        %{
          external_namespace: @namespace,
          external_id: row["id"],
          identifiers: [%{namespace: @namespace, external_id: row["id"]} | upstream],
          position: index,
          match_details: match_details(term),
          preview_metadata: %{
            "title" => row["title"],
            "year" => "1916",
            "image_url" => row["image_url"],
            "thumbnail_url" => row["thumbnail_url"],
            "source_url" => "https://#{@host}/photos/#{row["id"]}",
            # M4 of #116: the fixed names every `:image` item carries.
            "license" => "CC-BY-4.0",
            "license_url" => "https://creativecommons.org/licenses/by/4.0/",
            "creator" => row["creator"],
            "creator_url" => "https://#{@host}/people/#{index}",
            "attribution" => "#{row["creator"]}, CC BY 4.0, via #{@name}",
            "content_type" => "image",
            "provider" => @name
          },
          display_allowed: true
        }
      end

      # Commons-shaped: the file's own `P180` names a QID (an identity reason).
      if @evidence == :identity do
        defp match_details(_term) do
          %{
            "kind" => "depiction",
            "depicts" => [
              %{
                "qid" => "Q4991371",
                "relation" => "exact",
                "entity_qid" => "Q4991371",
                "entity_label" => "soldier"
              }
            ]
          }
        end
      else
        # Openverse-shaped (M6): a keyword search that is honest about being
        # one, which is the only reason the `:image` row admits besides identity.
        defp match_details(term), do: %{"kind" => "query", "query" => term}
      end
    end
  end
end
