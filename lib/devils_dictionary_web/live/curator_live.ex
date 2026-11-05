defmodule DevilsDictionaryWeb.CuratorLive do
  @moduledoc """
  The curator pages (#299): the directory (`/curators`), one page per
  profile at its current version (`/curators/:slug`) and one per immutable
  version (`/curators/:slug/v/:n`).

  Each page keeps #203's four layers apart, labelled, each with the sentence
  that applies to it: the model's inherited knowledge, the dossier we
  authored, the instruction and context supplied, and the recorded result.
  Everything comes from `Curation.Curators`, a read-only projection; the page
  shows no prompt, no packet, no provider payload and no item reason, and a
  human actor appears by role and id only.

  Phones get the same sections in the reader's order (header, what it did,
  what we gave it, what runs it, what it is told, cost, judgments,
  versions) and lists rather than tables, so nothing scrolls sideways.
  """
  use DevilsDictionaryWeb, :live_view
  on_mount DevilsDictionaryWeb.ReadingMode

  alias DevilsDictionary.Curation.Curators
  alias DevilsDictionaryWeb.Opening

  @visible_activity 5

  @impl true
  def mount(params, _session, socket) do
    mode = socket.assigns.reading_mode

    case socket.assigns.live_action do
      :index ->
        {:ok,
         assign(socket,
           cards: Curators.directory(mode),
           page_title: "The curators",
           head: nil
         )}

      action ->
        with {:ok, number} <- number(action, params),
             {:ok, page} <- Curators.page(params["slug"], version: number, mode: mode) do
          {:ok,
           socket
           |> assign(
             page: page,
             page_title: title(page, action),
             visible: @visible_activity,
             head: nil
           )
           |> withheld(action, page)}
        else
          _ -> raise Ecto.NoResultsError, queryable: DevilsDictionary.Curation.Profile
        end
    end
  end

  # What is withheld now is the word page's own read, once per page the
  # curator holds (#304 R1). `assign_async/3` runs it only once the socket
  # is connected, so the first, disconnected render does not pay for it.
  defp withheld(socket, :show, page) do
    current = Map.take(page, [:current])
    assign_async(socket, :withheld, fn -> {:ok, %{withheld: Curators.withheld_now(current)}} end)
  end

  defp withheld(socket, _action, _page), do: socket

  defp number(:show, _params), do: {:ok, nil}

  defp number(:version, %{"version" => raw}) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp title(page, :show), do: "#{page.profile.label} · curators"

  defp title(page, :version),
    do: "#{page.profile.label} · version #{page.version.version} · curators"

  # ── render ───────────────────────────────────────────────────────────────

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div
        id="curators"
        class="mx-auto flex w-full max-w-5xl min-w-0 flex-col gap-10 px-4 py-10 sm:px-8"
      >
        <header class="flex flex-col gap-4">
          <h1 class="font-display text-4xl/12 text-mist-950 sm:text-5xl/14 dark:text-white">
            The curators
          </h1>
          <.text class="max-w-2xl">
            AI selection lenses that choose from the records a page already has. They never
            write definitions or quotations. A persona is modelled on a writer's work and labelled
            "inspired by"; none is that person, speaks in their voice, or checks facts. A persona
            is admitted only with recorded evidence that the writer has died; the generic editor
            has no persona.
          </.text>
        </header>

        <section :if={admitted(@cards) != []} id="curators-admitted" class="flex flex-col gap-4">
          <.eyebrow>Admitted</.eyebrow>
          <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
            <.link
              :for={card <- admitted(@cards)}
              navigate={~p"/curators/#{card.profile.slug}"}
              id={"curator-card-#{card.profile.slug}"}
              class="flex min-w-0 flex-col gap-2 rounded-xl bg-mist-950/2.5 p-5 hover:bg-mist-950/5 dark:bg-white/5 dark:hover:bg-white/10"
            >
              <span class="text-lg/8 font-medium text-mist-950 dark:text-white">
                {card.profile.label}
              </span>
              <span class="text-sm/6 text-mist-700 dark:text-mist-400">
                {version_line(card.current_version)}<span :if={
                  card.binding && card.binding.model_config
                }> · {card.binding.model_config.model_name}</span>
              </span>
              <span class="text-sm/6 text-mist-700 dark:text-mist-400">
                {plural(card.totals.pages, "page")} published · {plural(
                  card.totals.calls,
                  "model call"
                )}
              </span>
              <span class="text-sm/6 text-mist-700 dark:text-mist-400">
                admitted {date(card.profile.admitted_at)} · {if card.live?,
                  do: "bound in the current configuration",
                  else: "not bound in the current configuration"}
              </span>
            </.link>
          </div>
        </section>

        <section :if={proposed(@cards) != []} id="curators-proposed" class="flex flex-col gap-3">
          <.eyebrow>Proposed: not yet used on any page</.eyebrow>
          <ul class="flex flex-col gap-2 text-base/7">
            <li :for={card <- proposed(@cards)} id={"curator-card-#{card.profile.slug}"}>
              <.link
                navigate={~p"/curators/#{card.profile.slug}"}
                class="underline underline-offset-4"
              >
                {card.profile.label}
              </.link>
              <span class="text-mist-600 dark:text-mist-400">
                · no dossier admitted · {if card.deceased_evidence?,
                  do: "deceased-status evidence recorded, not yet reviewed for admission",
                  else: "deceased-status evidence not yet recorded"}
              </span>
            </li>
          </ul>
        </section>

        <section :if={retired(@cards) != []} id="curators-retired" class="flex flex-col gap-3">
          <.eyebrow>Retired</.eyebrow>
          <ul class="flex flex-col gap-2 text-base/7">
            <li :for={card <- retired(@cards)} id={"curator-card-#{card.profile.slug}"}>
              <.link
                navigate={~p"/curators/#{card.profile.slug}"}
                class="underline underline-offset-4"
              >
                {card.profile.label}
              </.link>
            </li>
          </ul>
        </section>

        <.text class="max-w-2xl text-sm/7">
          Every page a curator published has a receipt naming the exact version that chose each
          item; a curator's page lists them under what it did.
        </.text>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div
        id="curator"
        class="mx-auto flex w-full max-w-5xl min-w-0 flex-col gap-12 px-4 py-10 sm:px-8"
      >
        <.curator_header page={@page} action={@live_action} />

        <div class="flex min-w-0 flex-col gap-12">
          <.did
            :if={@live_action == :show}
            page={@page}
            visible={@visible}
            withheld={@withheld}
            class="order-1 lg:order-2"
          />
          <.used_by :if={@live_action == :version} page={@page} class="order-2 lg:order-2" />

          <div class="order-2 grid min-w-0 grid-cols-1 gap-12 lg:order-1 lg:grid-cols-2">
            <.gave page={@page} />
            <div class="flex min-w-0 flex-col gap-12">
              <.runs page={@page} action={@live_action} />
              <.told page={@page} />
            </div>
          </div>

          <.cost :if={@live_action == :show} page={@page} class="order-3" />
          <.judged :if={@live_action == :show} page={@page} class="order-4" />
          <.versions page={@page} class="order-5" />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── header ───────────────────────────────────────────────────────────────

  attr :page, :map, required: true
  attr :action, :atom, required: true

  defp curator_header(assigns) do
    ~H"""
    <header id="curator-header" class="flex min-w-0 flex-col gap-4">
      <.link navigate={~p"/curators"} class="w-fit text-sm/7 underline underline-offset-4">
        ← The curators
      </.link>
      <div class="flex flex-wrap items-baseline gap-x-4 gap-y-2">
        <h1 class="font-display text-4xl/12 text-mist-950 sm:text-5xl/14 dark:text-white">
          {@page.profile.label}
        </h1>
        <span
          id="curator-state"
          class="rounded-full bg-mist-950/10 px-3 py-0.5 text-xs/6 font-semibold tracking-wide uppercase dark:bg-white/10"
        >
          {state_label(@page.profile.state)}
        </span>
      </div>

      <p :if={@action == :version} id="curator-version-status" class="text-base/7 font-medium">
        {version_status(@page)}
      </p>

      <.text id="curator-disclosure" class="max-w-3xl">{disclosure(@page)}</.text>
      <.text :if={@page.profile.kind == :persona} id="curator-not" class="max-w-3xl text-sm/7">
        An AI selection lens. It is not the person, it does not speak in their voice, and it is
        not a fact-checker: it chooses among records the page already has, and writes only a
        short reason for each choice. This page keeps four layers apart: the model's inherited
        knowledge, the dossier we authored, the instruction and context supplied, and the
        recorded result.
      </.text>
      <.text :if={@page.profile.kind != :persona} id="curator-not" class="max-w-3xl text-sm/7">
        An AI editor. It is modelled on no one and is not a fact-checker: it chooses among
        records the page already has, and writes only a short reason for each choice. This page
        keeps four layers apart: the model's inherited knowledge, what we gave it, the
        instruction and context supplied, and the recorded result.
      </.text>

      <p :if={@page.profile.kind == :persona} id="curator-subject" class="text-sm/7">
        Subject: {@page.subject.label}
        <span :if={@page.subject.path}>
          ·
          <.link navigate={@page.subject.path} class="underline underline-offset-4">their entry on this site</.link>
        </span>
        <span :if={is_nil(@page.subject.path)}>
          · no entry on this site yet<span :for={ref <- @page.subject.deceased_evidence}><span :if={
            ref.url
          }>
            ·
            <a href={ref.url} rel="noopener" target="_blank" class="underline underline-offset-4">{ref.authority ||
              "authority record"} ↗</a>
          </span></span>
        </span>
      </p>

      <p :if={@action == :show} id="curator-now" class="text-sm/7">{now_line(@page)}</p>
    </header>
    """
  end

  # ── what it did (layer 4) ────────────────────────────────────────────────

  attr :page, :map, required: true
  attr :visible, :integer, required: true
  attr :withheld, :any, default: nil
  attr :class, :string, default: nil

  defp did(assigns) do
    ~H"""
    <section id="curator-did" class={["flex min-w-0 flex-col gap-4", @class]}>
      <.layer title="What it did" label="The recorded result">
        What the system recorded: each call's outcome, the versions it wrote and what was
        published. A recorded reason is a reported reason, not a trace of how the model reached
        it, and not evidence that the writer would agree.
      </.layer>

      <p :if={@page.activity == []} id="curator-no-activity" class="text-base/7">
        Not yet used on any page.
      </p>

      <div :if={@page.activity != []} id="curator-totals" class="flex flex-col gap-1 text-sm/7">
        <p>
          {plural(@page.totals.calls, "model call")} · {@page.totals.accepted} accepted · {@page.totals.abstained} abstained · {@page.totals.refused} refused<span :if={
            @page.totals.other > 0
          }> · {@page.totals.other} other</span>
        </p>
        <p>
          {plural(@page.totals.pages, "page")} published · {plural(
            @page.totals.publications,
            "publication"
          )} · {plural(@page.totals.placed, "choice")} placed · {@page.totals.expired} later withheld because the cited observation expired<span :if={
            @page.totals.withdrawals > 0
          }> · {plural(@page.totals.withdrawals, "withdrawal")} by a reviewer</span>
        </p>
        <.async_result :let={withheld} :if={@withheld} assign={@withheld}>
          <:loading>
            <p id="curator-withheld-loading">Checking what the current pages withhold now…</p>
            <noscript>
              <p id="curator-withheld-noscript">
                Counting what the current pages withhold now needs JavaScript. Every other
                figure on this page is complete without it.
              </p>
            </noscript>
          </:loading>
          <:failed>
            <p id="curator-withheld-failed">What the current pages withhold now could not be read.</p>
          </:failed>
          <p :if={withheld.pages == %{} and withheld.choices == %{}} id="curator-withheld-now">
            Nothing is withheld on the current pages now.
          </p>
          <p :if={withheld.pages != %{} or withheld.choices != %{}} id="curator-withheld-now">
            Withheld on the current pages now:
            <span :for={{reasons, count} <- by_count(withheld.pages)}>
              {plural(count, "page")} withheld whole, {each(count)} {Opening.withheld_reason(reasons)};
            </span>
            <span :for={{reason, count} <- by_count(withheld.choices)}>
              {plural(count, "choice")} withheld on a page that is shown, {each(count)} {Opening.withheld_reason(
                reason
              )};
            </span>
          </p>
        </.async_result>
        <p :if={@page.holds != []} id="curator-holds">
          Held by the owner now:
          <span :for={hold <- @page.holds}>{hold.page} since {stamp(hold.since)}; </span>
          earlier holds are not recorded.
        </p>
      </div>

      <ol
        :if={@page.activity != []}
        id="curator-activity"
        class="flex min-w-0 flex-col divide-y divide-mist-950/10 dark:divide-white/10"
      >
        <.entry :for={entry <- Enum.take(@page.activity, @visible)} entry={entry} page={@page} />
      </ol>
      <details :if={length(@page.activity) > @visible} id="curator-activity-more" class="min-w-0">
        <summary class="cursor-pointer text-sm/7 underline underline-offset-4">
          Show all {length(@page.activity)} entries
        </summary>
        <ol class="flex min-w-0 flex-col divide-y divide-mist-950/10 dark:divide-white/10">
          <.entry :for={entry <- Enum.drop(@page.activity, @visible)} entry={entry} page={@page} />
        </ol>
      </details>
    </section>
    """
  end

  attr :entry, :map, required: true
  attr :page, :map, required: true

  defp entry(%{entry: %{kind: :withdrawal}} = assigns) do
    ~H"""
    <li class="flex min-w-0 flex-wrap gap-x-3 gap-y-1 py-2 text-sm/7">
      <span class="tabular-nums text-mist-600 dark:text-mist-400">{stamp(@entry.at)}</span>
      <.page_link page={@entry.page} />
      <span>version {@entry.version} withdrawn by a reviewer: {@entry.reason}</span>
    </li>
    """
  end

  defp entry(assigns) do
    assigns = assign(assigns, :binding, binding(assigns.page, assigns.entry.binding_id))

    ~H"""
    <li
      id={"curator-attempt-#{@entry.attempt_id}"}
      class="flex min-w-0 flex-wrap gap-x-3 gap-y-1 py-2 text-sm/7"
    >
      <span class="tabular-nums text-mist-600 dark:text-mist-400">{stamp(@entry.at)}</span>
      <.page_link page={@entry.page} />
      <span>{outcome(@entry)}</span>
      <span class="text-mist-600 dark:text-mist-400">attempt {@entry.attempt_id}</span>
      <span :if={@binding} class="text-mist-600 dark:text-mist-400">
        {instruction_of(@binding)}
      </span>
      <.link
        :if={@entry.published? and @entry.page}
        navigate={~p"/on/#{@entry.page}/receipt/#{@entry.version}"}
        class="underline underline-offset-4"
      >receipt</.link>
    </li>
    """
  end

  attr :page, :string, default: nil

  defp page_link(%{page: nil} = assigns), do: ~H""

  defp page_link(assigns) do
    ~H"""
    <.link navigate={~p"/on/#{@page}"} class="font-medium underline underline-offset-4">{@page}</.link>
    """
  end

  # ── what we gave it (layer 2) ─────────────────────────────────────────────

  attr :page, :map, required: true

  defp gave(assigns) do
    ~H"""
    <section id="curator-gave" class="flex min-w-0 flex-col gap-4">
      <.layer
        :if={@page.profile.kind == :persona}
        title="What we gave it"
        label="The dossier we authored"
      >
        Our interpretation of the writer's work, written and reviewed by us: not a
        reconstruction of their beliefs. Quoted passages are the source's words, marked with who
        speaks them; everything else on this page is ours.
      </.layer>
      <.layer
        :if={@page.profile.kind != :persona}
        title="What we gave it"
        label="No dossier, by design"
      >
        Nothing beyond the shared editorial rules: no dossier, no sources and no persona. What it
        is told is the instruction below.
      </.layer>

      <p :if={is_nil(@page.dossier)} id="curator-no-dossier" class="text-base/7">
        No dossier has been admitted for this curator.
      </p>
      <p
        :if={@page.dossier && @page.dossier.empty? && @page.profile.kind == :generic_editor}
        id="curator-no-dossier"
        class="text-base/7"
      >
        None, by design: the generic editor has no persona, no dossier and no sources. It is the
        control the personas are compared with.
      </p>

      <dl
        :if={@page.dossier && not @page.dossier.empty?}
        id="curator-dossier"
        class="flex min-w-0 flex-col gap-4 text-sm/7"
      >
        <div
          :for={{key, label} <- dossier_fields()}
          :if={@page.dossier.fields[key] not in [nil, "", []]}
        >
          <dt class="font-medium text-mist-950 dark:text-white">{label}</dt>
          <dd :if={is_binary(@page.dossier.fields[key])}>{@page.dossier.fields[key]}</dd>
          <dd :if={is_list(@page.dossier.fields[key])}>
            <ul class="list-[square] pl-5">
              <li :for={line <- @page.dossier.fields[key]}>{line}</li>
            </ul>
          </dd>
        </div>
      </dl>

      <div
        :if={@page.dossier && @page.dossier.sources != []}
        id="curator-sources"
        class="flex min-w-0 flex-col gap-4"
      >
        <h3 class="text-base/8 font-medium text-mist-950 dark:text-white">Sources</h3>
        <article
          :for={{source, i} <- Enum.with_index(@page.dossier.sources, 1)}
          id={"curator-source-#{i}"}
          class="flex min-w-0 flex-col gap-2 rounded-xl bg-mist-950/2.5 p-4 text-sm/7 dark:bg-white/5"
        >
          <p class="font-medium text-mist-950 dark:text-white">
            <a
              :if={source.url}
              href={source.url}
              rel="noopener"
              target="_blank"
              class="underline underline-offset-4"
            >{source.work} ↗</a>
            <span :if={is_nil(source.url)}>{source.work}</span>
          </p>
          <p :if={source.edition}>{source.edition}</p>
          <p :if={source.locators != []}>Read at: {Enum.join(source.locators, "; ")}.</p>
          <p :if={source.basis}>Why: {source.basis}</p>
          <p :if={source.rights}>Rights: {source.rights}</p>
          <ul :if={source.passages != []} class="flex flex-col gap-2">
            <li
              :for={passage <- source.passages}
              class="border-l-2 border-mist-300 pl-3 dark:border-mist-700"
            >
              <q :if={source.passages_shown? and passage["text"]} class="italic">{passage["text"]}</q>
              <span :if={not source.passages_shown?}>A passage is cited here; its rights note does not permit showing it.</span>
              <span class="block text-mist-600 dark:text-mist-400">
                {passage["locator"]} · speaker: {passage["speaker"]}
              </span>
            </li>
          </ul>
        </article>
      </div>

      <div
        :if={@page.dossier && @page.dossier.deceased_evidence != []}
        id="curator-deceased"
        class="text-sm/7"
      >
        <h3 class="text-base/8 font-medium text-mist-950 dark:text-white">
          Evidence the subject has died
        </h3>
        <p :for={ref <- @page.dossier.deceased_evidence}>
          <a
            :if={ref.url}
            href={ref.url}
            rel="noopener"
            target="_blank"
            class="underline underline-offset-4"
          >{ref.authority} ↗</a>
          <span :if={is_nil(ref.url)}>{ref.authority}</span>
          <span :if={ref.field}>· {ref.field}: {ref.value}</span>
        </p>
      </div>
    </section>
    """
  end

  # ── what runs it (layer 1) ───────────────────────────────────────────────

  attr :page, :map, required: true
  attr :action, :atom, required: true

  defp runs(assigns) do
    assigns = assign(assigns, :shown, shown_bindings(assigns.page, assigns.action))

    ~H"""
    <section id="curator-runs" class="flex min-w-0 flex-col gap-4">
      <.layer title="What runs it" label="Inherited model knowledge">
        A pretrained model's general knowledge, which we cannot enumerate: we do not know what it
        learned about anyone, or which training text shaped an answer, and training details we
        do not have are unknown, not inferred. No fine-tuning.
      </.layer>

      <p :if={@shown == []} id="curator-no-binding" class="text-base/7">
        No model has been bound to {if @action == :version, do: "this version", else: "this curator"}.
      </p>

      <article
        :for={binding <- @shown}
        id={binding.anchor}
        class="flex min-w-0 flex-col gap-2 rounded-xl bg-mist-950/2.5 p-4 text-sm/7 dark:bg-white/5"
      >
        <p class="font-medium break-words text-mist-950 dark:text-white">{binding.bot_actor.label}</p>
        <p>{windows(binding)}</p>
        <.model_config :if={binding.model_config} config={binding.model_config} />
      </article>
    </section>
    """
  end

  attr :config, :map, required: true

  defp model_config(assigns) do
    ~H"""
    <dl class="grid min-w-0 grid-cols-1 gap-x-4 sm:grid-cols-[9rem_1fr]">
      <dt class="font-medium">Model</dt>
      <dd>
        {join([
          @config.model_name,
          @config.family,
          @config.parameter_size,
          @config.quantization,
          @config.format
        ])}
      </dd>
      <dt class="font-medium">Runtime</dt>
      <dd>{@config.runtime} {@config.runtime_version}</dd>
      <dt class="font-medium">Settings</dt>
      <dd>{generation(@config.generation)}</dd>
      <dt class="font-medium">Licence</dt>
      <dd>{@config.license_name || "not recorded"} · no fine-tuning · model card not recorded</dd>
      <dt class="font-medium">Artifact</dt>
      <dd class="font-mono text-xs/6 break-all">{@config.manifest_digest}</dd>
      <dt class="font-medium">Weights</dt>
      <dd class="font-mono text-xs/6 break-all">{@config.weights_digest}</dd>
      <dt class="font-medium">Instruction</dt>
      <dd>{@config.instruction_version} · output contract {@config.output_contract_version}</dd>
      <dt class="font-medium">Config</dt>
      <dd class="font-mono text-xs/6 break-all">{@config.slug} · {@config.config_hash}</dd>
    </dl>
    """
  end

  # The bindings a page shows: on a version page, those that bound it; on
  # the profile page, all of them, newest first.
  defp shown_bindings(page, :version), do: Enum.reverse(page.used_by.bindings)
  defp shown_bindings(page, _action), do: Enum.reverse(page.bindings)

  # ── what it is told (layer 3) ────────────────────────────────────────────

  attr :page, :map, required: true

  defp told(assigns) do
    ~H"""
    <section id="curator-told" class="flex min-w-0 flex-col gap-4">
      <.layer title="What it is told" label="The instruction and context supplied">
        A reviewed public summary of the pinned instruction, not the prompt itself. Each call is
        given one bounded packet of the page's own eligible records (identifiers, meanings and
        short excerpts or labels); it contains no earlier answers, and nothing is remembered
        between calls.
      </.layer>

      <p :if={is_nil(@page.instruction)} class="text-base/7">No instruction has been pinned.</p>

      <div
        :if={@page.instruction}
        id="curator-instruction"
        class="flex min-w-0 flex-col gap-3 text-sm/7"
      >
        <p>
          <span class="font-medium text-mist-950 dark:text-white">{@page.instruction.version}</span>
          <span :if={@page.instruction.sha256}>
            · sha256 <span class="font-mono text-xs/6 break-all">{@page.instruction.sha256}</span>
          </span>
        </p>
        <.summary :if={@page.instruction.summary} text={@page.instruction.summary} />
        <p :if={is_nil(@page.instruction.summary)}>
          No reviewed summary of this instruction exists yet.
        </p>
      </div>
    </section>
    """
  end

  attr :text, :string, required: true

  # The reviewed summaries are a small subset of Markdown: one `#` title,
  # paragraphs and `-` bullets. Rendered as escaped text, never as HTML.
  defp summary(assigns) do
    assigns = assign(assigns, :blocks, blocks(assigns.text))

    ~H"""
    <div class="flex min-w-0 flex-col gap-2">
      <%= for block <- @blocks do %>
        <p :if={elem(block, 0) == :title} class="font-medium text-mist-950 dark:text-white">
          {elem(block, 1)}
        </p>
        <p :if={elem(block, 0) == :para}>{elem(block, 1)}</p>
        <ul :if={elem(block, 0) == :list} class="list-[square] pl-5">
          <li :for={line <- elem(block, 1)}>{line}</li>
        </ul>
      <% end %>
    </div>
    """
  end

  @doc false
  def blocks(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.chunk_by(&block_kind/1)
    |> Enum.flat_map(fn [first | _] = lines ->
      case block_kind(first) do
        :blank -> []
        :title -> Enum.map(lines, &{:title, String.trim_leading(&1, "# ")})
        :item -> [{:list, Enum.map(lines, &String.trim_leading(&1, "- "))}]
        :para -> [{:para, Enum.join(lines, " ")}]
      end
    end)
  end

  defp block_kind(""), do: :blank
  defp block_kind("# " <> _), do: :title
  defp block_kind("- " <> _), do: :item
  defp block_kind(_), do: :para

  # ── cost ─────────────────────────────────────────────────────────────────

  attr :page, :map, required: true
  attr :class, :string, default: nil

  defp cost(assigns) do
    ~H"""
    <section id="curator-cost" class={["flex min-w-0 flex-col gap-4", @class]}>
      <div class="flex flex-col gap-1">
        <.eyebrow>Cost</.eyebrow>
        <h2 class="font-display text-[2rem]/10 text-mist-950 dark:text-white">What it cost</h2>
        <.text class="text-sm/7">
          Calls, time and tokens on the local model, and the share of the daily inference budget
          each call was charged. No money figures: none is recorded.
        </.text>
      </div>
      <p :if={@page.totals.calls == 0} class="text-base/7">Nothing yet.</p>
      <ul :if={@page.totals.calls > 0} class="flex min-w-0 flex-col gap-3 text-sm/7">
        <li
          :for={b <- Enum.reverse(@page.bindings)}
          :if={b.totals.calls > 0}
          id={"curator-cost-#{b.bot_actor.id}"}
          class="min-w-0"
        >
          <span class="font-medium text-mist-950 dark:text-white">{instruction_of(b)}</span>: {cost_line(
            b.totals
          )}
        </li>
        <li
          id="curator-cost-total"
          class="min-w-0 border-t border-mist-950/10 pt-3 dark:border-white/10"
        >
          <span class="font-medium text-mist-950 dark:text-white">All bindings</span>: {cost_line(
            @page.totals
          )}
        </li>
      </ul>
    </section>
    """
  end

  # ── judged ───────────────────────────────────────────────────────────────

  attr :page, :map, required: true
  attr :class, :string, default: nil

  defp judged(assigns) do
    ~H"""
    <section id="curator-judged" class={["flex min-w-0 flex-col gap-4", @class]}>
      <div class="flex flex-col gap-1">
        <.eyebrow>Judged</.eyebrow>
        <h2 class="font-display text-[2rem]/10 text-mist-950 dark:text-white">
          How it has been judged
        </h2>
        <.text class="text-sm/7">
          Dated developer judgments against a frozen scorecard: not independent review.
        </.text>
      </div>
      <p :if={@page.judgments == []} class="text-base/7">No dated judgment has been recorded.</p>
      <ul :if={@page.judgments != []} class="flex min-w-0 flex-col gap-3 text-sm/7">
        <li :for={j <- @page.judgments} class="min-w-0">
          <span class="font-medium text-mist-950 dark:text-white">{j["date"]} · {j["title"]}</span>
          · {j["instruction_version"]}:
          <span :if={j["useful_pages"]} class="font-medium">
            {useful(j["useful_pages"])};
          </span>
          {j["meanings"]["supported"]} supported, {j["meanings"]["insufficient"]} insufficient and {j[
            "meanings"
          ]["wrong"]} wrong of {plural(j["choices"], "choice")}; {plural(
            j["reasons"]["unsupported"],
            "unsupported or misattributed reason"
          )} · <strong>{j["verdict"]}</strong>
          ·
          <a href={j["report"]} rel="noopener" target="_blank" class="underline underline-offset-4">report ↗</a>
        </li>
      </ul>
    </section>
    """
  end

  # ── versions ─────────────────────────────────────────────────────────────

  attr :page, :map, required: true
  attr :class, :string, default: nil

  defp versions(assigns) do
    ~H"""
    <section id="curator-versions" class={["flex min-w-0 flex-col gap-4", @class]}>
      <div class="flex flex-col gap-1">
        <.eyebrow>Versions</.eyebrow>
        <h2 class="font-display text-[2rem]/10 text-mist-950 dark:text-white">Every version</h2>
        <.text class="text-sm/7">
          Each version is immutable. A receipt links to the version that made its choices, never
          to today's.
        </.text>
      </div>
      <p :if={@page.versions == []} class="text-base/7">No version has been recorded.</p>
      <ol
        :if={@page.versions != []}
        class="flex min-w-0 flex-col divide-y divide-mist-950/10 dark:divide-white/10"
      >
        <li
          :for={row <- Enum.reverse(@page.versions)}
          id={"curator-version-#{row.version.version}"}
          class="flex min-w-0 flex-col gap-1 py-3 text-sm/7"
        >
          <p class="flex flex-wrap gap-x-3">
            <.link
              navigate={~p"/curators/#{@page.profile.slug}/v/#{row.version.version}"}
              class="font-medium underline underline-offset-4"
            >Version {row.version.version}</.link>
            <span>{row.version.template_version}</span>
            <span :if={row.version.id == @page.current_version_id} class="font-semibold">current</span>
          </p>
          <p>
            Recorded {stamp(row.version.inserted_at)} by {actor(row.created_by)}: {row.version.change_reason}
          </p>
          <p :if={row.version.id == @page.current_version_id and @page.admission}>
            Admitted {stamp(@page.admission.at)} by {actor(@page.admission.by)}: {@page.admission.reason}
          </p>
          <p>
            {if row.first_active, do: "First active #{stamp(row.first_active)}", else: "Never active"} · {plural(
              length(row.bindings),
              "binding"
            )} · {plural(row.publications, "publication")} on {plural(row.pages, "page")}
          </p>
          <p class="font-mono text-xs/6 break-all text-mist-600 dark:text-mist-400">
            {row.version.manifest_hash}
          </p>
        </li>
      </ol>
    </section>
    """
  end

  # ── a version's users ────────────────────────────────────────────────────

  attr :page, :map, required: true
  attr :class, :string, default: nil

  defp used_by(assigns) do
    ~H"""
    <section id="curator-used-by" class={["flex min-w-0 flex-col gap-4", @class]}>
      <.layer title="Used by" label="The recorded result">
        The bindings that ran this version and the page versions they published. Each receipt
        resolves to this version for as long as it exists.
      </.layer>
      <nav class="flex flex-wrap gap-4 text-sm/7" aria-label="Versions">
        <.link
          :if={@page.version.version > 1}
          navigate={~p"/curators/#{@page.profile.slug}/v/#{@page.version.version - 1}"}
          class="underline underline-offset-4"
        >← version {@page.version.version - 1}</.link>
        <.link
          :if={@page.latest_version && @page.version.version < @page.latest_version.version}
          navigate={~p"/curators/#{@page.profile.slug}/v/#{@page.version.version + 1}"}
          class="underline underline-offset-4"
        >version {@page.version.version + 1} →</.link>
        <.link navigate={~p"/curators/#{@page.profile.slug}"} class="underline underline-offset-4">
          the curator now
        </.link>
      </nav>
      <p :if={@page.used_by.published == []} class="text-base/7">
        No page was published under this version.
      </p>
      <ol
        :if={@page.used_by.published != []}
        id="curator-version-published"
        class="flex min-w-0 flex-col divide-y divide-mist-950/10 dark:divide-white/10"
      >
        <li
          :for={row <- @page.used_by.published}
          class="flex min-w-0 flex-wrap gap-x-3 gap-y-1 py-2 text-sm/7"
        >
          <span class="tabular-nums text-mist-600 dark:text-mist-400">{stamp(row.at)}</span>
          <.page_link page={row.page} />
          <span>published version {row.version}</span>
          <span class="text-mist-600 dark:text-mist-400">attempt {row.attempt_id}</span>
          <.link
            :if={row.page}
            navigate={~p"/on/#{row.page}/receipt/#{row.version}"}
            class="underline underline-offset-4"
          >receipt</.link>
        </li>
      </ol>
    </section>
    """
  end

  # ── shared ───────────────────────────────────────────────────────────────

  attr :title, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp layer(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <.eyebrow class="layer-label">{@label}</.eyebrow>
      <h2 class="font-display text-[2rem]/10 text-mist-950 dark:text-white">{@title}</h2>
      <.text class="text-sm/7">{render_slot(@inner_block)}</.text>
    </div>
    """
  end

  # A trial's main ground, first: how many of its pages got a useful entry.
  defp useful(%{"useful" => 1, "pages" => pages}), do: "1 useful entry of #{pages} pages"
  defp useful(%{"useful" => n, "pages" => pages}), do: "#{n} useful entries of #{pages} pages"

  # The reasons are singular ("its configuration has changed"), so a count
  # of more than one reads "each because".
  defp each(1), do: "because"
  defp each(_count), do: "each because"

  defp by_count(counts), do: Enum.sort_by(counts, &{-elem(&1, 1), inspect(elem(&1, 0))})

  defp admitted(cards), do: Enum.filter(cards, &(&1.profile.state == :admitted))
  defp proposed(cards), do: Enum.filter(cards, &(&1.profile.state == :proposed))
  defp retired(cards), do: Enum.filter(cards, &(&1.profile.state == :retired))

  defp state_label(state), do: state |> to_string() |> String.upcase()

  defp disclosure(%{profile: %{state: :proposed} = p}),
    do:
      "A proposed AI selection lens inspired by #{p.subject_label}. Not yet used on any page: no dossier has been admitted and no model is bound."

  defp disclosure(%{profile: %{kind: :generic_editor}}),
    do:
      "An AI editor with no persona: it applies the editorial rules alone, as the control the personas are compared with."

  defp disclosure(%{dossier: %{fields: %{"disclosure" => text}}}) when is_binary(text), do: text

  defp disclosure(%{profile: p}), do: "An AI selection lens inspired by #{p.subject_label}."

  defp now_line(%{current_binding: nil, profile: %{state: :admitted}} = page),
    do: "#{version_line(page.version)} · not bound in the current configuration."

  defp now_line(%{current_binding: nil}), do: "No model is bound."

  defp now_line(%{current_binding: b} = page) do
    config = b.model_config
    since = b.windows |> Enum.filter(&is_nil(&1.until)) |> Enum.map(& &1.from) |> List.first()

    "Now: #{version_line(page.version)}" <>
      if(config, do: " · #{config.model_name} #{config.quantization}", else: "") <>
      if(since, do: " · since #{stamp(since)}", else: "") <>
      if(b.editor_on?, do: " · switched on", else: " · switched off")
  end

  defp version_status(%{version: v, latest_version: latest, current_version_id: current}) do
    cond do
      v.id == current -> "Version #{v.version} of #{latest.version}: the current version."
      v.version < latest.version -> "Version #{v.version} of #{latest.version}: superseded."
      true -> "Version #{v.version} of #{latest.version}: not admitted."
    end
  end

  defp version_line(nil), do: "no version"
  defp version_line(v), do: "version #{v.version} · #{v.template_version}"

  defp windows(%{windows: []}), do: "Never active."

  defp windows(%{windows: windows}) do
    Enum.map_join(windows, "; ", fn w ->
      "Active #{stamp(w.from)} – #{if w.until, do: stamp(w.until), else: "now"}"
    end) <> "."
  end

  defp generation(%{} = g) do
    [
      g["seed"] && "seed #{g["seed"]}",
      g["temperature"] != nil && "temperature #{g["temperature"]}",
      g["num_ctx"] && "#{number(g["num_ctx"])} context tokens",
      g["num_predict"] && "#{number(g["num_predict"])} output tokens",
      g["think"] == false && "thinking off"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp generation(_), do: "not recorded"

  defp join(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")

  defp binding(page, id), do: id && Enum.find(page.bindings, &(&1.bot_actor.id == id))

  defp instruction_of(%{model_config: %{instruction_version: v, slug: slug}}),
    do: "#{v} · #{slug}"

  defp instruction_of(%{bot_actor: actor}), do: actor.label

  defp outcome(%{purpose: :readiness_smoke} = e),
    do: "readiness check, #{human(e.outcome)}, no page"

  defp outcome(%{purpose: :benchmark} = e), do: "benchmark, #{human(e.outcome)}, no page"
  defp outcome(%{page: nil} = e), do: "rehearsal, #{human(e.outcome)}, not published"
  defp outcome(%{outcome: :accepted, published?: true} = e), do: "published version #{e.version}"

  defp outcome(%{outcome: :accepted, version: n}) when is_integer(n),
    do: "wrote version #{n}, not published"

  defp outcome(%{outcome: :accepted}), do: "accepted, no new version written"
  defp outcome(%{outcome: :abstained}), do: "abstained"

  defp outcome(%{outcome: :refused, refusal_codes: codes}),
    do:
      "refused by the output check" <>
        if(codes == [], do: "", else: ": " <> Enum.map_join(codes, ", ", &human/1))

  defp outcome(e), do: human(e.outcome || e.state)

  defp cost_line(t) do
    [
      plural(t.calls, "call"),
      "#{duration(t.wall_ms)} inference",
      "#{number(t.prompt_tokens)} prompt and #{number(t.output_tokens)} output tokens",
      "#{duration(t.charged_ms)} of daily budget charged",
      t.lowest_free_percent && "lowest free memory #{t.lowest_free_percent}%",
      t.most_swap_bytes && "swap #{swap(t.most_swap_bytes)}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp swap(0), do: "none"
  defp swap(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp duration(nil), do: "0 s"

  defp duration(ms) when is_integer(ms) do
    seconds = div(ms + 500, 1000)

    cond do
      seconds < 60 -> "#{seconds} s"
      seconds < 3600 -> "#{div(seconds, 60)} m #{rem(seconds, 60)} s"
      true -> "#{div(seconds, 3600)} h #{div(rem(seconds, 3600), 60)} m"
    end
  end

  defp dossier_fields do
    [
      {"selection", "Selection rule"},
      {"principles", "Principles"},
      {"blind_spots", "Blind spots"},
      {"positive_example", "A choice it should make"},
      {"negative_example", "A choice it should refuse"}
    ]
  end

  defp actor(nil), do: "an actor not recorded"
  defp actor(%{kind: :reviewer, id: id}), do: "a reviewer (actor #{id})"
  defp actor(%{kind: :bot, label: label}), do: label
  defp actor(%{kind: kind, id: id}), do: "#{human(kind)} actor #{id}"

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{number(n)} #{word}s"

  defp human(nil), do: "not recorded"
  defp human(value), do: value |> to_string() |> String.replace("_", " ")

  defp date(nil), do: "not recorded"
  defp date(at), do: Calendar.strftime(at, "%-d %b %Y")

  defp stamp(nil), do: "not recorded"
  defp stamp(at), do: Calendar.strftime(at, "%-d %b %Y %H:%M UTC")
end
