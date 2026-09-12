defmodule Mix.Tasks.Dd.Artsy.Withdraw do
  @shortdoc "Removes Artsy-retained payloads and disables the provider"

  @moduledoc """
  Executes the tested provider shutdown path while preserving independently
  licensed Wikidata identities and editorial work.

      mix dd.artsy.withdraw --reason "API terms ended on 2026-12-31"
  """

  use Mix.Task

  alias DevilsDictionary.Artworks

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, rest, invalid} = OptionParser.parse(args, strict: [reason: :string])
    reason = opts[:reason] && String.trim(opts[:reason])

    if rest != [] or invalid != [] or reason in [nil, ""] do
      Mix.raise("invalid arguments; --reason is required (run `mix help dd.artsy.withdraw`)")
    end

    case Artworks.withdraw_artsy(reason) do
      {:ok, summary} -> Mix.shell().info("Artsy withdrawal complete: " <> inspect(summary))
      {:error, error} -> Mix.raise("Artsy withdrawal failed: #{inspect(error)}")
    end
  end
end
