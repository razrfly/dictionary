defmodule DevilsDictionary.DemoInertTest do
  @moduledoc """
  Fake-data mode is off unless something turns it on (#71 §9, U3).

  Its own file, and `async: false`, because turning the flag off is a change to
  application env — global state every other test shares. The point of the mode
  is that it can never reach a reader, so this is the test the mode exists to
  pass.
  """

  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Demo
  alias DevilsDictionary.Fixtures

  setup ctx do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    Map.merge(ctx, %{sources: sources, animals: scopes["animals"]})
  end

  defp with_demo_off(fun) do
    previous = Application.get_env(:devils_dictionary, :demo_mode)
    Application.put_env(:devils_dictionary, :demo_mode, false)

    try do
      fun.()
    after
      Application.put_env(:devils_dictionary, :demo_mode, previous)
    end
  end

  test "with the flag off, `?demo=1` is a parameter nothing reads", ctx do
    oyster = word!(ctx, "oyster", ~w(bierce))
    entry!(ctx, oyster, "bierce", body: "A slimy, gobby shellfish.")

    with_demo_off(fn ->
      refute Demo.enabled?()
      refute Demo.on?(%{"demo" => "1"})

      {:ok, _live, html} = live(ctx.conn, ~p"/define/oyster?demo=1")

      refute html =~ ~s(id="demo-banner")
      refute html =~ ~s(id="card-sample-webster1913")
      refute html =~ ~s(id="demo-evidence")
      refute html =~ "SAMPLE"
      refute html =~ "invented for layout"

      # And the real page is untouched: the parameter is inert, not fatal.
      assert html =~ ~s(id="card-bierce")
    end)
  end

  test "with the flag off, nothing on the page carries the parameter onward", ctx do
    oyster = word!(ctx, "oyster", ~w(wiktionary))
    relation!(ctx, oyster, :derived, word!(ctx, "oyster bed", ~w(wiktionary)))

    with_demo_off(fn ->
      {:ok, _live, html} = live(ctx.conn, ~p"/define/oyster?demo=1")

      refute html =~ "demo=1"
    end)
  end

  test "production config carries no demo_mode key, and neither does runtime" do
    # Read back rather than asserted. `config/test.exs` sets the flag, so a
    # test that only asked `Application.get_env` would be asking itself; this
    # reads what production will actually load. Set the key in prod and this
    # test goes red, which is what makes the claim in `Demo`'s moduledoc a
    # claim about the repository rather than about the author's intentions.
    prod = Config.Reader.read!("config/prod.exs", env: :prod)

    refute Keyword.has_key?(Keyword.get(prod, :devils_dictionary, []), :demo_mode)
    refute File.read!("config/runtime.exs") =~ "demo_mode"

    # And it is genuinely on where it is meant to be, or the mode is untested.
    assert File.read!("config/dev.exs") =~ "demo_mode: true"
    assert File.read!("config/test.exs") =~ "demo_mode: true"
  end
end
