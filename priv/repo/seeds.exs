# The source registry: five open sources for MVP-0 (issue #69 §2), the Animals
# test scope (§3), and Bierce as a person who authored a layer.
#
# The definitions live in DevilsDictionary.Sources.Catalog, not here, because
# seeds do not run in :test — tests upsert the same catalog themselves.
# Idempotent: re-running only refreshes the pinned config.
#
#     mix run priv/repo/seeds.exs

%{sources: sources, scopes: scopes} = DevilsDictionary.Sources.Catalog.seed!()

IO.puts("seeded #{map_size(sources)} sources, #{map_size(scopes)} scope(s), 1 person")
