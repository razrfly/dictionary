defmodule Mix.Tasks.Dd.Verify.Rebuild do
  use Mix.Task
  @shortdoc "Compare two new-model rebuilds by exact semantic multiset fingerprints"
  @moduledoc "Run `mix dd.verify.rebuild --baseline DATABASE`. Neither database is modified."
  @requirements ["app.start"]
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: [baseline: :string, output: :string])
    if invalid != [] or is_nil(opts[:baseline]), do: Mix.raise("--baseline DATABASE is required")
    current = DevilsDictionary.Repo.config()[:database]
    if current == opts[:baseline], do: Mix.raise("baseline must be a different database")
    baseline = DevilsDictionary.Health.RebuildSnapshot.capture(opts[:baseline])
    rebuilt = DevilsDictionary.Health.RebuildSnapshot.capture(current)
    differences = Map.keys(baseline) |> Enum.filter(&(baseline[&1] != rebuilt[&1]))

    result = %{
      baseline_database: opts[:baseline],
      rebuilt_database: current,
      baseline: baseline,
      rebuilt: rebuilt,
      differences: differences,
      identical: differences == []
    }

    json = Jason.encode!(result, pretty: true)
    if opts[:output], do: File.write!(opts[:output], json <> "\n")
    Mix.shell().info(json)

    if differences != [],
      do: Mix.raise("semantic rebuild mismatch: #{Enum.join(differences, ", ")}")
  end
end
