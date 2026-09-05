defmodule Mix.Tasks.Dd.Scope.Categories do
  @shortdoc "Walk a Wiktionary category tree and freeze it into scopes.rules"

  @moduledoc """
  Resolves a scope's `wiktionary_category_root` into the flat list of category
  names the `wiktionary_category` rule matches against.

  The Kaikki dump carries each entry's categories as flat strings ("en:Corvids")
  with no hierarchy, so the tree has to come from the Wiktionary API. We walk it
  once and freeze the result into `scopes.rules`, which keeps `mix dd.scope.build`
  offline and reproducible. Re-run this only if Wiktionary reorganises the tree.

      mix dd.scope.categories animals
      mix dd.scope.categories animals --depth 4

  Options:

    * `--depth` — how deep to recurse (default 4)
    * `--dry-run` — print the list, write nothing
  """

  use Mix.Task

  alias DevilsDictionary.Lexicon

  @api "https://en.wiktionary.org/w/api.php"
  @user_agent "wordhoard/0.1 (https://github.com/razrfly/dictionary)"
  @rate_limit_ms 200

  # Subtrees that are about animals without being animals: body parts, ethics,
  # veterinary practice, and the thesaurus mirror.
  # Subtrees that are about animals without being animals: body parts and
  # products, equestrian equipment and sport, ethics, veterinary practice,
  # a toy franchise, and the thesaurus mirror.
  @denylist [
    "en:Animal body parts",
    "en:Animal riding",
    "en:Bestiality",
    "en:Eggs",
    "en:Equestrianism",
    "en:Farriery",
    "en:Feathers",
    "en:Horse colors",
    "en:Horse racing",
    "en:Horse tack",
    "en:My Little Pony",
    "en:Veterinary medicine"
  ]

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, [slug], _} =
      OptionParser.parse(args, strict: [depth: :integer, dry_run: :boolean])

    depth = opts[:depth] || 4
    scope = Lexicon.get_scope_by_slug!(slug)

    root =
      scope.rules["wiktionary_category_root"] || raise "scope has no wiktionary_category_root"

    Mix.shell().info("walking Category:#{root} to depth #{depth}…")

    categories =
      [root]
      |> walk(depth, MapSet.new([root]))
      |> Enum.sort()

    Mix.shell().info("#{length(categories)} categories (#{length(@denylist)} subtrees skipped)")
    Enum.each(Enum.take(categories, 15), &Mix.shell().info("  #{&1}"))
    if length(categories) > 15, do: Mix.shell().info("  … #{length(categories) - 15} more")

    if opts[:dry_run] do
      Mix.shell().info("--dry-run: nothing written")
    else
      rules = Map.put(scope.rules, "wiktionary_categories", categories)
      Lexicon.update_scope(scope, %{rules: rules})
      Mix.shell().info("wrote #{length(categories)} categories into scopes.rules")
    end

    categories
  end

  # Breadth-first, one level at a time, so the depth limit is exact.
  defp walk([], _depth, seen), do: MapSet.to_list(seen)
  defp walk(_frontier, 0, seen), do: MapSet.to_list(seen)

  defp walk(frontier, depth, seen) do
    next =
      frontier
      |> Enum.flat_map(&subcategories/1)
      |> Enum.reject(fn category ->
        category in @denylist or String.starts_with?(category, "Thesaurus:") or
          MapSet.member?(seen, category)
      end)
      |> Enum.uniq()

    walk(next, depth - 1, Enum.into(next, seen))
  end

  defp subcategories(category) do
    Process.sleep(@rate_limit_ms)

    params = [
      action: "query",
      list: "categorymembers",
      cmtitle: "Category:" <> category,
      cmtype: "subcat",
      cmlimit: 500,
      format: "json"
    ]

    case Req.get(@api, params: params, headers: [{"user-agent", @user_agent}], retry: :transient) do
      {:ok, %{status: 200, body: %{"query" => %{"categorymembers" => members}}}} ->
        Enum.map(members, &String.replace_prefix(&1["title"], "Category:", ""))

      other ->
        Mix.shell().error("  ! #{category}: #{inspect(other |> elem(0))}")
        []
    end
  end
end
