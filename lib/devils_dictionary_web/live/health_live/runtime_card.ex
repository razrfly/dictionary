defmodule DevilsDictionaryWeb.HealthLive.RuntimeCard do
  @moduledoc """
  The "Editor runtime" card on `/ops/health` (#267 §3.4, #264 R17): the
  private model service's slot, which database it is bound to, the
  registered model, today's inference and the last smoke and attempt.

  Read-only, with no button. It renders `Runtime.Snapshot.read/1`, which is
  SELECTs and a file read, so mounting the page writes nothing and calls
  nothing; an empty database says "none" on every line. It shows current
  state only: `inference_services` keeps no window or stop history, and a
  slot marked available is not proof the process is running, so the card
  says the process is not checked here. #264's "Proposals" card, with the
  review units, sits directly below it.
  """
  use DevilsDictionaryWeb, :html

  @doc "The card, for a `Runtime.Snapshot.read/1` map."
  attr :snapshot, :map, required: true

  def runtime_card(assigns) do
    ~H"""
    <.section
      id="runtime-card"
      eyebrow="Curation"
      headline="Editor runtime"
      subheadline="The private model service, read from the database and the authority marker. Nothing here starts, stops or calls it."
    >
      <dl class="grid grid-cols-1 gap-x-8 gap-y-3 rounded-xl bg-mist-950/2.5 p-6 text-sm/7 sm:grid-cols-[10rem_1fr] dark:bg-white/5">
        <.line id="runtime-slot" label="Slot (database)">{slot_text(@snapshot.service)}</.line>
        <.line id="runtime-process" label="Process">
          not checked here: a window's start and stop are in its record
        </.line>
        <.line id="runtime-bound" label="Bound to">{bound(@snapshot.authority)}</.line>
        <.line id="runtime-model" label="Model">{models(@snapshot.model_configs)}</.line>
        <.line id="runtime-today" label="Today">{today(@snapshot.today)}</.line>
        <.line id="runtime-smoke" label="Last smoke">{attempt(@snapshot.last_smoke)}</.line>
        <.line id="runtime-attempt" label="Last attempt">{attempt(@snapshot.last_attempt)}</.line>
      </dl>
    </.section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp line(assigns) do
    ~H"""
    <dt class="font-medium text-mist-950 dark:text-white">{@label}</dt>
    <dd id={@id} class="min-w-0 text-mist-700 wrap-anywhere dark:text-mist-400">
      {render_slot(@inner_block)}
    </dd>
    """
  end

  defp slot_text(nil), do: "none"

  defp slot_text(service) do
    holder = if service.holder_attempt_id, do: "held by attempt #{service.holder_attempt_id}"

    reason =
      case service.state do
        :paused -> service.paused_reason
        :quarantined -> service.quarantine_reason
        _ -> nil
      end

    [
      to_string(service.state),
      reason,
      service.key,
      "epoch #{service.epoch}",
      "fence #{service.fence}",
      holder || "no holder"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp bound(:unbound), do: "none (no authority marker)"
  defp bound(:unreadable), do: "unreadable authority marker"

  defp bound(%{database: database, here: here}) do
    "#{database} (run/authority.json)" <>
      if(here, do: " · this database", else: " · not this database")
  end

  defp models([]), do: "none"

  defp models(configs) do
    Enum.map_join(configs, "; ", fn c ->
      "#{c.slug} · #{c.instruction_version} · digest #{String.slice(c.manifest_digest, 0, 8)}… · config ##{c.id}"
    end)
  end

  defp today(nil), do: "none"

  defp today(%{charged_ms: charged, reserved_ms: reserved, limit_ms: limit}) do
    "#{duration(charged)} of #{div(limit, 60_000)} min of inference" <>
      if(reserved > 0, do: " · #{duration(reserved)} reserved by a live attempt", else: "")
  end

  defp duration(ms) do
    seconds = div(ms, 1000)

    "#{div(seconds, 60)} min #{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")} s"
  end

  defp attempt(nil), do: "none"

  defp attempt(a) do
    [
      stamp(a.finished_at || a.admitted_at),
      a.request_key,
      to_string(a.outcome || a.state),
      "attempt ##{a.id}"
    ]
    |> Enum.join(" · ")
  end

  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
end
