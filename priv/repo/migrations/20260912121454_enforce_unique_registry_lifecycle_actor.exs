defmodule DevilsDictionary.Repo.Migrations.EnforceUniqueRegistryLifecycleActor do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute """
    WITH lifecycle_actors AS (
      SELECT id, min(id) OVER () AS keeper_id
      FROM actors
      WHERE actor_kind = 'import' AND label = 'Registry lifecycle system'
    )
    UPDATE actors AS actor
    SET label = 'Registry lifecycle system (legacy ' || actor.id || ')'
    FROM lifecycle_actors
    WHERE actor.id = lifecycle_actors.id AND actor.id <> lifecycle_actors.keeper_id
    """

    create unique_index(:actors, [:label],
             where: "actor_kind = 'import' AND label = 'Registry lifecycle system'",
             name: :actors_registry_lifecycle_system_index,
             concurrently: true
           )
  end

  def down do
    drop index(:actors, [:label],
           name: :actors_registry_lifecycle_system_index,
           concurrently: true
         )
  end
end
