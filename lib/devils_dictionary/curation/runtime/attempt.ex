defmodule DevilsDictionary.Curation.Runtime.Attempt do
  @moduledoc """
  One admitted request to the runtime, and everything known about it (#195).

  The lifecycle, enforced by a trigger:

      admitted ─┬─> dispatched ─┬─> completed            (an answer came back)
                │               ├─> failed_pre_dispatch  (connection refused: never sent)
                │               └─> uncertain ──> ended_by_restart
                └─> released                             (never sent; lease ran out)

  `dispatched` is committed *before* the request is sent. An `admitted`
  attempt therefore provably never reached the model, and a `dispatched` one
  might have. `uncertain` is not an outcome but the absence of one: the
  service is quarantined until a controlled stop proves the generation
  ended.

  What is kept:

    * the request key;
    * the packet's hash and a summary of ids, revision ids and excerpt
      hashes;
    * the prompt's hash;
    * the validated result, with quotes as hashes and ranges;
    * refusal reasons and runtime metrics.

  What is never kept: excerpt text, the prompt, or any reasoning the model
  emitted.
  """
  use Ecto.Schema

  alias DevilsDictionary.Types.JsonValue

  @states [
    :admitted,
    :dispatched,
    :completed,
    :failed_pre_dispatch,
    :uncertain,
    :ended_by_restart,
    :released
  ]

  @outcomes [:accepted, :abstained, :refused, :runtime_error, :unknown, :never_sent]

  @terminal [:completed, :failed_pre_dispatch, :ended_by_restart, :released]

  # The `inference_attempts_shape` CHECK (migration 20260927114948) holds
  # `transport_retries` between 0 and 2. This is that bound, and the one place
  # the code reads it from (#221 A1). Configuration may ask for fewer retries,
  # never more (`Endpoint.transport_retries/1`). A higher ceiling is a
  # migration of the CHECK, and `GatewayTest` fails until both agree.
  @max_transport_retries 2

  schema "inference_attempts" do
    field :service_id, :id
    field :model_config_id, :id
    field :request_key, :string
    field :purpose, Ecto.Enum, values: [:request, :readiness_smoke, :benchmark]
    field :packet_hash, :string
    field :packet_bytes, :integer
    field :packet_summary, :map
    field :prompt_sha256, :string
    field :requested_by_actor_id, :id
    field :owner, :string
    field :fence, :integer
    field :service_epoch, :integer
    field :state, Ecto.Enum, values: @states, default: :admitted
    field :outcome, Ecto.Enum, values: @outcomes
    field :refusal_reasons, JsonValue, default: []
    field :result, :map
    field :metrics, :map, default: %{}
    field :transport_retries, :integer, default: 0
    field :reserved_ms, :integer
    field :units, :integer, default: 1
    field :budget_day, :date
    field :admitted_at, :utc_datetime_usec
    field :dispatched_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :lease_expires_at, :utc_datetime_usec
    field :settled_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def states, do: @states
  def outcomes, do: @outcomes
  def terminal, do: @terminal
  def live, do: [:admitted, :dispatched, :uncertain]

  @doc """
  The most often one attempt may retry a refused connection: the database's
  own bound on `transport_retries`.
  """
  def max_transport_retries, do: @max_transport_retries
end
