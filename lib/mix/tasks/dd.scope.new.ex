defmodule Mix.Tasks.Dd.Scope.New do
  @shortdoc "Create a scope row from its slug, name and rules"

  @moduledoc """
  Writes `priv/scopes/<slug>.json` and the `scopes` row it describes. This is
  the generic entry point that makes scorecard row **E2** ("a new scope is
  data") true: the Nth scope costs a file and a task run, not an edit to
  `Sources.Catalog.scopes/0`.

      mix dd.scope.new emotions --name Emotions \\
        --rules '{"wordnet_roots":["oewn-00026390-n"]}'

  With no options it reads the file that is already there, which is how a fresh
  clone or a release seeds a scope someone else added:

      mix dd.scope.new emotions

  Then `mix dd.scope.build emotions` applies the rules. The three rules
  `Absorb.ScopeBuilder` knows are all optional keys of the same map:

    * `wordnet_roots` — a list of synset ids; the hyponym closure of each
    * `wiktionary_category_root` / `wiktionary_categories` — the topical
      categories, pinned by `mix dd.scope.categories`
    * `wikidata_root` — a QID whose taxon descendants join the scope, and the
      root of the browse page's taxonomy rail

  A rule whose key is absent is skipped with a reason rather than contributing a
  silent zero, so a non-taxonomic scope needs only `wordnet_roots`.

  Options:

    * `--name` — the display name; defaults to the file's, then to the slug
    * `--rules` — the rules map as JSON; defaults to the file's, then to `{}`
  """

  use Mix.Task

  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Sources.Catalog

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, [slug], _} = OptionParser.parse(args, strict: [name: :string, rules: :string])

    path = Path.join(Catalog.scopes_dir(), "#{slug}.json")
    on_disk = if File.exists?(path), do: Catalog.read_scope!(path), else: %{}

    rules = if opts[:rules], do: decode_rules(opts[:rules]), else: Map.get(on_disk, :rules, %{})
    name = opts[:name] || Map.get(on_disk, :name) || String.capitalize(slug)

    attrs = %{slug: slug, name: name, rules: rules}
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(attrs, pretty: true) <> "\n")

    {:ok, scope} = Lexicon.create_scope(attrs)

    Mix.shell().info("scope #{scope.slug} — #{scope.name}  (#{path})")

    if rules == %{} do
      Mix.shell().error("  no rules: mix dd.scope.build #{slug} will match nothing")
    else
      Enum.each(rules, fn {key, value} ->
        Mix.shell().info("  #{String.pad_trailing(key, 26)} #{inspect(value)}")
      end)
    end

    Mix.shell().info("\nnext: mix dd.scope.build #{slug}")
  end

  defp decode_rules(nil), do: %{}

  defp decode_rules(json) do
    case Jason.decode(json) do
      {:ok, rules} when is_map(rules) ->
        rules

      {:ok, other} ->
        Mix.raise("--rules must be a JSON object, got #{inspect(other)}")

      {:error, error} ->
        Mix.raise("--rules is not valid JSON: #{Exception.message(error)}")
    end
  end
end
