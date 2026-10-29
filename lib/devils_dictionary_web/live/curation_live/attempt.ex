defmodule DevilsDictionaryWeb.CurationLive.Attempt do
  @moduledoc """
  One editor attempt, `/ops/curation/attempts/:id` (#253 D9, #264 R16, §2.5).

  Reviewer-only, inside the separate curation `live_session`, including over
  the published tunnel. Other operator surfaces remain local-only.
  Every model-selected item reaches its attempt here, through its version's
  `attempt_id`, or after a Take through the copy it was taken from.

  What it shows is what the attempt kept: the request key, the model config,
  the packet's hash, policy and counts, its meanings, the candidates offered
  and those the cut omitted with their reasons, the validated answer (each
  choice's candidate, meaning and reason, a quote as its hash and range),
  the outcome, any refusal, the latency and tokens, and the proposal version
  it produced. **Ids and hashes only: never excerpt text.** Reads only.
  """
  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Curation.{CompositionVersion, Proposals}
  alias DevilsDictionary.Curation.Runtime.{Attempt, ModelConfig}
  alias DevilsDictionary.Repo

  on_mount {DevilsDictionaryWeb.UserAuth, :require_reviewer}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # An attempt that does not exist answers 404 (`Ecto.NoResultsError`).
    attempt =
      case Integer.parse(id) do
        {n, ""} -> Repo.get!(Attempt, n)
        _other -> raise Ecto.NoResultsError, queryable: Attempt
      end

    config = Repo.get(ModelConfig, attempt.model_config_id)
    version = Repo.get_by(CompositionVersion, attempt_id: attempt.id)
    summary = attempt.packet_summary || %{}

    {:ok,
     assign(socket,
       page_title: "Attempt ##{attempt.id}",
       attempt: attempt,
       config: config,
       proposed_by: Proposals.proposed_by(config),
       version: version,
       proposal: version && Proposals.for_version(version.id),
       page: version && Proposals.page_slug(version.composition_id),
       summary: summary,
       candidates: summary["candidates"] || [],
       omitted: summary["omitted"] || [],
       meanings: summary["meanings"] || [],
       result: attempt.result || %{}
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.container>
        <div id="curation-attempt" class="flex flex-col gap-8 py-10 sm:py-14">
          <header class="flex flex-col gap-2">
            <.link
              navigate={~p"/ops/curation"}
              class="flex min-h-11 w-fit items-center gap-1 rounded-sm text-sm/7 text-mist-600 hover:text-mist-950 sm:min-h-0 dark:text-mist-400 dark:hover:text-white"
            >
              <span aria-hidden="true">←</span> Curation
            </.link>
            <h1 class="font-display text-4xl/12 text-mist-950 dark:text-white">
              Attempt #{@attempt.id}
            </h1>
            <p class="text-sm/7 text-pretty text-mist-600 dark:text-mist-400">
              What the editor was offered and what it answered, as the attempt recorded it: ids
              and hashes, never the excerpts themselves.
            </p>
          </header>

          <dl
            id="attempt-facts"
            class="grid grid-cols-1 gap-x-8 gap-y-3 text-sm/6 sm:grid-cols-[11rem_minmax(0,1fr)]"
          >
            <.fact id="attempt-key" label="Request key"><code>{@attempt.request_key}</code></.fact>
            <.fact id="attempt-model" label="Model config">
              {@proposed_by}{if @config,
                do: " · config ##{@config.id} · #{short(@config.config_hash)}"}
            </.fact>
            <.fact id="attempt-packet" label="Packet">
              <code>{short(@attempt.packet_hash)}</code>
              · {@summary["packet_version"] || "—"} · {policy(@summary)}
            </.fact>
            <.fact id="attempt-counts" label="Counts">
              {length(@candidates)} offered of {get_in(@summary, ["counts", "offered"]) ||
                length(@candidates)} candidates · {length(@omitted)} omitted · {length(@meanings)} of {get_in(
                @summary,
                ["counts", "meanings_total"]
              ) || length(@meanings)} meanings
            </.fact>
            <.fact id="attempt-outcome" label="Outcome">
              {@attempt.state} · {@attempt.outcome || "no answer"}{refusals(@attempt.refusal_reasons)}
            </.fact>
            <.fact id="attempt-metrics" label="Latency, tokens">
              {metrics(@attempt.metrics)}
            </.fact>
            <.fact id="attempt-when" label="When">
              {stamp(@attempt.admitted_at)}{if @attempt.finished_at,
                do: " → #{stamp(@attempt.finished_at)}"}
            </.fact>
            <.fact id="attempt-proposal" label="Proposal">
              <%= cond do %>
                <% @version && @page -> %>
                  <.link
                    navigate={~p"/ops/curation/on/#{@page}?#{%{proposal: @version.id}}"}
                    class="underline underline-offset-4"
                  >
                    version {@version.version} of {@page}
                  </.link>
                  <span :if={@proposal}> · {@proposal.state}</span>
                <% @version -> %>
                  version id {@version.id}
                <% true -> %>
                  none: this attempt wrote no version
              <% end %>
            </.fact>
          </dl>

          <section id="attempt-answer" class="flex flex-col gap-3">
            <h2 class="text-sm/7 font-semibold tracking-wide text-mist-950 uppercase dark:text-white">
              The validated answer
            </h2>
            <p :if={@result == %{}} class="text-sm/7 text-mist-500">No validated answer.</p>
            <p
              :if={@result["decision"] == "abstain"}
              class="text-sm/7 text-mist-700 dark:text-mist-300"
            >
              Abstained: “{@result["abstain_reason"]}”
            </p>
            <ul role="list" class="flex flex-col gap-2 text-sm/6">
              <li :for={{slot, choice} <- choices(@result)} id={"attempt-choice-#{slot}"}>
                <span class="font-medium text-mist-950 dark:text-white">{slot}</span>
                · candidate <code>{choice["candidate_id"]}</code>
                · meaning <code>{choice["meaning_id"]}</code>{quote_range(choice["quote"])}
                <span class="block text-mist-700 text-pretty dark:text-mist-300">
                  “{choice["reason"]}”
                </span>
              </li>
            </ul>
          </section>

          <section id="attempt-offered" class="flex flex-col gap-3">
            <h2 class="text-sm/7 font-semibold tracking-wide text-mist-950 uppercase dark:text-white">
              Offered ({length(@candidates)})
            </h2>
            <ul
              role="list"
              class="flex flex-col gap-1 font-mono text-xs/6 text-mist-700 dark:text-mist-300"
            >
              <li :for={c <- @candidates} id={"attempt-offered-#{c["candidate_id"]}"}>
                {c["candidate_id"]} · {c["kind"]} · object {c["object_id"]}{revision(c)} · meaning {c[
                  "required_meaning"
                ]} · {short(c["excerpt_sha256"] || c["label_sha256"])}
              </li>
            </ul>
          </section>

          <section id="attempt-omitted" class="flex flex-col gap-3">
            <h2 class="text-sm/7 font-semibold tracking-wide text-mist-950 uppercase dark:text-white">
              Omitted by the cut ({length(@omitted)})
            </h2>
            <p :if={@omitted == []} class="text-sm/7 text-mist-500">None.</p>
            <ul
              role="list"
              class="flex flex-col gap-1 font-mono text-xs/6 text-mist-700 dark:text-mist-300"
            >
              <li :for={o <- @omitted} id={"attempt-omitted-#{o["key"]}"}>
                {o["key"]} · {o["kind"]} · object {o["object_id"]} · {o["reason"]}
              </li>
            </ul>
          </section>

          <section id="attempt-meanings" class="flex flex-col gap-3">
            <h2 class="text-sm/7 font-semibold tracking-wide text-mist-950 uppercase dark:text-white">
              Meanings ({length(@meanings)})
            </h2>
            <ul
              role="list"
              class="flex flex-col gap-1 font-mono text-xs/6 text-mist-700 dark:text-mist-300"
            >
              <li :for={m <- @meanings}>
                {m["meaning_id"]} · {m["kind"]} · {m["lexeme_id"] || m["sense_revision_id"]}
              </li>
            </ul>
          </section>
        </div>
      </.container>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp fact(assigns) do
    ~H"""
    <dt class="font-medium text-mist-950 dark:text-white">{@label}</dt>
    <dd id={@id} class="text-mist-700 text-pretty break-words dark:text-mist-300">
      {render_slot(@inner_block)}
    </dd>
    """
  end

  defp choices(result) do
    lead = if result["lead"], do: [{"lead", result["lead"]}], else: []

    highlights =
      (result["highlights"] || [])
      |> Enum.with_index(1)
      |> Enum.map(fn {h, n} -> {"highlight-#{n}", h} end)

    lead ++ highlights
  end

  defp quote_range(%{"sha256" => sha, "byte_offset" => offset, "byte_length" => length}),
    do: " · quote #{short(sha)} at bytes #{offset}+#{length}"

  defp quote_range(_none), do: ""

  defp revision(%{"content_revision_id" => id}) when is_integer(id), do: ", revision #{id}"

  defp revision(%{"sense_revision_id" => id, "locator" => locator}) when is_integer(id),
    do: ", sense revision #{id} #{locator}"

  defp revision(%{"assertion_revision_id" => id}) when is_integer(id),
    do: ", claim revision #{id}"

  defp revision(%{"catalog" => %{"manifest" => m, "identity" => i}}), do: ", catalog #{m} #{i}"
  defp revision(_c), do: ""

  defp policy(%{"policy" => %{"cut" => cut, "meanings" => meanings}}), do: "#{cut} · #{meanings}"
  defp policy(_summary), do: "policy not recorded"

  defp refusals([]), do: ""
  defp refusals(nil), do: ""

  defp refusals(reasons),
    do: " · " <> Enum.map_join(reasons, ", ", &Enum.join(List.wrap(&1), ": "))

  defp metrics(metrics) when is_map(metrics) do
    [
      metrics["wall_ms"] && "#{metrics["wall_ms"]} ms",
      metrics["prompt_eval_count"] && "#{metrics["prompt_eval_count"]} prompt tokens",
      metrics["eval_count"] && "#{metrics["eval_count"]} output tokens"
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "not recorded"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp metrics(_metrics), do: "not recorded"

  defp short(nil), do: "—"
  defp short(hash) when is_binary(hash), do: String.slice(hash, 0, 12)

  defp stamp(nil), do: "—"
  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %Y %H:%M:%S UTC")
end
