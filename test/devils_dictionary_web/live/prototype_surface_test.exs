defmodule DevilsDictionaryWeb.PrototypeSurfaceTest do
  @moduledoc """
  #77 §1: the product has no privileged subject.

  The navigation used to read `Animals · Health · Imports` — one test population
  and two developer consoles standing in for the whole site's structure. These
  are the regressions that would let it back: a population named in the chrome,
  a public page linking an ops surface, or a retired path going nowhere.
  """

  use DevilsDictionaryWeb.ConnCase, async: true

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Fixtures

  setup do
    %{sources: sources, scopes: scopes} = Fixtures.seed_catalog!()
    %{sources: sources, animals: scopes["animals"]}
  end

  describe "the chrome" do
    test "names no population and links no ops surface", ctx do
      {:ok, _live, html} = live(ctx.conn, ~p"/")

      for scope <- ~w(Animals Culture Emotions) do
        refute html =~ scope
      end

      refute html =~ ~s(href="/s/)
      refute html =~ ~s(href="/admin/imports")
    end

    # The footer's Sources column is read from the `sources` table, which is the
    # asymmetry #77 objected to: sources were enumerated, populations were one
    # hardcoded link. Enumerating populations too would have been the wrong fix.
    test "the footer still names every source", ctx do
      {:ok, _live, html} = live(ctx.conn, ~p"/")

      for source <- ctx.sources |> Map.values() do
        assert html =~ ~s(href="/sources/#{source.slug}")
      end
    end
  end

  describe "the retired paths" do
    test "redirect to /ops, temporarily, keeping their query string", ctx do
      for {from, to} <- [
            {"/s/animals", "/ops/scopes/animals"},
            {"/s/animals?missing=bierce&page=2", "/ops/scopes/animals?missing=bierce&page=2"},
            {"/health", "/ops/health"},
            {"/health?scope=emotions", "/ops/health?scope=emotions"},
            {"/admin/imports", "/ops/imports"},
            {"/admin/imports?scope=culture", "/ops/imports?scope=culture"}
          ] do
        conn = get(ctx.conn, from)

        # 302, not 301: `/ops` is a first guess at where a diagnostic surface
        # belongs, and a browser caches a permanent redirect near-forever.
        assert conn.status == 302
        assert redirected_to(conn, 302) == to
      end
    end

    test "and the pages they point at are live", ctx do
      word!(ctx, "oyster", ~w(bierce))

      assert {:ok, _live, _html} = live(ctx.conn, ~p"/ops/scopes/animals")
      assert {:ok, _live, _html} = live(ctx.conn, ~p"/ops/health")
      assert {:ok, _live, _html} = live(ctx.conn, ~p"/ops/imports")
    end
  end
end
