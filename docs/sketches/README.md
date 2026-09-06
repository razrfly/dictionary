# Sketches

Migrations and modules written to answer a question, proven, and then taken out
of the path where they would run.

| File | Question | Answer |
|---|---|---|
| `community_layer_migration.exs` | #69 §7 **E3** — does the community layer of §4's sketch fit the finished MVP-0 schema? | Yes. `users`, `examples` and `votes` were generated with `mix ecto.gen.migration`, applied to a full development database, diffed against a schema dump taken before them, and rolled back. The diff adds three tables, seven indexes and two check constraints, and changes **no column, index or constraint of the thirteen**. Four foreign keys point into `lexemes`, `senses`, `concepts` and `sources` without adding anything to them. |

Nothing here is loaded, compiled or run. `.exs` outside `priv/repo/migrations/`
is invisible to `mix ecto.migrate`, and `mix precommit` — which migrates the
test database — cannot reach it either.
