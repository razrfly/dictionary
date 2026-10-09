defmodule DevilsDictionaryWeb.PublicRoutingTest do
  @moduledoc """
  The launch switch and the published host (#237 C3, C7; D2, D5):

    * production's configuration pins the switch off, and only the published
      host's development block in `config/runtime.exs` turns it on — read
      back from the configuration files themselves;
    * **off**, every family route answers 404 to the public — a published
      page, its alias, its tombstone — and public links fall back to the
      exact-identity route, while internal mode is unaffected and nothing in
      the ledger changes; **on again**, every answer is what it was;
    * nothing in a request turns it on;
    * the published host reads publicly, whatever development configures:
      a draft is 404 there, and only an authenticated reviewer or contributor
      reads internally.

  Voltaire and Arouet are CI fixtures in this test's sandbox.
  """
  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.OnFixtures
  import DevilsDictionary.RoutingFixtures, only: [human!: 0, importer!: 0]

  alias DevilsDictionary.{CurationFixtures, Fixtures, Repo}

  alias DevilsDictionary.Routing.{
    Ledger,
    Links,
    PagePublication,
    PublicPath,
    PublicRouting,
    RouteChange
  }

  alias DevilsDictionaryWeb.ReadingMode

  @root Path.expand("../../config", __DIR__)

  setup %{conn: conn} do
    Fixtures.seed_catalog!()
    %{conn: conn, human: human!(), importer: importer!()}
  end

  defp switch(on?, fun), do: with_env(:public_routing, on?, fun)

  defp with_env(key, value, fun) do
    previous = Application.get_env(:devils_dictionary, key)
    Application.put_env(:devils_dictionary, key, value)

    try do
      fun.()
    after
      if is_nil(previous),
        do: Application.delete_env(:devils_dictionary, key),
        else: Application.put_env(:devils_dictionary, key, previous)
    end
  end

  defp with_system_env(vars, fun) do
    previous = Map.new(vars, fn {name, _} -> {name, System.get_env(name)} end)

    Enum.each(vars, fn {name, value} ->
      if value, do: System.put_env(name, value), else: System.delete_env(name)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)
    end
  end

  defp runtime(env, vars) do
    with_system_env(vars, fn ->
      @root
      |> Path.join("runtime.exs")
      |> Config.Reader.read!(env: env)
      |> Keyword.get(:devils_dictionary, [])
    end)
  end

  test "production pins the switch off; only the published host's development block turns it on" do
    for file <- ~w(config.exs prod.exs) do
      assert @root |> Path.join(file) |> File.read!() =~
               "config :devils_dictionary, :public_routing, false",
             "#{file} must pin public routing off"
    end

    published = [{"DD_PUBLISHED_HOST", "wordhoard.test"}, {"DD_PUBLIC_ROUTING", nil}]

    # Production never reads the published host's variables.
    prod =
      runtime(
        :prod,
        published ++
          [
            {"DATABASE_URL", "ecto://u:p@localhost/db"},
            {"SECRET_KEY_BASE", String.duplicate("k", 64)}
          ]
      )

    refute Keyword.has_key?(prod, :public_routing)
    refute Keyword.has_key?(prod, :published_host)

    # Development: on for the published host, off again by the rollback
    # switch, and absent without a published host.
    dev = runtime(:dev, published)
    assert dev[:published_host] == "wordhoard.test"
    assert dev[:public_routing] == true

    assert runtime(:dev, [{"DD_PUBLISHED_HOST", "wordhoard.test"}, {"DD_PUBLIC_ROUTING", "off"}])[
             :public_routing
           ] == false

    plain = runtime(:dev, [{"DD_PUBLISHED_HOST", nil}])
    refute Keyword.has_key?(plain, :public_routing)
    refute Keyword.has_key?(plain, :published_host)
  end

  # A published page with an alias (after a move) and a published page whose
  # address was retired.
  defp world!(ctx) do
    voltaire =
      subject!("Voltaire", "people",
        kind: :person,
        description: "French writer",
        path: "/people/arouet",
        published: true,
        actor: ctx.human
      )

    {:ok, _} =
      Ledger.move(voltaire.page.id, "/people/voltaire", actor_id: ctx.human.id, reason: "fixture")

    retired =
      subject!("Candide", "works",
        kind: :work,
        description: "1759 novella",
        path: "/works/candide",
        published: true,
        actor: ctx.human
      )

    {:ok, _} = Ledger.retire(retired.page.id, actor_id: ctx.human.id, reason: "fixture")
    %{voltaire: voltaire, retired: retired}
  end

  defp answers(conn) do
    for path <- ["/people/voltaire", "/people/arouet", "/works/candide"] do
      response = get(conn, path)
      {path, response.status, Plug.Conn.get_resp_header(response, "location")}
    end
  end

  defp ledger,
    do: for(s <- [PublicPath, RouteChange, PagePublication], do: Repo.aggregate(s, :count))

  test "off: the family routes are 404 publicly and links fall back; internal unaffected; on again, the same",
       ctx do
    world = world!(ctx)

    reading(false, fn ->
      on = answers(ctx.conn)

      assert on == [
               {"/people/voltaire", 200, []},
               {"/people/arouet", 301, ["/people/voltaire"]},
               {"/works/candide", 410, []}
             ]

      assert Links.path(world.voltaire.entity.object_id, "Voltaire") == "/people/voltaire"
      before = ledger()

      off =
        switch(false, fn ->
          refute PublicRouting.enabled?()
          answers = answers(ctx.conn)

          # The exact-identity route still reads, and links go there.
          assert ctx.conn
                 |> get("/entities/#{world.voltaire.entity.object_id}/voltaire")
                 |> html_response(200)

          assert Links.path(world.voltaire.entity.object_id, "Voltaire") ==
                   "/entities/#{world.voltaire.entity.object_id}/voltaire"

          # Internal mode is unaffected.
          reading(true, fn ->
            assert ctx.conn |> get("/people/voltaire") |> html_response(200)
          end)

          answers
        end)

      assert off == [
               {"/people/voltaire", 404, []},
               {"/people/arouet", 404, []},
               {"/works/candide", 404, []}
             ]

      assert ledger() == before
      assert answers(ctx.conn) == on
    end)
  end

  test "nothing in a request turns it on", ctx do
    world!(ctx)

    reading(false, fn ->
      switch(false, fn ->
        conn =
          ctx.conn
          |> put_req_header("x-public-routing", "on")
          |> put_req_cookie("public_routing", "true")

        for query <- ["", "?public_routing=true", "?public_routing=1&internal_reading=true"] do
          assert conn |> get("/people/voltaire" <> query) |> html_response(404), query
        end

        refute PublicRouting.enabled?()
      end)
    end)
  end

  test "the published host reads publicly: a draft is 404 there, and only a reviewer reads internally",
       ctx do
    draft =
      subject!("Arouet", "people",
        kind: :person,
        description: "a draft",
        path: "/people/françois"
      )

    # Development configures internal reading; the published host refuses it.
    assert Application.get_env(:devils_dictionary, :internal_reading) == true
    assert ReadingMode.configured?()

    with_env(:published_host, "wordhoard.test", fn ->
      refute ReadingMode.configured?()
      assert ReadingMode.mode(nil) == :public
      assert ReadingMode.mode(CurationFixtures.account([])) == :public
      assert ReadingMode.mode(CurationFixtures.account([:reviewer])) == :internal
      assert PublicRouting.origin() == "https://wordhoard.test"

      assert ctx.conn |> get("/people/fran%C3%A7ois") |> html_response(404)
      refute Links.path(draft.entity.object_id, "Arouet") =~ "/people/"
    end)

    assert ctx.conn |> get("/people/fran%C3%A7ois") |> html_response(200)
  end
end
