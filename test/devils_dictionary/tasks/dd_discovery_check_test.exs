defmodule DevilsDictionary.Tasks.DdDiscoveryCheckTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    original = Application.fetch_env!(:devils_dictionary, :cinegraph)
    on_exit(fn -> Application.put_env(:devils_dictionary, :cinegraph, original) end)
    :ok
  end

  test "rejects missing and blank credentials without printing them" do
    for key <- [nil, "", "   "] do
      configure(api_key: key)
      assert_raise Mix.Error, ~r/CINEGRAPH_API_KEY is missing or blank/, &run/0
    end
  end

  test "disabled or invalid endpoint configuration cannot pass preflight" do
    configure(enabled: false)
    assert_raise Mix.Error, ~r/disabled/, &run/0

    for endpoint <- [nil, "", "ftp://example.com", "https://user:secret@example.com/api/graphql"] do
      configure(endpoint: endpoint)
      assert_raise Mix.Error, ~r/CINEGRAPH_GRAPHQL_URL/, &run/0
    end
  end

  test "successful configuration check does not claim a live verified credential" do
    configure([])
    output = capture_io(&run/0)
    assert output =~ "configuration ready"
    assert output =~ "still require verification"
    refute output =~ "test-secret-never-print"
  end

  defp configure(overrides) do
    config =
      Keyword.merge(
        [
          enabled: true,
          endpoint: "https://cinegraph.org/api/graphql",
          api_key: "test-secret-never-print"
        ],
        overrides
      )

    Application.put_env(:devils_dictionary, :cinegraph, config)
  end

  defp run, do: Mix.Tasks.Dd.Discovery.Check.run([])
end
