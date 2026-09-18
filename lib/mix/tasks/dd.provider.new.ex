defmodule Mix.Tasks.Dd.Provider.New do
  @shortdoc "Scaffold a discovery provider, a corpus, or both"

  @moduledoc ~S"""
  Writes everything a new cultural source needs except its own knowledge of the
  API it talks to (K7 of #109).

      mix dd.provider.new poetrydb \
        --archetype both \
        --content-type text \
        --transport get \
        --pagination offset

  There are two archetypes and no third (K1). A **discovery provider** answers a
  page live through the shared pipeline; a **corpus** is a committed,
  checksummed manifest seeded onto the registry. A source may be one or both.

  ## Options

    * `--archetype` — `discovery`, `corpus` or `both`. Required.
    * `--content-type` — one of the types the reader can present. Required for
      `discovery` and `both`. An unknown type is refused with the list.
    * `--transport` — `get` or `graphql`. Required for `discovery` and `both`.
    * `--pagination` — `offset` or `cursor`. Required for `discovery` and
      `both`. `:none` is not offered: a provider that cannot page says so by
      never returning a cursor, and declaring `:none` skips the conformance
      pagination case.
    * `--name` — the display name; defaults to the slug, capitalized.
    * `--root` — write under this directory instead of the project root. Used by
      the generator's own test, which scaffolds into a temporary directory.

  ## What it writes

  For `discovery`:

    * `lib/devils_dictionary/discovery/providers/<slug>.ex` — the provider
    * `test/support/discovery/conformance/<slug>_fixture.ex` — its `Req.Test`
      stub and the target it covers
    * `test/devils_dictionary/discovery/conformance/<slug>_conformance_test.exs`
      — the one-line suite that runs `DevilsDictionary.Discovery.Conformance`
    * the `:discovery_providers` entry and a `config :devils_dictionary, :<slug>`
      stanza in `config/config.exs`, and the test-environment stanza in
      `config/test.exs`

  For `corpus`:

    * `lib/devils_dictionary/artworks/corpus/<slug>.ex` — the manifest builder

  The scaffolded discovery provider passes
  `DevilsDictionary.Discovery.Conformance` unedited, against its own generated
  stub. It does **not** talk to the real API: the response envelope it parses is
  the one its stub produces, and replacing that envelope with the real one — and
  the stub with the real fixture — is the work `docs/discovery/adding-a-provider.md`
  describes.

  ## What it does not write, and why

  A corpus has two registration points that are pattern matches in shared
  modules rather than configuration: the kind in
  `DevilsDictionary.Artworks.Corpus.Manifest`'s `@kinds` — its source, its
  identity field, the `external_identifiers` namespace that field is written
  to, the `work_kind` it is seeded as and the `evidence` it carries — and the
  `entry/3` clause in
  `DevilsDictionary.Artworks.Corpus.Seeder` that maps a row onto a
  `SourceIdentity.Entry`. Only the person who has read the source's rows can
  write the second one, so the task prints both rather than guessing at them.
  This is a real gap between #109's K7 and the code, recorded here rather than
  papered over.
  """

  use Mix.Task

  alias DevilsDictionary.Discovery.ContentTypes

  @archetypes ~w(discovery corpus both)
  @transports ~w(get graphql)
  @paginations ~w(offset cursor)

  @switches [
    archetype: :string,
    content_type: :string,
    transport: :string,
    pagination: :string,
    name: :string,
    root: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("unknown option: #{invalid |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}")
    end

    slug = slug!(rest)
    archetype = choice!(opts, :archetype, @archetypes)
    root = opts[:root] || File.cwd!()

    assigns = assigns(slug, archetype, opts)

    # Every path is decided, and every collision refused, before the first
    # `File.write!/2`. Checking as it went would leave a half-written scaffold
    # behind when the fourth output collided with something already there, and
    # a partial scaffold is worse than none: the next run refuses the files it
    # wrote itself.
    planned =
      List.flatten([
        if(archetype in ~w(discovery both), do: discovery_files(assigns), else: []),
        if(archetype in ~w(corpus both), do: corpus_files(assigns), else: []),
        ledger(assigns)
      ])

    refuse_collisions!(root, planned)
    written = Enum.map(planned, fn {relative, contents} -> write(root, relative, contents) end)

    Enum.each(written, &Mix.shell().info("  created  #{Path.relative_to(&1, root)}"))

    if archetype in ~w(discovery both), do: configure(root, assigns)

    next_steps(assigns)
    written
  end

  defp assigns(slug, archetype, opts) do
    underscored = String.replace(slug, "-", "_")

    base = %{
      slug: slug,
      underscored: underscored,
      module: Macro.camelize(underscored),
      name: opts[:name] || slug |> String.split("-") |> Enum.map_join(" ", &String.capitalize/1),
      archetype: archetype,
      operation: "#{underscored}_search",
      namespace: "#{underscored}_item"
    }

    if archetype in ~w(discovery both) do
      Map.merge(base, %{
        content_type: content_type!(opts),
        transport: choice!(opts, :transport, @transports),
        pagination: choice!(opts, :pagination, @paginations)
      })
    else
      base
    end
  end

  # Hyphen-separated segments, and no empty ones: a trailing or doubled hyphen
  # would make the slug → module name mapping lossy. `Macro.camelize/1` folds
  # `demo_` and `demo` to `Demo`, and `a__b` and `a_b` to `AB`, so `demo-` would
  # generate a second file quietly redefining the module `demo` generated — a
  # collision the path check cannot see, because the paths differ.
  @slug ~r/\A[a-z][a-z0-9]*(-[a-z0-9]+)*\z/

  defp slug!([slug]) do
    unless Regex.match?(@slug, slug) do
      Mix.raise("""
      #{inspect(slug)} is not a usable provider slug.

      A slug is lowercase letters and digits in hyphen-separated words, starting
      with a letter — `poetrydb`, `open-library`, `chronicling-america`. No
      leading, trailing or doubled hyphen: it names the source row, the config
      key, the generated files *and* the module, and `demo-` and `demo` would
      both be `Demo`.
      """)
    end

    slug
  end

  defp slug!(_rest) do
    Mix.raise("""
    mix dd.provider.new expects exactly one slug.

        mix dd.provider.new <slug> --archetype discovery --content-type text \\
          --transport get --pagination offset
    """)
  end

  defp choice!(opts, key, allowed) do
    flag = "--" <> String.replace(to_string(key), "_", "-")

    case opts[key] do
      nil ->
        Mix.raise("#{flag} is required. Valid values: #{Enum.join(allowed, ", ")}")

      value when is_binary(value) ->
        if value in allowed do
          value
        else
          Mix.raise(
            "#{flag} #{inspect(value)} is not valid. Valid values: #{Enum.join(allowed, ", ")}"
          )
        end
    end
  end

  # The content-type table is the reader's, not this task's: a provider ships
  # zero components (K2), so a type the table cannot present is a shelf that
  # would never appear.
  defp content_type!(opts) do
    known = Enum.map(ContentTypes.known(), &to_string/1)

    case opts[:content_type] do
      nil ->
        Mix.raise("--content-type is required. Valid values: #{Enum.join(known, ", ")}")

      value ->
        if value in known do
          value
        else
          Mix.raise("""
          --content-type #{inspect(value)} is not in the reader's content-type table.

          Valid values: #{Enum.join(known, ", ")}

          Adding a type is an entry in DevilsDictionary.Discovery.ContentTypes —
          a heading, a label, a badge, an aspect ratio and the thumbnail key
          ladder — and nothing else. See docs/discovery/README.md.
          """)
        end
    end
  end

  defp discovery_files(assigns) do
    [
      {"lib/devils_dictionary/discovery/providers/#{assigns.underscored}.ex",
       provider_template(assigns)},
      {"test/support/discovery/conformance/#{assigns.underscored}_fixture.ex",
       fixture_template(assigns)},
      {"test/devils_dictionary/discovery/conformance/#{assigns.underscored}_conformance_test.exs",
       suite_template(assigns)}
    ]
  end

  defp corpus_files(assigns) do
    [
      {"lib/devils_dictionary/artworks/corpus/#{assigns.underscored}.ex",
       corpus_template(assigns)}
    ]
  end

  defp ledger(assigns) do
    [{"docs/integrations/#{assigns.slug}.md", ledger_template(assigns)}]
  end

  defp refuse_collisions!(root, planned) do
    case Enum.filter(planned, fn {relative, _} -> File.exists?(Path.join(root, relative)) end) do
      [] ->
        :ok

      collisions ->
        Mix.raise("""
        refusing to overwrite #{length(collisions)} existing #{if length(collisions) == 1, do: "file", else: "files"}; nothing was written:

        #{Enum.map_join(collisions, "\n", fn {relative, _} -> "  " <> relative end)}
        """)
    end
  end

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, format(relative, contents))
    path
  end

  # The templates interleave EEx branches with Elixir, which leaves whitespace
  # no reviewer should have to look at. The formatter is the arbiter of layout
  # here exactly as it is everywhere else, so the scaffold arrives already
  # `mix format`-clean and a generated file never shows up in a format diff.
  defp format(relative, contents) do
    if Path.extname(relative) in [".ex", ".exs"] do
      contents
      |> Code.format_string!(file: relative)
      |> IO.iodata_to_binary()
      |> Kernel.<>("\n")
    else
      contents
    end
  end

  # ---------------------------------------------------------------- config

  defp configure(root, assigns) do
    config = Path.join(root, "config/config.exs")
    test = Path.join(root, "config/test.exs")

    if File.exists?(config) do
      config |> File.read!() |> register(assigns) |> then(&File.write!(config, &1))
      Mix.shell().info("  updated  config/config.exs")
    end

    if File.exists?(test) do
      File.write!(test, File.read!(test) <> test_stanza(assigns))
      Mix.shell().info("  updated  config/test.exs")
    end
  end

  @registry ~r/(config :devils_dictionary, :discovery_providers, \[\n)(.*?)(\n\])/s

  defp register(source, assigns) do
    module = "DevilsDictionary.Discovery.Providers.#{assigns.module}"

    replaced =
      Regex.replace(@registry, source, fn _whole, open, body, close ->
        entries =
          body
          |> String.split(",\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Kernel.++([module])
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.map_join(",\n", &("  " <> &1))

        open <> entries <> close
      end)

    insert_stanza(replaced, assigns)
  end

  @import_marker "# Import environment specific config."

  defp insert_stanza(source, assigns) do
    stanza = config_stanza(assigns)

    case String.split(source, @import_marker, parts: 2) do
      [before, rest] -> before <> stanza <> @import_marker <> rest
      [_whole] -> source <> stanza
    end
  end

  defp config_stanza(assigns) do
    """
    config :devils_dictionary, :#{assigns.underscored},
      endpoint: "https://#{assigns.slug}.example/api",
      enabled: true

    """
  end

  defp test_stanza(assigns) do
    """

    # Scaffolded by `mix dd.provider.new #{assigns.slug}`. Every request in the
    # suite goes through the `Req.Test` stub named after the provider module.
    config :devils_dictionary, :#{assigns.underscored},
      endpoint: "https://#{assigns.slug}.test/api",
      enabled: true
    """
  end

  defp next_steps(assigns) do
    Mix.shell().info("""

    next:
      1. mix compile
      2. mix test test/devils_dictionary/discovery/conformance/#{assigns.underscored}_conformance_test.exs
      3. replace the scaffolded response envelope and its stub with the real one
      4. record the probe in docs/integrations/#{assigns.slug}.md — running totals, not a total at the end

    docs/discovery/adding-a-provider.md is the whole checklist.
    """)

    if assigns.archetype in ~w(corpus both) do
      Mix.shell().error("""
      two edits this task cannot make for a corpus:

        * add "#{assigns.slug}" to @kinds in
          lib/devils_dictionary/artworks/corpus/manifest.ex, with all five keys:
            source      the source slug the rows are attributed to
            identity    the row field this kind is keyed on
            namespace   the external_identifiers namespace that field is
                        written to — not always the same as identity
            work_kind   the work_details.work_kind the seeder writes
                        ("artwork", "poem", ...)
            evidence    :depiction when a row records the QIDs of what the work
                        shows and a page can match on them, :none when it
                        records identity and display facts only
          Anything short of all five and either a seeded row cannot be read
          back or Corpus.Conformance asks this corpus for a contract it does
          not have.
        * add an `entry("#{assigns.slug}", version, row)` clause to
          lib/devils_dictionary/artworks/corpus/seeder.ex that maps a row onto a
          SourceIdentity.Entry

      Both are pattern matches in shared modules, and only a reader of the
      source's own rows can write the second one.
      """)
    end
  end

  # ------------------------------------------------------------- templates

  defp provider_template(assigns) do
    EEx.eval_string(provider_eex(), assigns: assigns)
  end

  defp fixture_template(assigns), do: EEx.eval_string(fixture_eex(), assigns: assigns)
  defp suite_template(assigns), do: EEx.eval_string(suite_eex(), assigns: assigns)
  defp corpus_template(assigns), do: EEx.eval_string(corpus_eex(), assigns: assigns)
  defp ledger_template(assigns), do: EEx.eval_string(ledger_eex(), assigns: assigns)

  defp provider_eex do
    ~S'''
    defmodule DevilsDictionary.Discovery.Providers.<%= @module %> do
      @moduledoc """
      <%= @name %>, scaffolded by `mix dd.provider.new <%= @slug %>`.

      This module implements `DevilsDictionary.Discovery.Provider` end to end
      against a **scaffolded response envelope**, not against the real API. It
      passes `DevilsDictionary.Discovery.Conformance` as generated, which proves
      the pipeline wiring; making it true of the real source is three edits:

        1. `request_options/1` — the real URL, parameters and headers
        2. `parse/1` — the real response shape
        3. `item/2` — the real identity, preview fields and match reason

      Two rules the pipeline will not enforce for you:

        * **Identity, not text.** A result is kept because an identifier matched
          an identifier — a QID, a keyword id, a gene — never because a title
          contained the word. A text provider's evidence is attestation (K11):
          the work *uses* the word, shown as `uses "war"`, never as *about* war.
        * **Pacing is a capability.** If this source throttles, declare
          `request_interval_ms` (and `min_retry_interval_ms`) in
          `capabilities/0` and let `DevilsDictionary.Discovery.Transport` hold
          the rate. Never `Process.sleep/1` inside `retrieve/4`.
      """

      @behaviour DevilsDictionary.Discovery.Provider

      @adapter_version "<%= @underscored %>.v1"
      @operation "<%= @operation %>"

      @impl true
      def slug, do: "<%= @slug %>"

      @impl true
      def adapter_version, do: @adapter_version

      @impl true
      def source_attrs do
        %{
          slug: slug(),
          name: "<%= @name %>",
          tier: :middle,
          kind: :media_provider,
          access: :api,
          license: "TODO: the source's licence, and what it permits being stored",
          homepage: "https://<%= @slug %>.example/",
          url_template: "https://<%= @slug %>.example/items/{external_id}",
          attribution: "<%= @name %>",
          active: true,
          config: %{"operation" => @operation}
        }
      end

      @impl true
      def capabilities do
        %{
          background: true,
          transport: :server,
          persistence: :persistent,
          pagination: :<%= @pagination %>,
          operations: [@operation],
          content_types: [:<%= @content_type %>]
          # If this source throttles, add the two pacing keys here:
          #   min_retry_interval_ms: 1_500,
          #   request_interval_ms: 3_000
        }
      end

      @impl true
      def enabled? do
        config()[:enabled] != false and is_binary(config()[:endpoint])
      end

      @impl true
      def shelf_detail, do: nil

      @impl true
      def automatic_mapping(target) do
        {@operation,
         %{
           "term" => String.trim(target.term),
           "language" => target.language,
           "relevance" => target.relevance,
           "resolution_strategy" => "literal_search_v1"
         }}
      end

      @impl true
      def validate_mapping(@operation, %{"term" => term}) when is_binary(term) and term != "",
        do: :ok

      def validate_mapping(_operation, _parameters), do: {:error, :invalid_mapping}
    <%= if @transport == "get" do %>
      @impl true
      def request_options(payload) do
        [
          method: :get,
          url: config()[:endpoint],
          params: %{
            q: payload["term"],
            <%= if @pagination == "offset" do %>offset: payload["offset"],<% else %>cursor: payload["cursor"],<% end %>
            limit: payload["limit"]
          },
          headers: headers()
        ]
      end
    <% else %>
      @query """
      query Search($query: String!, $first: Int!, $after: String) {
        search(query: $query, first: $first, after: $after) {
          nodes { id title year url }
          pageInfo { endCursor hasNextPage }
        }
      }
      """

      @impl true
      def request_options(payload) do
        [
          method: :post,
          url: config()[:endpoint],
          json: %{
            query: @query,
            variables: %{
              "query" => payload["term"],
              "first" => payload["limit"],
              "after" => <%= if @pagination == "offset" do %>payload["offset"]<% else %>payload["cursor"]<% end %>
            }
          },
          headers: headers()
        ]
      end
    <% end %>
      defp headers do
        [{"user-agent", Application.fetch_env!(:devils_dictionary, :user_agent)}]
      end

      @impl true
      def retrieve(@operation, mapping, request, request_fun) do
        with :ok <- validate_mapping(@operation, mapping) do
          limit = request["first"] || 10
    <%= if @pagination == "offset" do %>      offset = offset(request["after"])

          payload = %{
            "term" => mapping["term"],
            "offset" => Integer.to_string(offset),
            "limit" => limit
          }
    <% else %>      payload = %{
            "term" => mapping["term"],
            "cursor" => request["after"],
            "limit" => limit
          }
    <% end %>
          case request_fun.(@operation, payload) do
            {:ok, body} ->
              case parse(body) do
    <%= if @pagination == "offset" do %>            {:ok, rows, _cursor} -> {:ok, page(mapping, request, rows, offset, limit)}
    <% else %>            {:ok, rows, cursor} -> {:ok, page(mapping, request, rows, cursor)}
    <% end %>            :error -> {:error, "malformed_response"}
              end

            {:error, code} ->
              {:error, code}

            {:deferred, code, seconds} ->
              {:deferred, code, seconds, request}
          end
        else
          {:error, _reason} -> {:error, "invalid_mapping"}
        end
      end

      def retrieve(_operation, _mapping, _request, _request_fun), do: {:error, "invalid_mapping"}

      # The scaffolded envelope. Replace this with the real one — it is the
      # single place the shape of the response is known.
    <%= if @transport == "get" do %>  defp parse(%{"results" => rows, "next" => cursor}) when is_list(rows), do: {:ok, rows, cursor}
      defp parse(%{"results" => rows}) when is_list(rows), do: {:ok, rows, nil}
    <% else %>  defp parse(%{"data" => %{"search" => %{"nodes" => rows, "pageInfo" => page_info}}})
           when is_list(rows) do
        cursor = if page_info["hasNextPage"], do: page_info["endCursor"]
        {:ok, rows, cursor}
      end
    <% end %>  defp parse(_body), do: :error
    <%= if @pagination == "offset" do %>
      defp page(mapping, request, rows, offset, limit) do
        items = items(mapping, rows)

        %{
          request_parameters: Map.put(request, "offset", Integer.to_string(offset)),
          items: items,
          # A full page means there is at least one more behind it; the next
          # offset is the whole of the cursor this provider understands.
          next_cursor: if(length(rows) == limit, do: Integer.to_string(offset + limit)),
          completion_reason: if(items == [], do: :no_results, else: :results)
        }
      end

      defp offset(nil), do: 0

      defp offset(value) when is_binary(value) do
        case Integer.parse(value) do
          {offset, ""} when offset >= 0 -> offset
          _ -> 0
        end
      end

      defp offset(_value), do: 0
    <% else %>
      defp page(mapping, request, rows, cursor) do
        items = items(mapping, rows)

        %{
          request_parameters: request,
          items: items,
          next_cursor: cursor,
          completion_reason: if(items == [], do: :no_results, else: :results)
        }
      end
    <% end %>
      defp items(mapping, rows) do
        rows
        |> Enum.map(&item(mapping, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.external_id)
        |> Enum.with_index(&Map.put(&1, :position, &2))
      end

      # One normalized item. `match_details` is the factual reason this result is
      # on this page, read back by `DevilsDictionary.Discovery.MatchReason` —
      # `"tags"` for identity matches, `"keywords"` for keyword ids, `"lines"`
      # for a text attestation. The scaffold names no reason, which renders as
      # *the provider returned this result for “war”*; that is honest and it is
      # not good enough to ship.
      defp item(mapping, %{"id" => id} = row) when not is_nil(id) do
        %{
          external_namespace: "<%= @namespace %>",
          external_id: to_string(id),
          position: 0,
          match_details: %{"kind" => "query", "query" => mapping["term"]},
          preview_metadata:
            %{
              "title" => row["title"],
              "year" => row["year"],
              "source_url" => row["url"],
              "content_type" => "<%= @content_type %>",
              "provider" => "<%= @name %>"
            }
            |> Enum.reject(fn {_key, value} -> is_nil(value) end)
            |> Map.new(),
          display_allowed: true
        }
      end

      defp item(_mapping, _row), do: nil

      defp config, do: Application.get_env(:devils_dictionary, :<%= @underscored %>, [])
    end
    '''
  end

  defp fixture_eex do
    ~S'''
    defmodule DevilsDictionary.Discovery.Conformance.<%= @module %>Fixture do
      @moduledoc """
      Conformance for `DevilsDictionary.Discovery.Providers.<%= @module %>`,
      scaffolded by `mix dd.provider.new <%= @slug %>`.

      The stub answers the envelope the scaffolded provider parses. When the
      provider learns the real response shape, this learns it too — they are a
      pair, and the conformance suite is what keeps them one.
      """

      use DevilsDictionary.Discovery.Conformance.Fixture

      alias DevilsDictionary.Discovery.Providers.<%= @module %>

      @impl true
      def provider, do: <%= @module %>

      @impl true
      def covered_target(context) do
        word = word!(context, "war", ~w(wordnet))

        %{
          object_id: word.object_id,
          term: word.lemma,
          language: word.language_tag,
          relevance: "term"
        }
      end

      @impl true
      def stub(:empty, _context) do
        respond([])
        %{pages: [[]]}
      end

      def stub(:results, _context) do
        # Two rows against a `result_limit` of three: a short page, so
        # pagination ends rather than promising a page with nothing behind it.
        respond(rows(2))
        %{pages: [~w(1 2)]}
      end

      def stub(:paged, _context) do
        respond(rows(5))
        %{pages: [~w(1 2 3), ~w(4 5)]}
      end

      defp rows(count) do
        Enum.map(1..count//1, fn id ->
          %{
            "id" => id,
            "title" => "<%= @name %> result #{id}",
            "year" => "1751",
            "url" => "https://<%= @slug %>.test/items/#{id}"
          }
        end)
      end

      defp respond(rows) do
        Req.Test.stub(<%= @module %>, fn conn ->
    <%= if @transport == "get" do %>      conn = Plug.Conn.fetch_query_params(conn)
          limit = String.to_integer(conn.params["limit"])
    <%= if @pagination == "offset" do %>      offset = String.to_integer(conn.params["offset"] || "0")
    <% else %>      offset = cursor_offset(conn.params["cursor"])
    <% end %>
    <% else %>      variables = request_body(conn)["variables"]
          limit = variables["first"]
    <%= if @pagination == "offset" do %>      offset = String.to_integer(variables["after"] || "0")
    <% else %>      offset = cursor_offset(variables["after"])
    <% end %>
    <% end %>      page = Enum.slice(rows, offset, limit)
          next = if length(page) == limit, do: "cursor-#{offset + limit}"

          Req.Test.json(conn, envelope(page, next))
        end)
      end
    <%= if @pagination == "cursor" do %>
      defp cursor_offset("cursor-" <> offset), do: String.to_integer(offset)

      # nil on the first page; Req serialises a nil query parameter as an empty
      # string, so both spellings of "no cursor yet" mean offset zero.
      defp cursor_offset(_value), do: 0
    <% end %><%= if @transport == "get" do %>
      defp envelope(rows, next), do: %{"results" => rows, "next" => next}
    <% else %>
      defp envelope(rows, next) do
        %{
          "data" => %{
            "search" => %{
              "nodes" => rows,
              "pageInfo" => %{"endCursor" => next, "hasNextPage" => is_binary(next)}
            }
          }
        }
      end

      defp request_body(conn) do
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        Jason.decode!(body)
      end
    <% end %>end
    '''
  end

  defp suite_eex do
    ~S'''
    defmodule DevilsDictionary.Discovery.Conformance.<%= @module %>ConformanceTest do
      use DevilsDictionary.Discovery.Conformance,
        fixture: DevilsDictionary.Discovery.Conformance.<%= @module %>Fixture
    end
    '''
  end

  defp corpus_eex do
    ~S'''
    defmodule DevilsDictionary.Artworks.Corpus.<%= @module %> do
      @moduledoc """
      Builds the `<%= @slug %>` corpus manifest, scaffolded by
      `mix dd.provider.new <%= @slug %>`.

      A corpus is a **selection**, built once and committed, never re-run at
      seed time: the #99 P0 probe measured the Met's own search totals as
      parameter-order-sensitive, so a corpus that re-queried would be a
      different corpus every time and nobody could say which rows a page had
      been showing. `DevilsDictionary.Artworks.Corpus.Manifest.new/3`
      deduplicates on the kind's identity field, orders by it and checksums the
      result; `save!/2` writes it to `priv/artworks/manifests/`.

      Two edits this scaffold could not make, both pattern matches in shared
      modules:

        1. `@kinds` in `DevilsDictionary.Artworks.Corpus.Manifest` needs
           `"<%= @slug %>" => %{source: "<%= @slug %>", identity: "...",
           namespace: "...", work_kind: "...", evidence: :depiction | :none}`.
           `identity` is the row field this kind is keyed on; `namespace` is the
           `external_identifiers` namespace the seeder writes it to. They are
           not always the same — a Wikidata row is keyed on `qid` and identified
           as `wikidata` — and `Corpus.Conformance` reads a seeded row back
           through `Manifest.identity_namespace/1`. `work_kind` is what the
           seeder writes to `work_details`, and `evidence` is whether a row of
           this kind carries depicted QIDs a page can match on (`:depiction`)
           or identity and display facts only (`:none`). The suite asks a
           corpus only for the contract its `evidence` declares, and holds it
           to that declaration.
        2. `DevilsDictionary.Artworks.Corpus.Seeder.entry/3` needs a clause for
           `"<%= @slug %>"` mapping one row onto a
           `DevilsDictionary.SourceIdentity.Entry` — the identity namespace, the
           label, the year, and the metadata the shelf reads.

      Until both exist, `Manifest.new/3` raises on this kind, which is the
      failure you want rather than a manifest nothing can seed.
      """

      alias DevilsDictionary.Artworks.Corpus.Manifest

      @kind "<%= @slug %>"

      @doc "The manifest kind this builder produces."
      def kind, do: @kind

      @doc """
      Builds the manifest from `rows` and writes it to `path`.

      Rows arrive from a **bounded** probe with a request ceiling and a ledger
      written as it goes — never a total recorded at the end, because a run that
      is killed then leaves a range instead of a number.
      """
      def build!(rows, path \\ default_path(), metadata \\ %{}) when is_list(rows) do
        @kind
        |> Manifest.new(rows, metadata)
        |> Manifest.save!(path)
      end

      @doc "Where the committed manifest lives."
      def default_path, do: "priv/artworks/manifests/#{@kind}-v1.json"
    end
    '''
  end

  defp ledger_eex do
    ~S'''
    # <%= @name %>

    Scaffolded by `mix dd.provider.new <%= @slug %>`. Fill this in as the
    probe runs, not after it: a builder writes **running** totals, because a run
    that is killed leaves a range instead of a number.

    ## Posture

    | | |
    |---|---|
    | Slug | `<%= @slug %>` |
    | Archetype | <%= @archetype %> |
    | Licence | TODO — and what it permits being *stored*, not only shown |
    | Key required | TODO |
    | Published rate limit | TODO |
    | Measured sustainable rate | TODO — the measured one, not the published one |
    | Images | references only; bytes are never downloaded |

    ## Probe

    Ceiling: **200 requests**. Stop at it.

    | date | requests | what was asked | what came back |
    |---|---|---|---|
    | | | | |

    **Running total: 0 / 200.**

    ## What identity a result carries

    Association is identity, not text. Name the identifier this source publishes
    and the identifier the encyclopedia already holds, and how the two meet:

    - Source identifier: TODO
    - Encyclopedia identifier: TODO
    - Crosswalk: TODO

    ## Measured facts

    Things nobody should have to measure twice — refusal rates, parameters that
    do not do what they say, fields that are free text, ceilings.

    - TODO

    ## Conformance

        mix test test/devils_dictionary/discovery/conformance/<%= @underscored %>_conformance_test.exs
    '''
  end
end
