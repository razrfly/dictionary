defmodule DevilsDictionaryWeb.LocalDevelopmentTest do
  @moduledoc """
  The development tools answer the owner's machine only (#250): a request
  through the tunnel is never shown a compile error, never stopped by the
  pending-migration check, and its page carries no reloader; the owner's own
  request gets all three, as on any development server. The endpoint reaches
  them only through `LocalDevelopment`. The published host is compiled
  without the debug pages (`PublicRoutingTest`), so no request there is
  shown a stack trace or the migration page's button.
  """
  use ExUnit.Case, async: true

  import Plug.Conn

  alias DevilsDictionaryWeb.LocalDevelopment

  @compile_error "== Compilation error in file lib/devils_dictionary_web/router.ex =="

  # The tools as the endpoint's, with a checkout that does not compile and a
  # migration pending.
  defp code_reloader,
    do: {Phoenix.CodeReloader, reloader: fn _endpoint, _opts -> {:error, @compile_error} end}

  defp check_repo_status do
    {Phoenix.Ecto.CheckRepoStatus,
     otp_app: :devils_dictionary,
     mock_migrations_fn: fn _repo, _dirs, _opts -> [{:down, 1, "pending"}] end}
  end

  defp request(headers \\ []) do
    headers
    |> Enum.reduce(Plug.Test.conn(:get, "/"), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> put_private(:phoenix_endpoint, DevilsDictionaryWeb.Endpoint)
  end

  defp proxied_requests do
    [
      request([{"x-forwarded-for", "203.0.113.7"}]),
      request([{"forwarded", "for=203.0.113.7"}]),
      request([{"x-forwarded-proto", "https"}]),
      %{request() | remote_ip: {192, 168, 1, 20}}
    ]
  end

  test "a request through the tunnel is never shown a compile error or the pending-migration check" do
    tools = LocalDevelopment.init(tools: [code_reloader(), check_repo_status()])

    # Untouched: not halted, nothing sent, nothing registered to send.
    for proxied <- proxied_requests() do
      assert LocalDevelopment.call(proxied, tools) == proxied
    end

    # The owner's own request: the compiler's output, and the check.
    conn = LocalDevelopment.call(request(), LocalDevelopment.init(tools: [code_reloader()]))
    assert conn.halted
    assert conn.status == 500
    assert conn.resp_body =~ "Compilation error in file"

    error =
      assert_raise Plug.Conn.WrapperError, fn ->
        LocalDevelopment.call(request(), LocalDevelopment.init(tools: [check_repo_status()]))
      end

    assert %Phoenix.Ecto.PendingMigrationError{} = error.reason
  end

  test "the endpoint's development tools are these, and a proxied request reaches none of them" do
    assert Enum.map(LocalDevelopment.init([]), &elem(&1, 0)) == [
             Phoenix.LiveReloader,
             Phoenix.CodeReloader,
             Phoenix.Ecto.CheckRepoStatus
           ]

    # Not one is called: the live reloader is not even loaded in the test
    # build, and no page gets its frame.
    for proxied <- proxied_requests() do
      assert LocalDevelopment.call(proxied, LocalDevelopment.init([])) == proxied
    end

    endpoint = File.read!(Path.expand("../../lib/devils_dictionary_web/endpoint.ex", __DIR__))
    assert endpoint =~ "plug DevilsDictionaryWeb.LocalDevelopment"

    for tool <- ~w(Phoenix.LiveReloader Phoenix.CodeReloader Phoenix.Ecto.CheckRepoStatus) do
      refute endpoint =~ "plug #{tool}", "the endpoint plugs #{tool} for every request"
    end
  end
end
