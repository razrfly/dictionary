defmodule DevilsDictionary.Repo.Migrations.AddUnresolvedCreatorCaseIndex do
  use Ecto.Migration

  # #164 C7: a relationship naming a QID the registry lacks and Wikidata cannot
  # supply opens one `unresolved_creator` case per (source, QID). Two runs
  # crediting the same missing QID at once would each find no open case and
  # insert one; a check-then-insert cannot prevent that and this index can.
  # Other kinds carry no `qid` in their payload, so the expression is NULL for
  # them and they never collide.
  def change do
    create unique_index(:reconciliation_cases, [:source_id, :kind, "(payload->>'qid')"],
             where: "status = 'open'",
             name: :reconciliation_cases_open_qid_index
           )
  end
end
