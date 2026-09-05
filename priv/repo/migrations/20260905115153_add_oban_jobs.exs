defmodule DevilsDictionary.Repo.Migrations.AddObanJobs do
  @moduledoc """
  Oban's job table. Infrastructure, not domain schema: the thirteen tables of
  #69 §4 are untouched, so scorecard row E1 ("a new source costs 0 migrations")
  still holds.
  """
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14)

  def down, do: Oban.Migration.down(version: 1)
end
