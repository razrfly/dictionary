defmodule DevilsDictionary.Claims.Catalog do
  @moduledoc """
  The predicate registry, as data.

  `priv/predicates/*.json`, read the way `priv/scopes/*.json` is. A new
  relationship type is a file entry plus its allowed endpoint pairs — no
  migration, and no code — which is what scorecard E1 measures now that it has
  stopped counting migrations.

  `core.json` holds the product's own predicates. Source-native lexical and
  semantic predicates get their own files, so WordNet's hypernym and Wikidata's
  P279 stay distinguishable rather than being flattened into a generic
  `related_to` — #72's requirement, and the reason the endpoint rules are
  enumerated per predicate rather than shared.
  """

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Registry.{ContentItem, Entity}

  @doc "Where the predicate files live, at compile time and from a release."
  def dir, do: Application.app_dir(:devils_dictionary, "priv/predicates")

  @doc "Every predicate definition, across every file, in file order."
  def predicates do
    dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(&read!/1)
  end

  @doc "Reads one predicate file."
  def read!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("predicates")
  end

  @doc """
  Upserts every predicate and its endpoint rules. Idempotent.

  Endpoint rules are added, never removed: withdrawing one would orphan the
  assertions relying on it, and the composite foreign key would refuse the
  delete anyway. Narrowing a predicate is a deliberate migration, not a seed.
  """
  def seed! do
    Map.new(predicates(), fn definition ->
      {:ok, predicate} = upsert(definition)

      for endpoint <- definition["endpoints"] || [],
          [subject, object] = endpoint,
          {subject_kind, subject_subkind} <- expand(subject),
          {object_kind, object_subkind} <- expand(object) do
        Claims.allow_endpoints(predicate, subject_kind, object_kind,
          subject_subkind: subject_subkind,
          object_subkind: object_subkind
        )
      end

      {predicate.key, predicate}
    end)
  end

  defp upsert(definition) do
    attrs =
      Map.take(definition, ~w(key forward_label reverse_label description
                              is_symmetric is_transitive cycles_allowed source_native))

    case Claims.predicate(definition["key"]) do
      nil ->
        Claims.create_predicate(attrs)

      existing ->
        existing
        |> DevilsDictionary.Claims.Predicate.changeset(attrs)
        |> DevilsDictionary.Repo.update()
    end
  end

  # "content/definition" -> [{"content", "definition"}]; "lexeme/-" -> [{"lexeme", "-"}].
  #
  # `*` expands over the kind's subkinds. An imported Wikidata item's kind is not
  # known before its statements are read, so `entity/*` on the hierarchy
  # predicates is the honest statement of the rule; writing out a hundred pairs
  # by hand would be a worse record of the same thing. Every pair still becomes
  # its own `predicate_endpoint_rules` row, so the composite foreign key checks
  # exactly what it checked before.
  defp expand(endpoint) do
    {kind, subkind} =
      case String.split(endpoint, "/", parts: 2) do
        [kind, subkind] -> {kind, subkind}
        [kind] -> {kind, "-"}
      end

    for sub <- subkinds(kind, subkind), do: {kind, sub}
  end

  defp subkinds("entity", "*"), do: Enum.map(Entity.kinds(), &to_string/1)
  defp subkinds("content", "*"), do: Enum.map(ContentItem.kinds(), &to_string/1)
  defp subkinds(_kind, "*"), do: ["-"]
  defp subkinds(_kind, subkind), do: [subkind]
end
