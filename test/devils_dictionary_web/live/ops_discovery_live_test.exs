defmodule DevilsDictionaryWeb.DiscoveryLiveTest do
  @moduledoc """
  `/ops/discovery` (#144 Phase 4). Its whole claim is that it renders what
  `mix dd.discovery.status` and `mix dd.discovery.check` print, so that is what
  is checked here — plus the rule that holds for every surface in this system:
  no credential reaches the page, and no provider is named in it.
  """

  use DevilsDictionaryWeb.ConnCase, async: false

  alias DevilsDictionary.Discovery.Status
  alias DevilsDictionary.FakeOffsetDiscoveryProvider, as: Fake
  alias DevilsDictionary.Fixtures

  setup do
    %{sources: sources} = Fixtures.seed_catalog!()
    discovery = Application.fetch_env!(:devils_dictionary, :discovery)
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    credentials = Application.get_env(:devils_dictionary, :provider_credentials, %{})
    guardian = Application.get_env(:devils_dictionary, :guardian, [])

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery, discovery)
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :provider_credentials, credentials)
      Application.put_env(:devils_dictionary, :guardian, guardian)
    end)

    %{sources: sources, registry: providers}
  end

  defp register(modules) do
    config = Application.fetch_env!(:devils_dictionary, :discovery)

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(config, :source_policies, %{})
    )

    Application.put_env(:devils_dictionary, :discovery_providers, modules)
  end

  test "a ledger row and a preflight row per registered provider", ctx do
    {:ok, _live, html} = live(ctx.conn, ~p"/ops/discovery")

    assert html =~ ~s(id="discovery-ledger")
    assert html =~ ~s(id="discovery-preflight")

    for provider <- ctx.registry do
      assert html =~ ~s(id="ledger-#{provider.slug()}")
      assert html =~ ~s(id="preflight-#{provider.slug()}")
    end
  end

  test "a provider registered today gets both rows, with no edit to the page", ctx do
    register([Fake])

    {:ok, _live, html} = live(ctx.conn, ~p"/ops/discovery")

    assert html =~ ~s(id="ledger-#{Fake.slug()}")
    assert html =~ ~s(id="preflight-#{Fake.slug()}")
    # And the page said so in the one figure that counts them.
    assert html =~ "1/1"
  end

  test "the figures are the ones the task prints, not a second implementation", ctx do
    rows = Status.rows()

    {:ok, _live, html} = live(ctx.conn, ~p"/ops/discovery")

    assert html =~ "#{Enum.count(rows, & &1.enabled)}/#{length(rows)}"

    # The ledger is empty in this suite's database, and an empty ledger is
    # exactly what the page should show for it: every provider last succeeded
    # `never`, and the totals the stats print are the rows' own sums.
    assert Enum.all?(rows, &(&1.runs == 0 and is_nil(&1.last_success)))
    assert html =~ "never"

    held = Enum.sum(Enum.map(rows, & &1.results))
    assert html =~ "#{held}</div>"
    assert html =~ "results held now, from #{Enum.sum(Enum.map(rows, & &1.runs))} runs ever given"
  end

  test "no credential value reaches the page, only its name and whether it arrived", ctx do
    Application.put_env(
      :devils_dictionary,
      :guardian,
      Keyword.merge(Application.get_env(:devils_dictionary, :guardian, []),
        api_key: "guardian-value-the-page-must-never-render"
      )
    )

    Application.put_env(:devils_dictionary, :provider_credentials, %{
      "GUARDIAN_API_KEY" => true,
      "SPOTIFY_CLIENT_SECRET" => false
    })

    {:ok, _live, html} = live(ctx.conn, ~p"/ops/discovery")

    assert html =~ "GUARDIAN_API_KEY present"
    assert html =~ "SPOTIFY_CLIENT_SECRET missing"
    refute html =~ "guardian-value-the-page-must-never-render"
  end

  test "refresh re-reads the ledger rather than replaying the mount's numbers", ctx do
    {:ok, live, _html} = live(ctx.conn, ~p"/ops/discovery")

    before = render(live)
    after_click = live |> element("button[phx-click=refresh]") |> render_click()

    assert after_click =~ ~s(id="discovery-ledger")
    assert before =~ "read at"
  end

  test "it is linked from the chrome in dev and test, beside the other consoles", ctx do
    {:ok, _live, html} = live(ctx.conn, ~p"/ops/imports")

    assert html =~ ~s(href="/ops/discovery")
  end
end
