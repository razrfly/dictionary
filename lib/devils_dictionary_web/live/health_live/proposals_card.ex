defmodule DevilsDictionaryWeb.HealthLive.ProposalsCard do
  @moduledoc """
  The "Proposals" card on `/ops/health` (#264 R17, §2.6), directly below
  #267's "Editor runtime" card: whether the editor is enabled and for which
  configuration version, the review units in use (pending proposals and
  reserved runs, of the cap), proposals by state, today's editor
  assessments and deferrals, and the last deferral with its reason. The
  editor step's refusals, `service_unreachable` among them, are shown here.

  It draws `Curation.Proposals.health_snapshot/1`, which only SELECTs: an
  empty database renders "none" and zeros, and rendering inserts nothing.
  """
  use DevilsDictionaryWeb, :html

  attr :snapshot, :map, required: true

  def card(assigns) do
    ~H"""
    <.section
      id="curation-proposals"
      eyebrow="Curation"
      headline="Proposals"
      subheadline="The generic editor's proposals and the owner's review work. A proposal never moves what a page shows; only the owner's Take or Edit does."
    >
      <dl
        id="proposals-card"
        class="grid grid-cols-1 gap-x-8 gap-y-3 rounded-xl bg-mist-950/2.5 p-6 text-sm/6 sm:grid-cols-[9rem_minmax(0,1fr)] dark:bg-white/5"
      >
        <dt class="font-medium text-mist-950 dark:text-white">Editor</dt>
        <dd id="proposals-card-editor" class="text-mist-700 dark:text-mist-300">
          {editor(@snapshot.enabled)}
        </dd>

        <dt class="font-medium text-mist-950 dark:text-white">Review units</dt>
        <dd id="proposals-card-units" class="text-mist-700 tabular-nums dark:text-mist-300">
          {@snapshot.review_units.pending} pending + {@snapshot.review_units.reserved} reserved of {@snapshot.review_units.cap}
        </dd>

        <dt class="font-medium text-mist-950 dark:text-white">Proposals</dt>
        <dd id="proposals-card-proposals" class="text-mist-700 tabular-nums dark:text-mist-300">
          {@snapshot.proposals.pending} pending ({@snapshot.proposals.superseded_on_arrival} superseded on arrival) · {@snapshot.proposals.taken} taken · {@snapshot.proposals.dismissed} dismissed · {@snapshot.proposals.obsolete} obsolete
        </dd>

        <dt class="font-medium text-mist-950 dark:text-white">Today</dt>
        <dd id="proposals-card-today" class="text-mist-700 tabular-nums dark:text-mist-300">
          {@snapshot.today.proposed} proposed · {@snapshot.today.abstained} abstained · {@snapshot.today.no_change} no change · {@snapshot.today.deferred} deferred
        </dd>

        <dt class="font-medium text-mist-950 dark:text-white">Last deferral</dt>
        <dd id="proposals-card-deferral" class="text-mist-700 dark:text-mist-300">
          {deferral(@snapshot.last_deferral)}
        </dd>
      </dl>
    </.section>
    """
  end

  defp editor(nil), do: "none: not enabled"

  defp editor(%{} = e) do
    [
      "enabled for #{e.configuration} v#{e.configuration_version}",
      e.at && stamp(e.at),
      e.by && "by #{e.by}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp deferral(nil), do: "none"

  defp deferral(%{} = d) do
    [
      d.page || "a page",
      d.error || "no reason recorded",
      d.next_retry_at && "retry #{time(d.next_retry_at)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %H:%M")
  defp time(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")
end
