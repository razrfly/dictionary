defmodule DevilsDictionary.FakeQuoteDiscoveryProvider do
  @moduledoc """
  A quotation provider shaped like build 4's Wikiquote provider, for #164.

  It exists so creator identity is proved through the real pipeline — admission,
  the prepare phase outside the transaction, the budget, the publication
  transaction — for a `content/quotation`, before any real quotation provider is
  allowed to write one (#158: nothing durable for quotations before #164
  closes). Its rows come from `test/support/fixtures/quotes/issue158.json`,
  keyed by search term through `put_rows/2`, so two concurrent runs can ask for
  two different terms.

  A row's creator is a QID or nothing. A `misattributed_to_qid` becomes a
  register relationship (`register: true`), which `Entry.new/1` refuses to make
  an `authored_by` of (#164 C4).
  """

  @behaviour DevilsDictionary.Discovery.Provider
  @behaviour DevilsDictionary.SourceIdentity.Adapter

  alias DevilsDictionary.SourceIdentity.Entry

  @env :quote_fixture_rows

  def slug, do: "quote-fixture"
  def adapter_version, do: "quote.fixture.v1"
  def enabled?, do: true

  @doc "The #158 fixture, decoded."
  def fixture do
    "test/support/fixtures/quotes/issue158.json"
    |> File.read!()
    |> Jason.decode!()
  end

  @doc "The fixture rows with these ids, in this order."
  def rows(ids) do
    by_id = Map.new(fixture()["quotations"], &{&1["id"], &1})
    Enum.map(ids, &Map.fetch!(by_id, &1))
  end

  @doc "What the provider answers for a search term, until `clear_rows/0`."
  def put_rows(term, rows) do
    Application.put_env(
      :devils_dictionary,
      @env,
      Map.put(Application.get_env(:devils_dictionary, @env, %{}), term, rows)
    )
  end

  def clear_rows, do: Application.delete_env(:devils_dictionary, @env)

  def source_attrs do
    %{
      slug: slug(),
      name: "Quote fixture",
      tier: :middle,
      kind: :media_provider,
      access: :api,
      license: "CC BY-SA 4.0",
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
      persistence: :persistent,
      pagination: :none,
      operations: ["search"],
      content_types: [:text]
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
    items =
      :devils_dictionary
      |> Application.get_env(@env, %{})
      |> Map.get(mapping["term"], [])
      |> Enum.with_index()
      |> Enum.map(fn {row, position} -> item(row, mapping["term"], position) end)

    {:ok,
     %{
       request_parameters: request,
       next_cursor: nil,
       completion_reason: if(items == [], do: :no_results, else: :results),
       items: items
     }}
  end

  defp item(row, term, position) do
    %{
      external_namespace: "quote_fixture",
      external_id: row["id"],
      position: position,
      match_details: %{"kind" => "query", "evidence" => "query", "query" => term},
      preview_metadata: %{
        "title" => row["text"],
        "artist" => row["author_display"],
        "work" => row["work"],
        "year" => row["year"],
        "source_url" => row["source_url"],
        "content_type" => "text",
        "provider" => "Quote fixture"
      },
      display_allowed: true,
      row: row
    }
  end

  def identity_record(%{external_namespace: "quote_fixture", row: row}) do
    Entry.new(%{
      source_slug: slug(),
      object_kind: :content,
      content_kind: :quotation,
      stable_identifier: %{namespace: "quote_fixture", external_id: row["id"]},
      label: row["text"],
      year: row["year"],
      content: %{
        body: row["text"],
        canonical_url: row["source_url"],
        year: row["year"],
        rights_metadata: %{"license" => "CC BY-SA 4.0"}
      },
      metadata: %{"author_display_name" => row["author_display"]},
      relationships: relationships(row),
      eligibility: :eligible,
      retention: :durable
    })
  end

  def identity_record(_item), do: {:error, :unsupported}

  defp relationships(row) do
    Enum.flat_map(List.wrap(row["author_qids"] || row["author_qid"]), fn qid ->
      credit(qid, "authored_by", false, :verified)
    end) ++
      credit(row["misattributed_to_qid"], "misattributed_to", true, :candidate)
  end

  defp credit(nil, _role, _register, _certainty), do: []

  defp credit(qid, role, register, certainty) do
    [
      %{
        role: role,
        target_identifiers: [%{namespace: "wikidata", external_id: qid}],
        certainty: certainty,
        register: register
      }
    ]
  end
end
