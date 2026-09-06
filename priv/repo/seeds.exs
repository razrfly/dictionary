# The source registry (issue #69 §2), the Animals test scope (§3), and the
# dead authors of the layers as people.
#
# The definitions live in DevilsDictionary.Sources.Catalog, not here, because
# seeds do not run in :test — tests upsert the same catalog themselves.
# Idempotent: re-running only refreshes the pinned config.
#
#     mix run priv/repo/seeds.exs

%{sources: sources, scopes: scopes, people: people} = DevilsDictionary.Sources.Catalog.seed!()

IO.puts(
  "seeded #{map_size(sources)} sources, #{map_size(scopes)} scope(s), " <>
    "#{map_size(people)} people"
)
