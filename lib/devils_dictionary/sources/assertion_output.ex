defmodule DevilsDictionary.Sources.AssertionOutput do
  @moduledoc """
  Which assertions a source record produced, and when a run last re-emitted them.

  The claim-side twin of `MaterializedOutput`, and the reason the linker can
  stop leaving unsupported links behind. A rung that no longer finds a match
  does not delete the link — it stops stamping it, and reconciliation retires
  it, which keeps the history and leaves any editorial decision about it intact.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Claims.Assertion
  alias DevilsDictionary.Sources.{ImportRun, SourceRecord}

  @primary_key false
  schema "source_assertion_outputs" do
    belongs_to :source_record, SourceRecord, primary_key: true
    field :output_key, :string, primary_key: true
    belongs_to :assertion, Assertion
    belongs_to :last_seen_run, ImportRun
    field :retired_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(output, attrs) do
    output
    |> cast(attrs, [
      :source_record_id,
      :output_key,
      :assertion_id,
      :last_seen_run_id,
      :retired_at
    ])
    |> validate_required([:source_record_id, :output_key, :assertion_id])
  end
end
