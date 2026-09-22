defmodule DevilsDictionary.Tasks.DdDiscoveryCheckTest do
  @moduledoc """
  The preflight walks the registry (#144 Phase 4).

  Until this phase the task checked **CineGraph**, by name, and had done since
  the second provider was registered: eleven of the twelve could have had a
  missing credential, a nonsense endpoint or an unreadable policy and it would
  still have printed *CineGraph configuration ready*. The cases here are the
  two halves of the repair — every registered provider is checked, and no
  provider is named in the task to do it.

  The last case is the one with teeth: every credential value this environment
  holds is looked for in the task's own output, character for character.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias DevilsDictionary.Discovery.Providers
  alias DevilsDictionary.FakeOffsetDiscoveryProvider, as: Fake

  # Values a preflight could only print by reading them. A sentence rather
  # than a random-looking token, so a substring search cannot be fooled and a
  # secret scanner reading this file is not either: nothing here has ever been
  # a credential anywhere.
  @secrets %{
    cinegraph: [api_key: "cinegraph-value-a-preflight-must-never-print"],
    giphy: [api_key: "giphy-value-a-preflight-must-never-print"],
    guardian: [api_key: "guardian-value-a-preflight-must-never-print"],
    pexels: [api_key: "pexels-value-a-preflight-must-never-print"],
    unsplash: [access_key: "unsplash-value-a-preflight-must-never-print"],
    spotify: [
      client_id: "spotify-id-a-preflight-must-never-print",
      client_secret: "spotify-value-a-preflight-must-never-print"
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

  defp run, do: capture_io(fn -> Mix.Tasks.Dd.Discovery.Check.run([]) end)

  defp configure(key, overrides) do
    config = Application.get_env(:devils_dictionary, key, [])
    Application.put_env(:devils_dictionary, key, Keyword.merge(config, overrides))
  end

  # Swapping the registry leaves the shipped `source_policies` naming slugs
  # that are no longer registered, which `validate!/0` refuses — rightly, and
  # not what any of these cases is about.
  defp register(modules) do
    config = Application.fetch_env!(:devils_dictionary, :discovery)

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(config, :source_policies, %{})
    )

    Application.put_env(:devils_dictionary, :discovery_providers, modules)
  end

  defp policy(slug, overrides) do
    config = Application.fetch_env!(:devils_dictionary, :discovery)
    policies = Keyword.get(config, :source_policies, %{})

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(config, :source_policies, Map.put(policies, slug, overrides))
    )
  end

  test "one row per registered provider, and the count is the registry's", ctx do
    output = run()

    assert output =~ "PROVIDERS (#{length(ctx.registry)} registered)"

    for provider <- ctx.registry do
      assert output =~ provider.slug()
    end
  end

  test "a provider registered today is checked, with no edit to the task" do
    register([Fake])

    output = run()

    assert output =~ "PROVIDERS (1 registered)"
    assert output =~ Fake.slug()
  end

  test "a credential's presence is reported and its value is not, for every provider that has one" do
    for {stanza, values} <- @secrets, do: configure(stanza, values)

    Application.put_env(
      :devils_dictionary,
      :provider_credentials,
      Map.new(
        ~w(CINEGRAPH_API_KEY GIPHY_API_KEY GUARDIAN_API_KEY PEXELS_API_KEY UNSPLASH_ACCESS_KEY
           SPOTIFY_CLIENT_ID SPOTIFY_CLIENT_SECRET),
        &{&1, true}
      )
    )

    output = run()

    assert output =~ "GUARDIAN_API_KEY present"
    assert output =~ "SPOTIFY_CLIENT_SECRET present"

    # The rule with teeth. Every value configured above, looked for whole in
    # everything the task printed.
    for {_stanza, values} <- @secrets, {_key, secret} <- values do
      refute output =~ secret
    end
  end

  test "a missing credential is reported and is not a failure — a keyless host is a host" do
    Application.put_env(
      :devils_dictionary,
      :provider_credentials,
      %{"GUARDIAN_API_KEY" => false, "SPOTIFY_CLIENT_ID" => false}
    )

    output = run()

    assert output =~ "GUARDIAN_API_KEY missing"
    assert output =~ "ready ·"
  end

  test "an endpoint that is not an http(s) endpoint fails the preflight" do
    for bad <- ["ftp://example.com", "https://user:secret@example.com/api/graphql", "nonsense"] do
      configure(:cinegraph, endpoint: bad)

      message =
        assert_raise Mix.Error, fn ->
          capture_io(fn -> Mix.Tasks.Dd.Discovery.Check.run([]) end)
        end

      assert Exception.message(message) =~ "is not an http(s) endpoint"
      # And the endpoint that was refused is not repeated with its userinfo.
      refute Exception.message(message) =~ "user:secret"
    end
  end

  test "a policy override the kit cannot read fails the preflight" do
    policy("cinegraph", positive_refresh_seconds: :whenever)

    message =
      assert_raise Mix.Error, fn -> capture_io(fn -> Mix.Tasks.Dd.Discovery.Check.run([]) end) end

    assert Exception.message(message) =~ "invalid duration or limit"
  end

  test "a registry the node would refuse to boot on fails the preflight, in its own words" do
    register([__MODULE__.NotAProvider])

    message =
      assert_raise Mix.Error, fn -> capture_io(fn -> Mix.Tasks.Dd.Discovery.Check.run([]) end) end

    assert Exception.message(message) =~ "does not export"
    assert {:error, _} = safely(fn -> Providers.validate!() end)
  end

  test "the shipped registry passes its own preflight", ctx do
    assert ctx.registry != []
    assert run() =~ "Configuration only"
  end

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  end

  defmodule NotAProvider do
    @moduledoc "Registered, and not a provider. `Providers.validate!/0` says so."
    def slug, do: "not-a-provider"
  end
end
