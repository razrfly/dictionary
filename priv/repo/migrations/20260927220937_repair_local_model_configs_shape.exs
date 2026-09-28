defmodule DevilsDictionary.Repo.Migrations.RepairLocalModelConfigsShape do
  @moduledoc """
  Re-states `local_model_configs_shape` exactly as `HardenCurationRuntime`
  (#210) defines it.

  On 27 September 2026 at 13:11 UTC the development database was migrated by
  mistake from an unmerged branch (#194's incident record), and what ran there
  as `20260927131023` was an earlier draft of that migration: its CHECK tests
  that `generation` *has* the keys `num_ctx` and `num_predict`
  (`generation ? 'num_ctx'`), while the merged migration requires them to be
  JSON numbers (`jsonb_typeof(...) = 'number'`). The version table already
  names the migration as applied, so Ecto never re-runs it. This migration
  makes every database carry the merged constraint, whichever version it ran.

  Idempotent: on a database that already has the merged constraint, dropping
  and re-creating it changes nothing. The audit that found the drift compared
  the four runtime tables and five trigger functions between a fresh database
  and the development database; only this constraint differed (#219, C).
  """
  use Ecto.Migration

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
    drop_if_exists constraint(:local_model_configs, :local_model_configs_shape)

    create constraint(:local_model_configs, :local_model_configs_shape,
             check:
               @shape <>
                 "coalesce(jsonb_typeof(generation -> 'num_ctx'), '') = 'number' AND\n" <>
                 "coalesce(jsonb_typeof(generation -> 'num_predict'), '') = 'number' AND\n" <>
                 @generation_bounds
           )
  end

  # Rolling a repair back must not weaken a database: a fresh one never had
  # the draft, and the development database should not get it back. The
  # constraint stays as it is.
  def down, do: :ok
end
