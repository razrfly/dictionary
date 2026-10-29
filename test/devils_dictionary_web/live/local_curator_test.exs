defmodule DevilsDictionaryWeb.LocalCuratorTest do
  use DevilsDictionaryWeb.ConnCase, async: false
  import DevilsDictionary.RefreshFixtures
  alias DevilsDictionary.Curation.{CompositionPublication, CompositionVersion, Receipt}
  alias DevilsDictionary.Repo

  setup do
    keys = [dev_routes: true, published_host: "wordhoard.eu.ngrok.io"]
    previous = Map.new(keys, fn {k, _} -> {k, Application.fetch_env(:devils_dictionary, k)} end)
    Enum.each(keys, fn {k, v} -> Application.put_env(:devils_dictionary, k, v) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {k, {:ok, v}} -> Application.put_env(:devils_dictionary, k, v)
        {k, :error} -> Application.delete_env(:devils_dictionary, k)
      end)
    end)

    world = love_world!()
    world = Map.put(world, :composition, provision!(world))
    world
  end

  defp local(conn) do
    %{conn | host: "localhost", remote_ip: {127, 0, 0, 1}}
    |> put_private(:live_view_connect_info, %{
      x_headers: [],
      peer_data: %{address: {127, 0, 0, 1}}
    })
  end

  test "localhost owner enters connected editor without a website login", w do
    conn = w.conn |> local() |> get("/ops/curation/on/love")
    assert html_response(conn, 200) =~ "curation"
    assert get_session(conn, :local_curator_user_id) == w.reviewer.user.id
    assert get_session(conn, :user_token) == nil
    assert {:ok, view, _} = live(conn)
    assert has_element?(view, "#curation-form")
  end

  test "ngrok headers cannot acquire local owner even with loopback peer or copied local session",
       w do
    conn = w.conn |> local() |> get("/ops/curation/on/love")

    conn =
      conn
      |> recycle()
      |> put_req_header("x-forwarded-for", "203.0.113.7")
      |> get("/ops/curation/on/love")

    assert redirected_to(conn) == "/users/log-in"
    assert get_session(conn, :local_curator_user_id) == nil
  end

  test "connected remote socket cannot reuse locally issued owner boot session", w do
    conn =
      w.conn
      |> local()
      |> get("/ops/curation/on/love")
      |> put_private(:live_view_connect_info, %{
        x_headers: [{"x-forwarded-for", "203.0.113.7"}],
        peer_data: %{address: {127, 0, 0, 1}}
      })

    assert {:error, {:redirect, %{to: "/"}}} = live(conn)
  end

  test "non-loopback and hostile Host do not get owner identity", w do
    remote = %{w.conn | host: "localhost", remote_ip: {192, 168, 1, 20}}
    assert remote |> get("/ops/curation/on/love") |> redirected_to() == "/users/log-in"
    hostile = %{w.conn | host: "attacker.example", remote_ip: {127, 0, 0, 1}}
    assert hostile |> get("/ops/curation/on/love") |> redirected_to() == "/users/log-in"
  end

  test "owner revocation takes effect before local access", w do
    w.reviewer.user |> Ecto.Changeset.change(reviewer: false) |> Repo.update!()
    assert w.conn |> local() |> get("/ops/curation/on/love") |> redirected_to() == "/users/log-in"
  end

  test "local owner capability is curation-only and no public receipt claims a human review for an agent",
       w do
    conn = w.conn |> local() |> get("/ops/curation/on/love")
    conn = conn |> recycle() |> get("/on/love")
    assert get_session(conn, :local_curator_user_id) == nil
    refute Repo.exists?(CompositionPublication)
    refute Repo.exists?(CompositionVersion)
    assert {:error, :not_found} = Receipt.read("love", 1)
  end

  test "password-free local identity does not disable CSRF protection", w do
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      w.conn
      |> local()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/users/log-in", %{"action" => "publish"})
    end
  end

  test "local curation marker grants no identity to other reviewer views", w do
    socket = %Phoenix.LiveView.Socket{
      view: DevilsDictionaryWeb.UserLive.Settings,
      assigns: %{__changed__: %{}, current_scope: nil}
    }

    socket =
      DevilsDictionaryWeb.LocalCurator.mount(
        socket,
        %{"local_curator_user_id" => w.reviewer.user.id}
      )

    assert socket.assigns.current_scope == nil
  end

  test "anonymous non-curation requests do not dirty the session", w do
    conn =
      w.conn
      |> init_test_session(%{})
      |> assign(:current_scope, nil)
      |> put_private(:plug_session_info, :fetch)

    conn = DevilsDictionaryWeb.LocalCurator.call(conn, [])
    assert conn.private.plug_session_info == :fetch
    assert get_session(conn, :local_curator_user_id) == nil
  end
end
