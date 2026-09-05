defmodule DevilsDictionary.Sources.ImportRun do
  @moduledoc """
  Every task run leaves a row. The import dashboard and `mix dd.score` read
  these. Spec: issue #69 §4.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:running, :done, :failed]

  @timestamps_opts false
  schema "import_runs" do
    belongs_to :source, DevilsDictionary.Sources.Source
    belongs_to :scope, DevilsDictionary.Lexicon.Scope

    field :task, :string
    field :status, Ecto.Enum, values: @statuses, default: :running
    field :stats, :map, default: %{}
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
  end

  @doc false
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :source_id,
      :scope_id,
      :task,
      :status,
      :stats,
      :error,
      :started_at,
      :finished_at
    ])
    |> validate_required([:task, :status])
  end
end
