defmodule DevilsDictionaryWeb.CurationReceiptLive do
  @moduledoc "Public version receipts; reads only, with no indexing or private attempt links."
  use DevilsDictionaryWeb, :live_view
  on_mount DevilsDictionaryWeb.ReadingMode
  alias DevilsDictionary.Curation.{Receipt, ContentDate}
  @impl true
  def mount(%{"slug" => slug, "version" => version}, _session, socket) do
    with {number, ""} <- Integer.parse(version), {:ok, receipt} <- Receipt.read(slug, number) do
      {:ok,
       assign(socket,
         receipt: receipt,
         page_title: "How #{slug} was curated · version #{number}",
         head: nil
       )}
    else
      _ -> raise Ecto.NoResultsError, queryable: DevilsDictionary.Curation.CompositionVersion
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <main id="curation-receipt" class="mx-auto flex max-w-4xl flex-col gap-8 px-5 py-10 sm:px-8">
        <header class="flex flex-col gap-3">
          <.link navigate={~p"/on/#{@receipt.slug}"} class="w-fit underline underline-offset-4">← {@receipt.slug}</.link>
          <h1 class="font-display text-4xl/12">How this page was curated</h1>
          <p id="receipt-version">
            Version {@receipt.version.version} · published {stamp(@receipt.publication.committed_at)}
          </p>
          <p id="receipt-owner-actions">
            Published by {@receipt.publication_actor.label} · actor #{@receipt.publication_actor.id}.
            <span :if={@receipt.review_actor}>Reviewed by {@receipt.review_actor &&
              @receipt.review_actor.label}.</span>
            <span
              :if={@receipt.publication.authority_kind == :single_editor}
              id="receipt-agent-authority"
            >Automatically published under single-editor policy; no human approval.</span>
          </p>
          <p id="receipt-window">Assessment window: {div(@receipt.window, 3600)} hours.</p>
          <nav id="receipt-versions" aria-label="Published versions" class="flex flex-wrap gap-3">
            <.link
              :for={number <- @receipt.published_versions}
              navigate={~p"/on/#{@receipt.slug}/receipt/#{number}"}
              class="underline underline-offset-4"
            >Version {number}</.link>
          </nav>
        </header>
        <article
          :for={item <- @receipt.items}
          id={"receipt-item-#{item.role}-#{item.position}"}
          class="flex min-w-0 flex-col gap-4 rounded-xl border border-mist-200 p-5 dark:border-mist-800"
        >
          <h2 class="text-xl font-medium">
            {String.capitalize(to_string(item.role))} {item.position} · {human(item.kind)}
          </h2>
          <p id={"receipt-status-#{item.id}"}>{status(item)}</p>
          <dl class="grid gap-x-6 gap-y-2 sm:grid-cols-[8rem_1fr]">
            <dt class="font-medium">Chosen by</dt><dd id={"receipt-chooser-#{item.id}"}>
              {chooser(item.chooser)}
            </dd>
            <dt class="font-medium">Chosen</dt><dd>{stamp(item.chooser.at)}</dd>
            <dt class="font-medium">Reason</dt><dd id={"receipt-reason-#{item.id}"}>
              {item.reason || withheld_reason(item)}<span :if={item.reason_author.label}> · {item.reason_author.label}</span>
            </dd>
            <dt class="font-medium">Based on</dt><dd id={"receipt-basis-#{item.id}"}>
              {basis(item.basis)}
            </dd>
            <dt :if={item.later_owner} class="font-medium">Later owner</dt><dd :if={item.later_owner}>
              Actor #{item.later_owner} · reviewed or carried the choice
            </dd>
            <dt :if={item.basis && item.basis.reason_rewritten} class="font-medium">
              Reason rewritten
            </dt><dd :if={item.basis && item.basis.reason_rewritten}>
              Attributed to {item.reason_author.label || "the recorded owner"}<span :if={
                item.reason_author.actor_id
              }> · actor #{item.reason_author.actor_id}</span>
            </dd>
            <dt class="font-medium">Content date</dt><dd id={"receipt-date-#{item.id}"}>
              {date(item)}
            </dd>
            <dt :if={item.source_edition} class="font-medium">Source edition</dt><dd :if={
              item.source_edition
            }>
              {item.source_edition}
            </dd>
            <dt :if={item.fetched} class="font-medium">Fetched</dt><dd :if={item.fetched}>
              {stamp(item.fetched)}
            </dd>
          </dl>
          <div
            :if={item.representation}
            id={"receipt-representation-#{item.id}"}
            class="rounded-lg bg-mist-950/5 p-3 dark:bg-white/5"
          >
            {item.representation["subject_label"]} {item.representation["predicate_phrase"]} {item.representation[
              "object_label"
            ]}
          </div>
          <p :if={
            item.current_label && item.representation &&
              item.current_label !=
                Enum.join(
                  [
                    item.representation["subject_label"],
                    item.representation["predicate_phrase"],
                    item.representation["object_label"]
                  ],
                  " "
                )
          }>
            Now: {item.current_label}
          </p>
          <div :if={item.provider_metadata} id={"receipt-provider-fields-#{item.id}"}>
            <p>Selected from provider metadata.</p>
            <p>{item.provider_metadata["title"]}</p>
            <p :for={reason <- item.provider_match}>
              {DevilsDictionary.Discovery.MatchReason.describe(reason)}
            </p>
          </div>
          <p
            :if={item.citation && is_nil(item.provider_metadata)}
            id={"receipt-provider-status-#{item.id}"}
          >
            Provider fields are unavailable here: {DevilsDictionaryWeb.Opening.withheld_reason(
              item.provider_status
            )}. {payload_status(item.payload_state)}
          </p>
          <details class="min-w-0">
            <summary class="cursor-pointer underline underline-offset-4">
              Exact record and evidence
            </summary>
            <dl class="mt-3 flex min-w-0 flex-col gap-2 break-all text-sm">
              <div :for={{key, value} <- Enum.sort(item.reference)}>
                <dt class="font-medium">{key}</dt><dd>{value_text(value)}</dd>
              </div>
              <div :for={{key, value} <- citation_fields(item.citation)}>
                <dt class="font-medium">{key}</dt><dd>{value_text(value)}</dd>
              </div>
              <div :if={item.basis}>
                <dt class="font-medium">Supplied evidence sha256</dt><dd>
                  {item.basis.supplied_sha256 || "not recorded"}
                </dd>
              </div>
            </dl>
          </details>
        </article>
      </main>
    </Layouts.app>
    """
  end

  defp status(%{status: :shown}), do: "Shown on the current page."

  defp status(%{status: :withheld, status_reason: r}),
    do: "Withheld now: #{DevilsDictionaryWeb.Opening.withheld_reason(r)}."

  defp status(%{status: :withdrawn, replacement: r}), do: "Withdrawn #{stamp(r.at)}: #{r.reason}"

  defp status(%{status: :replaced, replacement: r}),
    do: "Replaced by version #{r.version}, #{stamp(r.at)}."

  defp chooser(%{kind: :model} = c),
    do:
      "#{c.label}, an AI model · #{c.model} · model config ##{c.model_config_id} · attempt ##{c.attempt_id}" <>
        if(c.profile,
          do:
            " · profile ##{c.profile["profile_id"]}, version ##{c.profile["profile_version_id"]}",
          else: ""
        )

  defp chooser(c), do: c.label || "chooser not recorded"
  defp basis(nil), do: "basis not recorded"
  defp basis(%{origin: "legacy_unknown"}), do: "basis not recorded (legacy choice)"

  defp basis(%{origin: "model"} = b),
    do: "the editor was given only: #{human(b.evidence_kind)}; #{b.fields_version}."

  defp basis(b),
    do:
      "chosen on the curation screen, which lists #{human(b.evidence_kind)} and links to the source; #{b.fields_version}."

  defp withheld_reason(%{reference: %{"reason_withheld" => %{} = marker}}),
    do: "Reason withheld under #{marker["policy"]}; sha256 #{marker["sha256"]}."

  defp withheld_reason(%{role: :lead}), do: "Chosen by the configuration's lead policy."
  defp withheld_reason(_), do: "reason not recorded"

  defp date(%{citation: c, provider_metadata: nil}) when not is_nil(c),
    do: "value unavailable under #{c.field_policy}; #{c.content_date_meaning || "not supplied"}"

  defp date(item), do: ContentDate.text(item.content_date)
  defp payload_status(:stored), do: "Physical removal has not yet been confirmed."
  defp payload_status(:redacted), do: "The retained source row has been redacted."
  defp payload_status(_), do: "The source payload was deleted."
  defp stamp(nil), do: "not recorded"
  defp stamp(value), do: Calendar.strftime(value, "%d %b %Y %H:%M UTC")
  defp human(nil), do: "not recorded"
  defp human(value), do: value |> to_string() |> String.replace("_", " ")
  defp value_text(nil), do: "not recorded"
  defp value_text(%DateTime{} = v), do: DateTime.to_iso8601(v)
  defp value_text(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp value_text(value), do: to_string(value)
  defp citation_fields(nil), do: []
  defp citation_fields(c), do: c |> Map.from_struct() |> Map.drop([:__meta__]) |> Enum.sort()
end
