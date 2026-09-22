defmodule DevilsDictionary.Tasks.DdDiscoveryStatusTest do
  @moduledoc """
  The ledger in a terminal (#144 Phase 4), and the acceptance line that names
  it: *`mix dd.discovery.status` runs on a keyless checkout and prints one row
  per provider*.

  The numbers themselves are `status_test.exs`'s; what is checked here is that
  the task prints a row for every registered provider whatever the environment
  holds, that a provider registered today gets one without this file or the
  task being edited, and that nothing it prints is a credential.
  """

  use DevilsDictionary.DataCase, async: false

  import ExUnit.CaptureIO

  alias DevilsDictionary.FakeOffsetDiscoveryProvider, as: Fake

  @secrets %{
    cinegraph: [api_key: "cinegraph-value-the-status-task-must-never-print"],
    guardian: [api_key: "guardian-value-the-status-task-must-never-print"],
    spotify: [
      client_id: "spotify-id-the-status-task-must-never-print",
      client_secret: "spotify-value-the-status-task-must-never-print"
    ]
  }

  setup do
    discovery = Application.fetch_env!(:devils_dictionary, :discovery)
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    credentials = Application.get_env(:devils_dictionary, :provider_credentials, %{})

    stanzas =
      Map.new(@secrets, fn {key, _} -> {key, Application.get_env(:devils_dictionary, key)} end)

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery, discovery)
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :provider_credentials, credentials)

      for {key, value} <- stanzas do
        if is_nil(value),
          do: Application.delete_env(:devils_dictionary, key),
          else: Application.put_env(:devils_dictionary, key, value)
      end
    end)

    %{registry: providers}
  end

  defp run(args \\ []), do: capture_io(fn -> Mix.Tasks.Dd.Discovery.Status.run(args) end)

  defp register(modules) do
    config = Application.fetch_env!(:devils_dictionary, :discovery)

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(config, :source_policies, %{})
    )

    Application.put_env(:devils_dictionary, :discovery_providers, modules)
  end

  test "one row per registered provider — twelve rows, not one", ctx do
    output = run()

    assert output =~ "DISCOVERY (#{length(ctx.registry)} registered providers"

    for provider <- ctx.registry do
      assert output =~ provider.slug()
    end

    assert rows(output) == length(ctx.registry)
  end

  test "a keyless checkout gets the same twelve rows, and says which are waiting", ctx do
    # Every credential gone, every stanza's key gone: the state of a fresh
    # clone with no `.env`, which is where this task has to work.
    Application.put_env(:devils_dictionary, :provider_credentials, %{})

    for {stanza, values} <- @secrets do
      config = Application.get_env(:devils_dictionary, stanza, [])
      Application.put_env(:devils_dictionary, stanza, Keyword.drop(config, Keyword.keys(values)))
    end

    output = run()

    assert rows(output) == length(ctx.registry)
    assert output =~ "no key"
    # And the providers that need nothing are still ready, so "no key" is a
    # statement about a provider and not about the machine.
    assert output =~ "ready"
  end

  test "a provider registered today gets a row, with no edit to the task" do
    register([Fake])

    output = run()

    assert output =~ "DISCOVERY (1 registered providers"
    assert output =~ Fake.slug()
    assert output =~ "never"
    assert rows(output) == 1
  end

  test "nothing it prints is a credential" do
    for {stanza, values} <- @secrets do
      config = Application.get_env(:devils_dictionary, stanza, [])
      Application.put_env(:devils_dictionary, stanza, Keyword.merge(config, values))
    end

    Application.put_env(:devils_dictionary, :provider_credentials, %{
      "CINEGRAPH_API_KEY" => true,
      "GUARDIAN_API_KEY" => true,
      "SPOTIFY_CLIENT_SECRET" => true
    })

    output = run()

    for {_stanza, values} <- @secrets, {_key, secret} <- values do
      refute output =~ secret
    end
  end

  test "the retention bound is the operator's to widen, and is said out loud" do
    assert run() =~ "next 500 due"
    assert run(["--retention-limit", "2000"]) =~ "next 2000 due"

    assert_raise Mix.Error, ~r/positive integer/, fn ->
      run(["--retention-limit", "0"])
    end

    assert_raise Mix.Error, ~r/invalid arguments/, fn -> run(["--nonsense"]) end
  end

  # The table's own rows: a line that begins with two spaces and a slug, which
  # the header and the footnotes do not.
  defp rows(output) do
    output
    |> String.split("\n")
    |> Enum.count(
      &Regex.match?(~r/^  [a-z][a-z0-9-]*\s{2,}(ready|no key|off|browser|inactive)/, &1)
    )
  end
end
