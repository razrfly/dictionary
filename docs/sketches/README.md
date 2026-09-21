# Sketches

Migrations and modules written to answer a question, proven, and then taken out
of the path where they would run — and, since #131, design sketches of pages
that do not exist yet.

## Design

| Directory | What it holds |
|---|---|
| [`word-page/`](word-page/) | #131 Phase 1 — three whole-page layouts for `/define/:slug` as static HTML against the app's own tokens, with the hard cases and the GIF-shelf versions beside them. Screenshots and the write-up are under [`../discovery/`](../discovery/) |

## Retired migrations

Nothing here is loaded, compiled or run. `.exs` outside `priv/repo/migrations/`
is invisible to `mix ecto.migrate`, and `mix precommit` — which migrates the
test database — cannot reach it either.

| File | Question it answered | Why it is gone |
|---|---|---|
| `community_layer_migration.exs` | #69 §7 **E3** — does the community layer of §4's sketch fit the finished MVP-0 schema? Yes: `users`, `examples` and `votes` were generated, applied to a full development database, diffed against a schema dump taken before them, and rolled back, adding three tables and changing no column, index or constraint of the thirteen. | **The community layer shipped.** #74 built it as schema — `users`, `actors`, `assertion_reviews`, `assertion_votes`, `review_contexts` — so a rolled-back sketch of it is no longer evidence of anything, and a scorecard row testing `File.exists?` on it would be measuring the presence of a file. E3 became [the extension exercise](../../test/devils_dictionary/extension_test.exs) instead: a translated poem passage, and what allowing it cost. |

The dated result above is preserved because it was true when it was made. What
is withdrawn is only its use as a *current* measurement.
