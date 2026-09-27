defmodule DevilsDictionary.Repo.Migrations.HardenCurationRuntime do
  @moduledoc """
  Two repairs to `CreateCurationRuntime` (#195 stage A), from review of PR
  #210. They are a migration of their own because that one is already applied
  in the benchmark databases that hold the stage A evidence.

    * A model config must carry `num_ctx` and `num_predict`. A missing key
      made the bound check NULL, and a CHECK accepts NULL.
    * The slot's holder must be live under the service's fence however the
      attempt changes, not only when the service row changes (G1, G4). An
      attempt that finished while still named as holder would leave the
      service `occupied` for ever.
  """
  use Ecto.Migration

  @live "('admitted', 'dispatched', 'uncertain')"

  @generation_bounds """
  (generation ->> 'num_ctx')::int BETWEEN 1024 AND 32768 AND
  (generation ->> 'num_predict')::int BETWEEN 1 AND 1024
  """

  @shape """
  runtime = 'ollama' AND
  manifest_digest ~ '^[0-9a-f]{64}$' AND weights_digest ~ '^[0-9a-f]{64}$' AND
  jsonb_typeof(layers) = 'array' AND jsonb_typeof(capabilities) = 'array' AND
  """

  def up do
    drop constraint(:local_model_configs, :local_model_configs_shape)

    create constraint(:local_model_configs, :local_model_configs_shape,
             check:
               @shape <>
                 "generation ? 'num_ctx' AND generation ? 'num_predict' AND\n" <>
                 @generation_bounds
           )

    execute """
    CREATE FUNCTION inference_attempts_holder_check() RETURNS trigger AS $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM inference_services s
          JOIN inference_attempts a ON a.id = s.holder_attempt_id
         WHERE s.holder_attempt_id = NEW.id
           AND (a.state NOT IN #{@live} OR a.fence <> s.fence)
      ) THEN
        RAISE EXCEPTION 'attempt % holds its service without being live under the fence', NEW.id
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE CONSTRAINT TRIGGER inference_attempts_holder AFTER UPDATE ON inference_attempts
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION inference_attempts_holder_check();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS inference_attempts_holder ON inference_attempts"
    execute "DROP FUNCTION IF EXISTS inference_attempts_holder_check()"

    drop constraint(:local_model_configs, :local_model_configs_shape)

    create constraint(:local_model_configs, :local_model_configs_shape,
             check: @shape <> @generation_bounds
           )
  end
end
