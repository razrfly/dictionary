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

    # The merged production configuration, as a release reads it, not a
    # line in a file: a later `true` in prod.exs would be caught here.
    merged = @root |> Path.join("config.exs") |> Config.Reader.read!(env: :prod, target: :host)
    assert get_in(merged, [:devils_dictionary, :public_routing]) == false

    secret = {"DD_SECRET_KEY_BASE", String.duplicate("s", 64)}
    published = [{"DD_PUBLISHED_HOST", "wordhoard.test"}, {"DD_PUBLIC_ROUTING", nil}, secret]

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

    assert runtime(:dev, [
             {"DD_PUBLISHED_HOST", "wordhoard.test"},
             {"DD_PUBLIC_ROUTING", "off"},
             secret
           ])[:public_routing] == false

    # The published host signs with its own secret, never the committed
    # development one: without it, or with a short one, it does not boot.
    assert dev[DevilsDictionaryWeb.Endpoint][:secret_key_base] == String.duplicate("s", 64)

    assert_raise RuntimeError, ~r/needs DD_SECRET_KEY_BASE/, fn ->
      runtime(:dev, [{"DD_PUBLISHED_HOST", "wordhoard.test"}, {"DD_SECRET_KEY_BASE", nil}])
    end

    assert_raise RuntimeError, ~r/at least 64 bytes/, fn ->
      runtime(:dev, [{"DD_PUBLISHED_HOST", "wordhoard.test"}, {"DD_SECRET_KEY_BASE", "short"}])
    end

    # Exactly on or off: a rollback typed another way raises at boot rather
    # than leave public routing on in silence.
    for typed <- ["OFF", "false", "0", "no", "disabled", ""] do
      assert_raise RuntimeError, ~r/DD_PUBLIC_ROUTING must be on or off/, fn ->
        runtime(:dev, [
          {"DD_PUBLISHED_HOST", "wordhoard.test"},
          {"DD_PUBLIC_ROUTING", typed},
          secret
        ])
      end
    end

    plain = runtime(:dev, [{"DD_PUBLISHED_HOST", nil}])
    refute Keyword.has_key?(plain, :public_routing)
    refute Keyword.has_key?(plain, :published_host)
    refute get_in(plain, [DevilsDictionaryWeb.Endpoint, :secret_key_base])
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
      # Not linked at all: neither its address nor its exact identity (#237 D2).
      assert Links.path(draft.entity.object_id, "Arouet") == nil
    end)

    assert ctx.conn |> get("/people/fran%C3%A7ois") |> html_response(200)
  end

  describe "through a proxy (the tunnel)" do
    defp proxied(conn), do: put_req_header(conn, "x-forwarded-for", "203.0.113.7")

    test "on the published host, the operator surfaces answer 404; the owner still reaches them locally",
         ctx do
      with_env(:published_host, "wordhoard.test", fn ->
        for path <- ~w(/dev/mailbox /dev/mailbox/json /dev/dashboard /kit /ops/imports /ops/health
                       /s/anything /health /admin/imports) do
          conn = ctx.conn |> proxied() |> get(path)
          assert conn.status == 404, "#{path} answered #{conn.status} through the proxy"
        end

        # The reader is served through the proxy as usual.
        refute (ctx.conn |> proxied() |> get("/robots.txt")).status in [403, 503]

        # On the machine itself, nothing is hidden.
        assert ctx.conn |> get("/ops/health") |> html_response(200)

        # And the login page does not send a visitor to the mailbox.
        refute ctx.conn |> get("/users/log-in") |> html_response(200) =~ "local-mail-notice"
      end)
    end

    test "a server that reads drafts and is not the published host refuses every proxied request",
         ctx do
      draft =
        subject!("Candide", "people",
          kind: :person,
          description: "a draft",
          path: "/people/candide"
        )

      assert DevilsDictionaryWeb.ReadingMode.configured?()

      conn = ctx.conn |> proxied() |> get("/people/candide")
      assert conn.status == 503
      assert conn.resp_body =~ "not the published host"
      refute conn.resp_body =~ draft.entity.preferred_label

      for header <- ~w(forwarded x-forwarded-host x-forwarded-proto) do
        assert (ctx.conn |> put_req_header(header, "x") |> get("/people/candide")).status == 503
      end

      # From another machine with no proxy headers: refused too.
      assert (%{ctx.conn | remote_ip: {192, 168, 1, 20}} |> get("/people/candide")).status == 503

      # Locally, the owner reads the draft.
      assert ctx.conn |> get("/people/candide") |> html_response(200)
    end

    test "the LiveView socket, which no plug reaches, refuses a proxied connection where the plug would" do
      local = %{x_headers: [], peer_data: %{address: {127, 0, 0, 1}}}

      for proxied <- [
            %{local | x_headers: [{"x-forwarded-for", "203.0.113.7"}]},
            %{local | x_headers: [{"X-Forwarded-Proto", "https"}]},
            %{local | x_headers: [{"x-forwarded-host", "wordhoard.test"}]},
            %{local | peer_data: %{address: {192, 168, 1, 20}}},
            %{x_headers: []}
          ] do
        # A server that reads drafts and is not the published host: refused.
        assert DevilsDictionaryWeb.ReadingMode.configured?()
        assert :error = DevilsDictionaryWeb.LiveSocket.connect(%{}, %Phoenix.Socket{}, proxied)

        # The published host reads publicly: the socket connects.
        with_env(:published_host, "wordhoard.test", fn ->
          assert {:ok, _} =
                   DevilsDictionaryWeb.LiveSocket.connect(%{}, %Phoenix.Socket{}, proxied)
        end)
      end

      # The owner's own machine connects either way.
      assert {:ok, _} = DevilsDictionaryWeb.LiveSocket.connect(%{}, %Phoenix.Socket{}, local)
    end

    test "on the published host, a reader page cannot live-navigate to an operator page, and a proxied socket is not mounted there",
         ctx do
      with_env(:published_host, "wordhoard.test", fn ->
        # Another live session: the navigation needs a request, which the
        # plug answers 404 through the proxy. (A refused navigation ends the
        # view, so each path starts from the reader page again.)
        for path <- ~w(/ops/health /ops/imports /ops/discovery /kit) do
          {:ok, view, _html} = ctx.conn |> proxied() |> live("/")
          assert {:error, {:redirect, %{to: to}}} = live_redirect(view, to: path)
          assert URI.parse(to).path == path
          assert (ctx.conn |> proxied() |> get(path)).status == 404
        end

        # A socket that reaches an operator LiveView anyway is sent away
        # before it mounts; the owner's own is mounted.
        socket = fn info ->
          %Phoenix.LiveView.Socket{private: %{connect_info: info, lifecycle: nil}}
        end

        proxied_info = %{
          x_headers: [{"x-forwarded-for", "203.0.113.7"}],
          peer_data: %{address: {127, 0, 0, 1}}
        }

        local_info = %{x_headers: [], peer_data: %{address: {127, 0, 0, 1}}}

        assert {:halt, %{redirected: {:redirect, %{to: "/"}}}} =
                 DevilsDictionaryWeb.ProxyGuard.on_mount(
                   :operator,
                   %{},
                   %{},
                   socket.(proxied_info)
                 )

        assert {:cont, _} =
                 DevilsDictionaryWeb.ProxyGuard.on_mount(:operator, %{}, %{}, socket.(local_info))

        # Locally, the operator pages mount as before.
        assert {:ok, _view, _html} = live(ctx.conn, "/ops/health")
      end)

      # Not the published host: the hook leaves the operator pages alone.
      assert {:ok, _view, _html} = live(ctx.conn, "/ops/health")
    end
  end
end
