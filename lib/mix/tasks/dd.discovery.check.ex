defmodule Mix.Tasks.Dd.Discovery.Check do
  use Mix.Task
  @shortdoc "Fail a demo/deployment preflight when CineGraph configuration is missing"
  @moduledoc """
  Run `mix dd.discovery.check` in the same environment as the server before a
  discovery demo or deployment. This checks configuration only; live verification
  of the credential and film discovery remains a separate gate. Never prints keys.
  """

  @impl true
  def run([]) do
    Mix.Task.run("app.config")
    config = Application.get_env(:devils_dictionary, :cinegraph, [])

    cond do
      config[:enabled] == false ->
        Mix.raise("CineGraph discovery is disabled")

      not present?(config[:api_key]) ->
        Mix.raise("CINEGRAPH_API_KEY is missing or blank; discovery is not ready")

      not valid_endpoint?(config[:endpoint]) ->
        Mix.raise(
          "CINEGRAPH_GRAPHQL_URL must be an HTTP(S) endpoint without credentials or query parameters"
        )

      true ->
        Mix.shell().info(
          "CineGraph configuration ready; credential validity and live discovery still require verification"
        )
    end
  end

  def run(_), do: Mix.raise("usage: mix dd.discovery.check")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_endpoint?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp valid_endpoint?(_), do: false
end
