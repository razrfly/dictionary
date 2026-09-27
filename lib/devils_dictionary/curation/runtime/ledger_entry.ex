defmodule DevilsDictionary.Curation.Runtime.LedgerEntry do
  @moduledoc """
  One append-only accounting entry (#195, G7, G8).

    * `reserve`: at admission, the call's deadline, on its budget day;
    * `release`: at settlement, exactly that reservation, once;
    * `charge`: at settlement, the slot occupancy that fell on each UTC day.

  The database refuses a second reserve or release for an attempt, a second
  charge for the same attempt and day, and any settlement of an attempt that
  has not finished.
  """
  use Ecto.Schema

  schema "inference_ledger_entries" do
    field :service_id, :id
    field :attempt_id, :id
    field :kind, Ecto.Enum, values: [:reserve, :release, :charge]
    field :day, :date
    field :amount_ms, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
