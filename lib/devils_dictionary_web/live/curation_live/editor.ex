defmodule DevilsDictionaryWeb.CurationLive.Editor do
  @moduledoc """
  The owner's curation editor, `/ops/curation/on/:slug` (#257 §2.2, §2.4,
  §2.6; #253 §6, §6a).

  **The scope is the page's words**, shown and never typed: the On page the
  slug addresses, built as the reader builds it, and its
  `page.headword.lexemes` (`CurationLive.page/1`). A composition is
  `:lexical_page` over them; the exact-word pages overlap it and share it
  (K3), and the editor says so and offers nothing else.

  **Left, the candidates** (`Curation.Candidates`): the lead, as the lead rule
  decides it, and up to three highlights from the four kinds the record
  admits, each with a reason of at most 280 characters. **Right, the
  preview** (`Curation.Preview`): the unsaved selection drawn by the public
  component, `DevilsDictionaryWeb.Opening`, as the page would show it.

  The rules hold as the form changes, not on submit: a Bierce entry on the
  page disables every other lead ("Bierce leads"); a fourth highlight
  cannot be ticked; an empty reason blocks Publish and not Save draft; and
  anything the record or the page would refuse is listed in the record's
  own words (`Preview`'s problems), and blocks both.

  **Writes are the record's own services**, as the signed-in reviewer
  (`Curation.Authority`):

    * *Save draft*: `Compositions.provision/3` the first time, then
      `create_version/3` from the version this form was opened on
      (`:expected_parent`). Notes are the reviewer's, attributed by the
      record; the form names no author;
    * *Publish*: the version (the latest, when the form still holds it),
      then `Reviews.decide/4` accepting it and `Publications.publish/3` from
      the pointer this form saw, in one transaction. A version or pointer
      that moved since is *not current*: the form says so and writes
      nothing;
    * *Withdraw*: `Publications.withdraw/3` from the pointer this form saw,
      with a reason. Withdrawal keeps the page empty (#253 §6a);
    * *Re-open*: opens the form again on a withdrawn page. It writes
      nothing: the refresh state it will clear is #254 P5's.

  No job is queued, nothing is fetched and no model is called.
  """
  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Curation.{
    Candidates,
    Compositions,
    Preview,
    Publications,
    Reviews,
    Standing
  }

  alias DevilsDictionary.Repo
  alias DevilsDictionaryWeb.{CurationLive, Opening}

  on_mount {DevilsDictionaryWeb.UserAuth, :require_reviewer}

  @note_max 280

  @groups [
    content: "Definitions",
    sense_quotation: "Sense quotations",
    work: "Catalog works",
    exemplar: "Accepted exemplars"
  ]

  # The page is built once the socket is up: the first paint is the header,
  # not a page build, a candidate listing and a preview done twice.
  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    socket =
      assign(socket,
        slug: slug,
        loaded?: false,
        reopened?: false,
        stale: nil,
        refusal: nil,
        notice: nil,
        withdraw_reason: "",
        me: Preview.author(socket.assigns.current_scope),
        page_title: "Curate · #{slug}"
      )

    {:ok, if(connected?(socket), do: load(socket), else: socket)}
  end

  # The page, its candidates and its record as they are now, and the form
  # opened on the latest version.
  defp load(socket) do
    page = CurationLive.page(socket.assigns.slug)

    socket
    |> assign(
      page: page,
      candidates: Candidates.for_page(page),
      loaded?: true,
      stale: nil,
      page_title: "Curate · #{page.headword.lemma || socket.assigns.slug}"
    )
    |> load_record()
    |> then(&assign(&1, :selection, initial_selection(&1.assigns)))
    |> preview()
  end

  # ── events ───────────────────────────────────────────────────────────────

  @impl true
  def handle_event("change", params, socket) do
    old = socket.assigns.selection
    socket = assign(socket, :selection, selection(form_of(params), socket.assigns))

    # A keystroke in the version's reason changes no item: the preview stands.
    if drawn(socket.assigns.selection) == drawn(old),
      do: {:noreply, refresh(socket)},
      else: {:noreply, preview(socket)}
  end

  def handle_event("submit", params, socket) do
    socket = socket |> assign(:selection, selection(form_of(params), socket.assigns)) |> preview()

    case params["action"] do
      "publish" -> {:noreply, publish(socket)}
      _draft -> {:noreply, save_draft(socket)}
    end
  end

  def handle_event("withdraw", params, socket) do
    reason =
      case params do
        %{"withdraw" => %{"reason" => reason}} when is_binary(reason) -> reason
        _other -> ""
      end

    {:noreply, withdraw(assign(socket, :withdraw_reason, reason))}
  end

  def handle_event("reload", _params, socket) do
    {:noreply, socket |> assign(reopened?: false, refusal: nil, notice: nil) |> load()}
  end

  def handle_event("reopen", _params, socket) do
    {:noreply,
     socket
     |> assign(reopened?: true, refusal: nil)
     |> assign(:notice, "Re-opened. Nothing was written: curate again and publish a new version.")
     |> preview()}
  end

  # ── the selection ────────────────────────────────────────────────────────

  defp form_of(%{"curation" => %{} = params}), do: params
  defp form_of(_params), do: %{}

  # What the preview is drawn from: the items and their words.
  defp drawn(sel),
    do: {sel.lead, sel.highlights, Map.take(sel.notes, sel.highlights), sel.lead_note}

  # What the form says, held to the screen's rules: a lead the rule admits,
  # the highlights in the order they were ticked, never more than the
  # configuration's limit and never the lead itself.
  defp selection(params, assigns) do
    old = assigns.selection
    candidates = assigns.candidates
    lead = if valid_lead?(params["lead"], candidates), do: params["lead"], else: old.lead

    ticked =
      params |> Map.get("highlights", []) |> List.wrap() |> Enum.reject(&(&1 in ["", nil]))

    highlights =
      (Enum.filter(old.highlights, &(&1 in ticked)) ++
         Enum.reject(ticked, &(&1 in old.highlights)))
      |> Enum.uniq()
      |> Enum.filter(&selectable?(&1, candidates, lead))
      |> Enum.take(max_highlights(assigns))

    notes =
      case params["notes"] do
        %{} = notes ->
          Map.merge(old.notes, for({k, v} <- notes, is_binary(v), into: %{}, do: {k, v}))

        _none ->
          old.notes
      end

    %{
      lead: lead,
      highlights: highlights,
      notes: notes,
      authors: old.authors,
      lead_note: text(params["lead_note"], old.lead_note),
      reason: text(params["reason"], old.reason)
    }
  end

  defp text(value, _old) when is_binary(value), do: value
  defp text(_value, old), do: old

  defp valid_lead?("none", %{no_lead: :ok}), do: true

  defp valid_lead?(key, candidates) when is_binary(key) do
    match?(%{lead: {:ok, _}}, Enum.find(candidates.leads, &(&1.key == key)))
  end

  defp valid_lead?(_key, _candidates), do: false

  defp selectable?(key, candidates, lead) do
    key != lead and match?(%{status: :ok}, Enum.find(candidates.highlights, &(&1.key == key)))
  end

  defp max_highlights(%{record: %{configuration_version: %{max_highlights: n}}}), do: n
  defp max_highlights(_assigns), do: DevilsDictionary.Curation.Opening.max_highlights()

  # The form opens on the latest version, so the owner edits what is there;
  # a page never curated opens on its Bierce entry, which is the only lead
  # the rule allows where there is one.
  defp initial_selection(%{record: %{latest: %{} = latest}, candidates: candidates}),
    do: version_selection(latest, candidates)

  defp initial_selection(%{candidates: candidates}) do
    lead =
      case Enum.find(candidates.leads, &match?({:ok, :priority_source}, &1.lead)) do
        %{key: key} -> key
        nil -> if candidates.no_lead == :ok, do: "none", else: nil
      end

    %{lead: lead, highlights: [], notes: %{}, authors: %{}, lead_note: "", reason: ""}
  end

  # A stored version as the form's selection: each item by its candidate's
  # key. An item that is no longer a candidate is left out, and the form is
  # then a new arrangement.
  defp version_selection(%{items: items}, candidates) do
    keyed = for item <- items, key = item_key(item, candidates), do: {item, key}
    lead = Enum.find(keyed, fn {item, _key} -> item.role == :lead end)

    %{
      lead:
        case lead do
          {_item, key} -> key
          nil -> if candidates.no_lead == :ok, do: "none", else: nil
        end,
      highlights:
        for(
          {item, key} <- Enum.sort_by(keyed, &elem(&1, 0).position),
          item.role == :highlight,
          do: key
        ),
      notes:
        for({item, key} <- keyed, item.role == :highlight, into: %{}, do: {key, item.note || ""}),
      # Who wrote each note carried from the version, by the label the record
      # signed it with: a new version signs every note as its own author's.
      authors:
        for(
          {item, key} <- keyed,
          is_binary(item.note_author_label),
          into: %{},
          do: {if(item.role == :lead, do: :lead, else: key), item.note_author_label}
        ),
      lead_note: (lead && elem(lead, 0).note) || "",
      reason: ""
    }
  end

  defp item_key(%{item_kind: :content, item_object_id: id}, candidates),
    do: known("content-#{id}", candidates)

  defp item_key(%{item_kind: :sense_quotation} = item, candidates) do
    "quotation:" <> n = item.locator || "quotation:"
    known("quotation-#{item.sense_revision_id}-#{n}", candidates)
  end

  defp item_key(%{item_kind: :work} = item, candidates) do
    Enum.find_value(candidates.highlights, fn
      %{kind: :work, spec: %{catalog: catalog}, key: key} ->
        if catalog.manifest == item.catalog_manifest and
             to_string(catalog.identity) == item.catalog_identity,
           do: key

      _other ->
        nil
    end)
  end

  defp item_key(%{item_kind: :exemplar, assertion_revision_id: id}, candidates),
    do: known("exemplar-#{id}", candidates)

  defp known(key, candidates), do: Candidates.find(candidates, key) && key

  # ── the preview and what would stop it ───────────────────────────────────

  defp preview(socket) do
    %{page: page, candidates: candidates, selection: sel, record: record} = socket.assigns

    lead =
      case sel.lead do
        key when is_binary(key) and key != "none" -> Candidates.find(candidates, key)
        _none -> nil
      end

    highlights =
      for key <- sel.highlights,
          candidate = Candidates.find(candidates, key),
          not is_nil(candidate),
          do: {candidate, sel.notes[key]}

    selection = %{lead: lead, lead_note: sel.lead_note, highlights: highlights}
    held = held(record, Preview.items(selection, socket.assigns.me))

    preview =
      Preview.build(page, candidates, selection, socket.assigns.current_scope,
        composition: record.composition,
        next_version: if(record.latest, do: record.latest.version.version + 1, else: 1),
        held: held && %{version: held.version, items: held.items, author: held.author}
      )

    socket
    |> assign(preview: preview, held: held)
    |> assign(:preview_key, :erlang.phash2({sel.lead, sel.highlights}))
    |> refresh()
  end

  # The blockers and the form, for a change that draws nothing new.
  defp refresh(socket) do
    socket
    |> assign(:blockers, blockers(socket.assigns, socket.assigns.preview))
    |> assign(:form, to_form(form_params(socket.assigns.selection), as: :curation))
  end

  # The fields that say what an item shows and why, and not who signed it:
  # two arrangements equal on these are one selection.
  @reference_fields ~w(role position item_kind item_object_id content_revision_id
                       sense_revision_id source_record_revision_id catalog_manifest
                       catalog_checksum catalog_identity locator words_sha256
                       meaning_sense_revision_id meaning_lexeme_id assertion_revision_id
                       note)a

  # The latest version, when the form holds exactly its references and words
  # and it still stands: Publish then publishes it, with its own notes and
  # their authors, rather than writing a copy. Anything else is a new version.
  defp held(%{latest: %{} = latest, composition: %{} = composition}, items) do
    if references(latest.items) == references(items) and stands?(latest.version, composition),
      do: latest
  end

  defp held(_record, _items), do: nil

  defp references(items) do
    items
    |> Enum.map(&Map.take(&1, @reference_fields))
    |> Enum.sort_by(&{to_string(&1.role), &1.position})
  end

  defp stands?(version, composition) do
    Standing.scope(version, composition) == :ok and Standing.configuration(version) == :ok and
      Standing.eligible(Standing.evaluate(version, composition), version) == :ok
  end

  defp form_params(sel),
    do: %{
      "lead" => sel.lead,
      "highlights" => sel.highlights,
      "notes" => sel.notes,
      "lead_note" => sel.lead_note,
      "reason" => sel.reason
    }

  # What stops each action, in the record's words. Both need a version
  # reason (the record requires one), something selected, and nothing the
  # record or the page would refuse; Publish also needs a reason for every
  # highlight.
  defp blockers(assigns, preview) do
    sel = assigns.selection

    common =
      List.flatten([
        if(assigns.stale, do: [:not_current], else: []),
        read_only(assigns),
        Enum.map(preview.problems, &problem/1),
        if(String.trim(sel.reason) == "", do: [{:required, :reason}], else: []),
        if(sel.lead in [nil, "none"] and sel.highlights == [], do: [:nothing_selected], else: []),
        for(
          {key, n} <- Enum.with_index(sel.highlights, 1),
          String.length(sel.notes[key] || "") > @note_max,
          do: {:note_too_long, n}
        ),
        if(String.length(sel.lead_note) > @note_max, do: [{:note_too_long, :lead}], else: [])
      ])

    notes =
      for {key, n} <- Enum.with_index(sel.highlights, 1),
          String.trim(sel.notes[key] || "") == "",
          do: {:reason_missing, n}

    published =
      if match?(%{version: %{id: id}} when id == assigns.record.published_id, assigns[:held]),
        do: [:already_published],
        else: []

    %{draft: common, publish: common ++ notes ++ published}
  end

  # A problem the preview found, by its place when it has one.
  defp problem(%{reason: reason, role: role, position: position})
       when is_atom(reason) and role in [:lead, :highlight],
       do: {reason, role, position}

  defp problem(%{reason: reason}), do: reason

  defp read_only(%{record: record, reopened?: reopened?, candidates: candidates}) do
    cond do
      record.state in [:unconfigured, :no_scope] -> [record.state]
      record.overlapping != [] -> [{:overlapping_scope, record.overlapping}]
      record.state == :withdrawn and not reopened? -> [:withdrawn]
      not Candidates.any?(candidates) -> [:nothing_to_cite]
      true -> []
    end
  end

  defp editable?(assigns), do: read_only(assigns) == []

  # ── actions ──────────────────────────────────────────────────────────────

  defp save_draft(%{assigns: %{blockers: %{draft: [_ | _] = blockers}}} = socket),
    do: assign(socket, refusal: hd(blockers), notice: nil)

  defp save_draft(socket) do
    %{current_scope: scope, selection: sel} = socket.assigns

    case write_version(socket.assigns, scope) do
      {:ok, version} ->
        socket
        |> after_write("Saved version #{version.version} as a draft. Nothing was published.")
        |> assign(:selection, %{sel | reason: ""})
        |> preview()

      {:error, reason} ->
        refused(socket, reason)
    end
  end

  defp publish(%{assigns: %{blockers: %{publish: [_ | _] = blockers}}} = socket),
    do: assign(socket, refusal: hd(blockers), notice: nil)

  # The version, its acceptance and its publication, in one transaction: a
  # version or a pointer that moved since this form was opened writes
  # nothing at all.
  defp publish(socket) do
    %{current_scope: scope, selection: sel, record: record, held: held} = socket.assigns

    result =
      atomically(fn ->
        with {:ok, version} <- publishable(socket.assigns, held, scope),
             {:ok, _review} <-
               Reviews.decide(scope, version.id, :accepted,
                 reason: sel.reason,
                 idempotency_key: key("review")
               ),
             {:ok, receipt} <-
               Publications.publish(scope, version.id,
                 reason: sel.reason,
                 idempotency_key: key("publish"),
                 expected_pointer: record.published_id
               ) do
          {:ok, {version, receipt}}
        end
      end)

    case result do
      {:ok, {version, receipt}} ->
        socket
        |> after_write(
          "Published version #{version.version} (receipt ##{receipt.id}). The page shows it on its next request."
        )
        |> assign(:selection, %{sel | reason: ""})
        |> preview()

      {:error, reason} ->
        refused(socket, reason)
    end
  end

  # The held version, while it is still the newest; otherwise a new one,
  # from the latest this form was opened on.
  defp publishable(_assigns, %{version: version}, _scope) do
    case Compositions.latest_version(version.composition_id) do
      %{id: id} when id == version.id -> {:ok, version}
      latest -> {:error, {:stale_parent, latest && latest.id}}
    end
  end

  defp publishable(assigns, nil, scope), do: write_version(assigns, scope)

  # A refusal is shown and nothing is reloaded. One that says another
  # reviewer moved the page also blocks every write until the owner reloads
  # and sees what they did.
  defp refused(socket, reason) do
    stale = if not_current?(reason), do: reason, else: socket.assigns.stale
    socket |> assign(refusal: reason, notice: nil, stale: stale) |> refresh()
  end

  defp withdraw(%{assigns: %{stale: stale}} = socket) when not is_nil(stale),
    do: assign(socket, refusal: :not_current, notice: nil)

  defp withdraw(socket) do
    %{current_scope: scope, record: record, withdraw_reason: reason} = socket.assigns

    result =
      case record do
        _record when reason == "" ->
          {:error, {:required, :withdraw_reason}}

        %{composition: %{id: id}, published_id: published} when is_integer(published) ->
          Publications.withdraw(scope, id,
            reason: reason,
            idempotency_key: key("withdraw"),
            expected_pointer: published
          )

        _unpublished ->
          {:error, :unpublished}
      end

    case result do
      {:ok, receipt} ->
        socket
        |> assign(reopened?: false, withdraw_reason: "")
        |> after_write(
          "Withdrawn (receipt ##{receipt.id}). The page shows no opening until it is re-opened and published again."
        )
        |> preview()

      {:error, reason} ->
        refused(socket, reason)
    end
  end

  defp blank(nil), do: nil

  defp blank(text) do
    case String.trim(text) do
      "" -> nil
      _text -> text
    end
  end

  # Provision the page's composition the first time, then write the version
  # from the latest this form saw. One transaction: a refused version leaves
  # no composition behind.
  defp write_version(assigns, scope) do
    %{record: record, candidates: candidates, selection: sel} = assigns

    atomically(fn ->
      with {:ok, composition} <- composition(record, candidates, scope, sel.reason) do
        Compositions.create_version(scope, composition.id, %{
          lead: lead_spec(sel, candidates),
          highlights: Enum.map(sel.highlights, &spec(candidates, &1, sel.notes[&1])),
          reason: sel.reason,
          expected_parent: record.latest && record.latest.version.id
        })
      end
    end)
  end

  defp composition(%{composition: %{} = composition}, _candidates, _scope, _reason),
    do: {:ok, composition}

  defp composition(%{overlapping: [_ | _] = ids}, _candidates, _scope, _reason),
    do: {:error, {:overlapping_scope, ids}}

  defp composition(record, candidates, scope, reason) do
    Compositions.provision(scope, record.configuration.id, %{
      scope_kind: :lexical_page,
      lexeme_ids: candidates.scope.ids,
      language_tag: candidates.scope.language,
      reason: reason
    })
  end

  defp atomically(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lead_spec(%{lead: key} = sel, candidates) when is_binary(key) and key != "none",
    do: spec(candidates, key, sel.lead_note)

  defp lead_spec(_sel, _candidates), do: nil

  # A candidate's item spec with the author's words, and nothing else: the
  # record attributes the note to whoever is signed in (K9).
  defp spec(candidates, key, note) do
    spec = Candidates.find(candidates, key).spec

    case blank(note) do
      nil -> spec
      text -> Map.put(spec, :note, %{text: text})
    end
  end

  defp key(action), do: "curation-screen:#{action}:#{Ecto.UUID.generate()}"

  defp after_write(socket, notice) do
    socket |> load_record() |> assign(refusal: nil, notice: notice)
  end

  defp load_record(socket),
    do: assign(socket, :record, CurationLive.record(socket.assigns.candidates))

  # ── rendering ────────────────────────────────────────────────────────────

  @impl true
  def render(%{loaded?: false} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.container>
        <div id="curation-editor" class="flex flex-col gap-4 py-10 sm:py-14">
          <h1 class="font-display text-4xl/12 text-mist-950 dark:text-white">On {@slug}</h1>
          <p id="curation-loading" class="text-sm/7 text-mist-500">Reading the page…</p>
        </div>
      </.container>
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:editable?, editable?(assigns))
      |> assign(:groups, @groups)
      |> assign(:max, max_highlights(assigns))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.container>
        <div id="curation-editor" class="flex flex-col gap-8 py-10 sm:py-14">
          <header class="flex flex-col gap-2">
            <.link
              id="curation-back"
              navigate={~p"/ops/curation"}
              class="flex min-h-11 w-fit items-center gap-1 rounded-sm text-sm/7 text-mist-600 hover:text-mist-950 sm:min-h-0 dark:text-mist-400 dark:hover:text-white"
            >
              <span aria-hidden="true">←</span> Curation
            </.link>
            <h1 class="font-display text-4xl/12 text-mist-950 dark:text-white">
              On {@page.headword.lemma || @slug}
            </h1>
            <p id="curation-scope" class="text-sm/7 text-pretty text-mist-700 dark:text-mist-300">
              <span class="font-medium text-mist-950 dark:text-white">Scope:</span>
              <%= if @candidates.scope.ids == [] do %>
                no words: this address names nothing to curate.
              <% else %>
                {scope_line(@candidates.scope)}
              <% end %>
            </p>
            <p id="curation-config" class="text-sm/7 text-mist-600 dark:text-mist-400">
              {config_line(@record)} ·
              <span id="curation-state-label">{CurationLive.state_label(@record)}</span>
            </p>
            <p id="curation-shared" class="max-w-3xl text-sm/7 text-pretty text-mist-500">
              Exact-word pages share this: their words overlap this page's, so they cannot
              have a composition of their own beside it, and show none.
            </p>
          </header>

          <.refusal :if={@refusal} refusal={@refusal} />
          <p
            :if={@notice}
            id="curation-notice"
            role="status"
            class="rounded-lg bg-emerald-50 px-4 py-3 text-sm/7 text-emerald-900 dark:bg-emerald-400/10 dark:text-emerald-200"
          >
            {@notice}
          </p>

          <.standing record={@record} reopened?={@reopened?} withdraw_reason={@withdraw_reason} />

          <p
            :if={not Candidates.any?(@candidates)}
            id="curation-nothing"
            class="rounded-xl border border-dashed border-mist-950/15 px-5 py-4 text-sm/7 text-pretty text-mist-700 dark:border-white/15 dark:text-mist-300"
          >
            Nothing the record can cite yet: this page has no entry that may lead, no sense
            quotation, no catalog work and no accepted exemplar. There is nothing to publish,
            and the public page stays as it is.
          </p>

          <div
            :if={Candidates.any?(@candidates)}
            class="grid grid-cols-1 gap-x-12 gap-y-10 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]"
          >
            <.form
              for={@form}
              id="curation-form"
              phx-change="change"
              phx-submit="submit"
              class="flex min-w-0 flex-col gap-10"
            >
              <fieldset
                id="curation-lead"
                disabled={not @editable?}
                class="flex min-w-0 flex-col gap-3"
              >
                <legend class="text-sm/7 font-semibold tracking-wide text-mist-950 uppercase dark:text-white">
                  Lead
                </legend>
                <p id="curation-bierce" class="text-sm/7 text-mist-600 dark:text-mist-400">
                  <%= if @candidates.bierce? do %>
                    Bierce leads: where The Devil’s Dictionary defines a word, only its entry may lead.
                  <% else %>
                    Bierce: no entry for this word. Another sourced definition may lead, chosen by hand, or none.
                  <% end %>
                </p>
                <p
                  :if={@candidates.leads == []}
                  id="curation-no-entries"
                  class="text-sm/7 text-mist-500"
                >
                  No entry on this page can lead: its dictionaries file senses, not entries.
                </p>
                <label
                  :for={c <- @candidates.leads}
                  id={"lead-#{c.key}"}
                  class={[
                    "flex min-h-11 gap-3 rounded-lg px-3 py-2 ring-1 ring-mist-950/10 ring-inset dark:ring-white/10",
                    match?({:ok, _}, c.lead) &&
                      "cursor-pointer hover:bg-mist-950/2.5 dark:hover:bg-white/5",
                    not match?({:ok, _}, c.lead) && "opacity-60"
                  ]}
                >
                  <input
                    type="radio"
                    name="curation[lead]"
                    value={c.key}
                    checked={@selection.lead == c.key}
                    disabled={not match?({:ok, _}, c.lead)}
                    class="mt-1 size-4 shrink-0"
                  />
                  <span class="flex min-w-0 flex-col">
                    <span class="text-sm/6 font-medium text-mist-950 dark:text-white">
                      {c.label}<span
                        :if={c.title}
                        class="font-normal text-mist-600 dark:text-mist-400"
                      > · {c.title}</span>
                    </span>
                    <span class="line-clamp-2 text-sm/6 text-pretty text-mist-700 dark:text-mist-300">
                      “{c.text}”
                    </span>
                    <span
                      :if={not match?({:ok, _}, c.lead)}
                      id={"lead-#{c.key}-verdict"}
                      class="text-sm/6 text-mist-500"
                    >
                      {lead_verdict(c.lead)}
                    </span>
                  </span>
                </label>
                <label
                  id="lead-none"
                  class={[
                    "flex min-h-11 items-center gap-3 rounded-lg px-3 py-2 ring-1 ring-mist-950/10 ring-inset dark:ring-white/10",
                    @candidates.no_lead != :ok && "opacity-60"
                  ]}
                >
                  <input
                    type="radio"
                    name="curation[lead]"
                    value="none"
                    checked={@selection.lead == "none"}
                    disabled={@candidates.no_lead != :ok}
                    class="size-4 shrink-0"
                  />
                  <span class="text-sm/6 text-mist-700 dark:text-mist-300">
                    No lead<span :if={@candidates.no_lead != :ok} class="text-mist-500"> · Bierce leads</span>
                  </span>
                </label>
                <.note_box
                  :if={@selection.lead not in [nil, "none"]}
                  id="lead-note"
                  name="curation[lead_note]"
                  label="Why this leads (optional: the rule above is its reason)"
                  value={@selection.lead_note}
                  author={@selection.authors[:lead]}
                  me={@me.label}
                />
              </fieldset>

              <fieldset
                id="curation-highlights"
                disabled={not @editable?}
                class="flex min-w-0 flex-col gap-6"
              >
                <legend class="text-sm/7 font-semibold tracking-wide text-mist-950 uppercase dark:text-white">
                  Highlights
                  <span
                    id="curation-highlight-count"
                    class="ml-2 font-normal tracking-normal text-mist-600 normal-case tabular-nums dark:text-mist-400"
                  >
                    {length(@selection.highlights)} of {@max}
                  </span>
                </legend>
                <input type="hidden" name="curation[highlights][]" value="" />

                <div
                  :for={{kind, title} <- @groups}
                  id={"group-#{kind}"}
                  class="flex min-w-0 flex-col gap-2"
                >
                  <h3 class="text-sm/7 font-medium text-mist-950 dark:text-white">
                    {title}
                    <span class="font-normal text-mist-500 tabular-nums">({length(
                      of_kind(@candidates, kind)
                    )})</span>
                  </h3>
                  <p
                    :if={of_kind(@candidates, kind) == []}
                    id={"group-#{kind}-empty"}
                    class="text-sm/6 text-pretty text-mist-500"
                  >
                    {empty_group(kind, @candidates)}
                  </p>
                  <% {shown, folded} = fold(of_kind(@candidates, kind), @selection) %>
                  <.candidate
                    :for={c <- shown}
                    candidate={c}
                    selection={@selection}
                    full?={length(@selection.highlights) >= @max}
                    position={position(@selection, c.key)}
                    me={@me.label}
                  />
                  <details
                    :if={folded != []}
                    id={"group-#{kind}-more"}
                    phx-mounted={JS.ignore_attributes(["open"])}
                    class="group/more"
                  >
                    <summary class="flex min-h-11 w-fit cursor-pointer list-none items-center gap-1 rounded-sm text-sm/7 text-mist-600 underline decoration-mist-950/20 underline-offset-4 hover:text-mist-950 sm:min-h-0 dark:text-mist-400 dark:hover:text-white [&::-webkit-details-marker]:hidden">
                      {length(folded)} more {String.downcase(title)}
                      <.icon name="hero-chevron-down-mini" class="size-4 group-open/more:rotate-180" />
                    </summary>
                    <div class="mt-2 flex flex-col gap-2">
                      <.candidate
                        :for={c <- folded}
                        candidate={c}
                        selection={@selection}
                        full?={length(@selection.highlights) >= @max}
                        position={position(@selection, c.key)}
                        me={@me.label}
                      />
                    </div>
                  </details>
                </div>
              </fieldset>

              <div
                id="curation-version"
                class="flex flex-col gap-3 border-t border-mist-950/10 pt-6 dark:border-white/10"
              >
                <.input
                  field={@form[:reason]}
                  type="textarea"
                  id="curation-reason"
                  label="Reason for this version"
                  rows="2"
                  maxlength="500"
                  disabled={not @editable?}
                  phx-debounce="300"
                  placeholder="What this version changes, and why"
                />
                <ul
                  :if={@blockers.publish != []}
                  id="curation-blockers"
                  role="list"
                  class="flex flex-col gap-1 text-sm/6 text-mist-600 dark:text-mist-400"
                >
                  <li :for={b <- Enum.uniq(@blockers.publish)} data-blocker={blocker_code(b)}>
                    <span aria-hidden="true">·</span> {blocker_text(b)}
                    <span :if={b not in @blockers.draft} class="text-mist-500">(blocks Publish only)</span>
                  </li>
                </ul>
                <div class="flex flex-wrap items-center gap-3">
                  <.button
                    id="curation-save-draft"
                    type="submit"
                    name="action"
                    value="draft"
                    variant="soft"
                    disabled={@blockers.draft != []}
                    class="min-h-11"
                  >
                    Save draft
                  </.button>
                  <.button
                    id="curation-publish"
                    type="submit"
                    name="action"
                    value="publish"
                    disabled={@blockers.publish != []}
                    class="min-h-11"
                  >
                    Publish
                  </.button>
                </div>
              </div>
            </.form>

            <aside
              id="curation-preview-pane"
              class="min-w-0 lg:sticky lg:top-6 lg:self-start"
              aria-label="Preview"
            >
              <p class="mb-4 text-sm/7 font-semibold tracking-wide text-mist-950 uppercase dark:text-white">
                Preview
                <span class="ml-2 font-normal tracking-normal text-mist-500 normal-case">
                  as the public page will show it once published
                </span>
              </p>
              <div
                id={"curation-preview-#{@preview_key}"}
                phx-mounted={JS.set_attribute({"open", ""}, to: {:inner, "details[id$='-why']"})}
                class="rounded-2xl p-5 ring-1 ring-mist-950/10 ring-inset sm:p-6 dark:ring-white/10"
              >
                <Opening.section :if={@preview.opening} opening={@preview.opening} />
                <p
                  :if={is_nil(@preview.opening)}
                  id="curation-preview-empty"
                  class="text-sm/7 text-mist-500"
                >
                  {if @selection.lead in [nil, "none"] and @selection.highlights == [],
                    do: "Nothing selected: the page shows no opening.",
                    else: "Everything selected is withheld: the page would show no opening."}
                </p>
              </div>
            </aside>
          </div>

          <.history record={@record} />
        </div>
      </.container>
    </Layouts.app>
    """
  end

  attr :candidate, :map, required: true
  attr :selection, :map, required: true
  attr :full?, :boolean, required: true
  attr :position, :integer, default: nil
  attr :me, :string, required: true

  defp candidate(assigns) do
    c = assigns.candidate
    checked? = c.key in assigns.selection.highlights
    lead? = assigns.selection.lead == c.key

    assigns =
      assign(assigns,
        checked?: checked?,
        disabled?: c.status != :ok or lead? or (assigns.full? and not checked?),
        why_not:
          cond do
            c.status != :ok -> "Cannot be selected: #{status_text(c.status)}"
            lead? -> "It is the lead"
            assigns.full? and not checked? -> "Three highlights are chosen"
            true -> nil
          end
      )

    ~H"""
    <div
      id={"candidate-#{@candidate.key}"}
      class={[
        "flex flex-col gap-2 rounded-lg px-3 py-2 ring-1 ring-inset",
        @checked? && "bg-mist-950/2.5 ring-mist-950/25 dark:bg-white/5 dark:ring-white/25",
        not @checked? && "ring-mist-950/10 dark:ring-white/10",
        @disabled? && not @checked? && "opacity-60"
      ]}
    >
      <label class="flex min-h-11 cursor-pointer gap-3">
        <input
          type="checkbox"
          id={"pick-#{@candidate.key}"}
          name="curation[highlights][]"
          value={@candidate.key}
          checked={@checked?}
          disabled={@disabled?}
          class="mt-1 size-4 shrink-0 rounded"
        />
        <span class="flex min-w-0 flex-col">
          <span class="flex flex-wrap items-center gap-x-2 text-sm/6">
            <span
              :if={@position}
              class="inline-flex size-5 items-center justify-center rounded-full bg-mist-950 text-xs/5 text-white tabular-nums dark:bg-white dark:text-mist-950"
            >
              {@position}
            </span>
            <span class="text-xs/5 font-semibold tracking-wide text-mist-500 uppercase">
              {chip(@candidate)}
            </span>
            <span class="line-clamp-1 font-medium text-mist-950 dark:text-white">
              {headline(@candidate)}
            </span>
          </span>
          <span :if={byline(@candidate)} class="text-sm/6 text-mist-600 dark:text-mist-400">
            {byline(@candidate)}
          </span>
          <span
            :if={@candidate.text && @candidate.kind != :exemplar}
            class="line-clamp-2 text-sm/6 text-pretty text-mist-700 dark:text-mist-300"
          >
            “{@candidate.text}”
          </span>
          <span :if={@candidate.meaning} class="line-clamp-1 text-sm/6 text-mist-500">
            for {@candidate.meaning}
          </span>
          <span
            :if={@why_not}
            id={"candidate-#{@candidate.key}-why-not"}
            class="text-sm/6 text-mist-500"
          >
            {@why_not}
          </span>
        </span>
      </label>
      <.note_box
        :if={@checked?}
        id={"note-#{@candidate.key}"}
        name={"curation[notes][#{@candidate.key}]"}
        label="Why this is here"
        value={@selection.notes[@candidate.key] || ""}
        author={@selection.authors[@candidate.key]}
        me={@me}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: ""
  attr :author, :string, default: nil, doc: "who the record signed a carried note to"
  attr :me, :string, default: nil

  # A note carried from a version someone else wrote says so: the record
  # signs every note of a new version as its author's (K9), so writing one
  # puts this reviewer's name to those words.
  defp note_box(assigns) do
    assigns = assign(assigns, :count, String.length(assigns.value || ""))

    ~H"""
    <div class="flex flex-col gap-1">
      <.input
        type="textarea"
        id={@id}
        name={@name}
        value={@value}
        label={@label}
        rows="2"
        maxlength={note_max()}
        phx-debounce="300"
      />
      <p
        id={"#{@id}-count"}
        class={[
          "-mt-2 text-right text-xs/5 tabular-nums",
          @count > note_max() && "text-red-700 dark:text-red-400",
          @count <= note_max() && "text-mist-500"
        ]}
      >
        {@count}/{note_max()}
      </p>
      <p
        :if={@author && @author != @me && @value != ""}
        id={"#{@id}-carried"}
        class="-mt-1 text-xs/5 text-pretty text-amber-800 dark:text-amber-200"
      >
        Written by {@author}. Publishing it unchanged keeps it theirs; a new version signs it as
        yours.
      </p>
    </div>
    """
  end

  attr :refusal, :any, required: true

  defp refusal(assigns) do
    assigns = assign(assigns, not_current?: not_current?(assigns.refusal))

    ~H"""
    <div
      id={if @not_current?, do: "curation-not-current", else: "curation-refusal"}
      role="alert"
      data-reason={blocker_code(@refusal)}
      class="rounded-lg bg-amber-50 px-4 py-3 text-sm/7 text-pretty text-amber-950 dark:bg-amber-400/10 dark:text-amber-100"
    >
      <%= if @not_current? do %>
        <p class="font-medium">Not current (not_current).</p>
        <p>
          Another reviewer saved or published this page since you opened it, so nothing was
          written. The record answered <code>{blocker_code(@refusal)}</code>. Nothing more can
          be written from this form: reload to curate from what they left.
        </p>
        <.button
          id="curation-reload"
          type="button"
          phx-click="reload"
          variant="soft"
          class="mt-2 min-h-11"
        >
          Reload
        </.button>
      <% else %>
        <p class="font-medium">
          The record refused this: <code>{blocker_code(@refusal)}</code>
        </p>
        <p>{blocker_text(@refusal)}</p>
      <% end %>
    </div>
    """
  end

  attr :record, :map, required: true
  attr :reopened?, :boolean, required: true
  attr :withdraw_reason, :string, default: ""

  # Where the page stands, and what can be done about it from here.
  defp standing(%{record: %{state: :published}} = assigns) do
    ~H"""
    <section
      id="curation-standing"
      class="flex flex-col gap-3 rounded-xl bg-mist-950/2.5 px-5 py-4 sm:flex-row sm:items-end sm:justify-between dark:bg-white/5"
    >
      <p class="text-sm/7 text-mist-700 dark:text-mist-300">
        <span class="font-medium text-mist-950 dark:text-white">Published:</span>
        version {published_version(@record)} is on the page.
      </p>
      <.form
        for={to_form(%{"reason" => @withdraw_reason}, as: :withdraw)}
        id="curation-withdraw-form"
        phx-submit="withdraw"
        class="flex flex-wrap items-end gap-3"
      >
        <.input
          type="text"
          id="curation-withdraw-reason"
          name="withdraw[reason]"
          value={@withdraw_reason}
          label="Reason to withdraw"
          class="w-64 rounded-lg border border-mist-950/15 bg-white px-3 py-2 text-sm/6 dark:border-white/15 dark:bg-mist-900"
        />
        <.button id="curation-withdraw" type="submit" variant="soft" class="mb-3 min-h-11">
          Withdraw
        </.button>
      </.form>
    </section>
    """
  end

  defp standing(%{record: %{state: :withdrawn}, reopened?: false} = assigns) do
    ~H"""
    <section
      id="curation-standing"
      class="flex flex-col gap-3 rounded-xl bg-amber-50 px-5 py-4 sm:flex-row sm:items-center sm:justify-between dark:bg-amber-400/10"
    >
      <p class="text-sm/7 text-pretty text-amber-950 dark:text-amber-100">
        <span class="font-medium">Withdrawn {withdrawal(@record)}:</span>
        kept off the page until it is re-opened. Re-open to curate it again.
      </p>
      <.button id="curation-reopen" type="button" phx-click="reopen" class="min-h-11">
        Re-open
      </.button>
    </section>
    """
  end

  defp standing(%{record: %{state: :withdrawn}} = assigns) do
    ~H"""
    <section id="curation-standing" class="rounded-xl bg-mist-950/2.5 px-5 py-4 dark:bg-white/5">
      <p class="text-sm/7 text-pretty text-mist-700 dark:text-mist-300">
        <span class="font-medium text-mist-950 dark:text-white">Re-opened:</span>
        curate again below. The withdrawn version stays in the history.
      </p>
    </section>
    """
  end

  defp standing(assigns), do: ~H""

  attr :record, :map, required: true

  defp history(assigns) do
    ~H"""
    <section
      id="curation-history"
      class="flex flex-col gap-4 border-t border-mist-950/10 pt-8 dark:border-white/10"
    >
      <h2 class="text-sm/7 font-semibold tracking-wide text-mist-950 uppercase dark:text-white">
        History
      </h2>
      <p :if={@record.versions == []} id="curation-history-empty" class="text-sm/7 text-mist-500">
        Versions: none yet.
      </p>
      <ol :if={@record.versions != []} role="list" class="flex flex-col gap-2">
        <li
          :for={v <- @record.versions}
          id={"curation-history-version-#{v.version.version}"}
          class="text-sm/6 text-pretty text-mist-700 dark:text-mist-300"
        >
          <span class="font-medium text-mist-950 dark:text-white">Version {v.version.version}</span>
          <span :if={parent = parent_number(@record, v)}> · from version {parent}</span>
          · by {v.author || "an unrecorded author"} · {date(v.version.inserted_at)} ·
          “{v.version.change_reason}” <span :if={v.review}> · review: {v.review.decision}</span>
          <span
            :if={v.version.id == @record.published_id}
            class="ml-1 rounded-full bg-emerald-100 px-2 py-0.5 text-xs/5 text-emerald-900 dark:bg-emerald-400/20 dark:text-emerald-100"
          >
            published
          </span>
        </li>
      </ol>
      <ol :if={@record.receipts != []} role="list" class="flex flex-col gap-1">
        <li
          :for={r <- @record.receipts}
          id={"curation-history-receipt-#{r.id}"}
          class="text-sm/6 text-pretty text-mist-600 dark:text-mist-400"
        >
          {receipt_line(@record, r)}
        </li>
      </ol>
    </section>
    """
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp note_max, do: @note_max

  defp of_kind(candidates, kind), do: Enum.filter(candidates.highlights, &(&1.kind == kind))

  # The first few of a group, and every one already chosen, stay in view; the
  # rest fold behind one disclosure. A folded checkbox is still in the form.
  @in_view 6

  defp fold(candidates, selection) do
    candidates
    |> Enum.with_index()
    |> Enum.split_with(fn {c, n} -> n < @in_view or c.key in selection.highlights end)
    |> then(fn {shown, folded} ->
      {Enum.map(shown, &elem(&1, 0)), Enum.map(folded, &elem(&1, 0))}
    end)
  end

  defp position(selection, key) do
    case Enum.find_index(selection.highlights, &(&1 == key)) do
      nil -> nil
      n -> n + 1
    end
  end

  defp empty_group(:content, _candidates), do: "No entry on this page."
  defp empty_group(:sense_quotation, _candidates), do: "None under these senses."

  defp empty_group(:work, _candidates),
    do:
      "None on this page’s Saved catalog shelf. Poems and books are not offered here: their catalogs record nothing a page can be matched on."

  defp empty_group(:exemplar, %{nominations: n}),
    do: "None accepted; #{n} #{if n == 1, do: "nomination", else: "nominations"} awaiting review."

  defp chip(%{kind: :content}), do: "Definition"
  defp chip(%{kind: :sense_quotation}), do: "Quotation"
  defp chip(%{kind: :work, work_kind: kind}) when is_binary(kind), do: kind
  defp chip(%{kind: :work}), do: "Work"
  defp chip(%{kind: :exemplar, label: label}), do: label

  defp headline(%{kind: :content} = c),
    do: Enum.join(Enum.reject([c.label, c.title], &is_nil/1), " · ")

  defp headline(%{kind: :sense_quotation} = c), do: c.citation || c.label
  defp headline(c), do: c.title || c.label

  defp byline(%{kind: :work} = c),
    do: [c.creator, c.date, c.label] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")

  defp byline(%{kind: :sense_quotation} = c), do: c.label

  defp byline(%{kind: :exemplar} = c),
    do: [c.detail, c.text && "“#{c.text}”"] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

  defp byline(_c), do: nil

  defp scope_line(scope) do
    words =
      Enum.map_join(scope.lexemes, ", ", fn l ->
        "#{l.lemma} (#{l.pos || "word"} #{l.id})"
      end)

    "#{words} · #{scope.language || "several languages"}"
  end

  defp config_line(%{configuration: %{slug: slug}, configuration_version: %{version: v}}),
    do: "#{slug} v#{v}"

  defp config_line(_record), do: "no enabled configuration"

  defp published_version(%{published_id: id, versions: versions}) do
    case Enum.find(versions, &(&1.version.id == id)) do
      nil -> "?"
      v -> v.version.version
    end
  end

  defp parent_number(record, %{version: %{parent_version_id: id}}) when is_integer(id) do
    Enum.find_value(record.versions, &(&1.version.id == id && &1.version.version))
  end

  defp parent_number(_record, _v), do: nil

  defp receipt_line(record, %{action: :publish} = r) do
    number =
      Enum.find_value(
        record.versions,
        &(&1.version.id == r.published_version_id && &1.version.version)
      )

    "Published version #{number} · receipt ##{r.id} · #{r.actor_label} · #{date(r.committed_at)} · “#{r.reason}”"
  end

  defp receipt_line(record, %{action: :withdraw} = r) do
    number =
      Enum.find_value(
        record.versions,
        &(&1.version.id == r.previous_version_id && &1.version.version)
      )

    "Withdrew version #{number} · receipt ##{r.id} · #{r.actor_label} · #{date(r.committed_at)} · “#{r.reason}”"
  end

  defp date(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %Y")

  defp withdrawal(%{receipts: [%{action: :withdraw} = r | _]}),
    do: "#{date(r.committed_at)} (“#{r.reason}”)"

  defp withdrawal(_record), do: ""

  defp lead_verdict({:error, :priority_source_available}), do: "Bierce leads"
  defp lead_verdict({:error, reason}), do: "Cannot lead: #{status_text(reason)}"
  defp lead_verdict(_ok), do: nil

  defp status_text(:not_a_catalog_row), do: "not a committed catalog row"
  defp status_text(reason), do: "#{Opening.withheld_reason(reason)} (#{reason})"

  defp not_current?(:not_current), do: true
  defp not_current?({:stale_parent, _}), do: true
  defp not_current?({:stale_pointer, _}), do: true
  defp not_current?(_reason), do: false

  @doc false
  def blocker_code({reason, _role, _position}) when is_atom(reason), do: to_string(reason)
  def blocker_code({reason, _detail}) when is_atom(reason), do: to_string(reason)
  def blocker_code(reason) when is_atom(reason), do: to_string(reason)
  def blocker_code(reason), do: inspect(reason)

  # Each refusal or blocker in plain words, after its code. Unknown ones say
  # what the record answered.
  defp blocker_text(:not_current),
    do: "Another reviewer changed this page since it was opened: reload to see it."

  defp blocker_text({:required, :withdraw_reason}),
    do: "Write a reason to withdraw: the record requires one."

  defp blocker_text({:required, :reason}),
    do: "Write a reason for this version: the record requires one."

  defp blocker_text({:reason_missing, n}), do: "Highlight #{n} needs a reason: why it is here."

  defp blocker_text({:note_too_long, :lead}),
    do: "The lead's reason is over #{@note_max} characters."

  defp blocker_text({:note_too_long, n}),
    do: "Highlight #{n}'s reason is over #{@note_max} characters."

  defp blocker_text(:nothing_selected), do: "Choose a lead or a highlight."
  defp blocker_text(:withdrawn), do: "This page was withdrawn: re-open it to curate again."
  defp blocker_text(:nothing_to_cite), do: "Nothing the record can cite yet."
  defp blocker_text(:unconfigured), do: "No curation configuration is enabled."
  defp blocker_text(:no_scope), do: "This address names no words to curate."
  defp blocker_text(:already_published), do: "This arrangement is already on the page."
  defp blocker_text(:unpublished), do: "Nothing is published to withdraw."
  defp blocker_text(:unauthorized), do: "Only a reviewer may do this."

  defp blocker_text({:overlapping_scope, ids}),
    do:
      "These words already belong to another composition (#{Enum.map_join(ids, ", ", &"##{&1}")}). Changing its scope is not done from this screen."

  defp blocker_text({:duplicate_display_identity, id}),
    do: "Two items would show the same thing (object #{id}). Keep one."

  defp blocker_text({:too_many_highlights, n}), do: "At most #{n} highlights."

  defp blocker_text({:duplicate_version, _id}),
    do: "This exact arrangement is already an earlier version under this configuration."

  defp blocker_text({:ineligible, results}),
    do:
      Enum.map_join(results, " ", fn {role, position, reason} ->
        "#{if role == :lead, do: "The lead", else: "Highlight #{position}"}: #{status_text(reason)}."
      end)

  defp blocker_text({:configuration, reason}), do: "No curation configuration: #{reason}."

  defp blocker_text({reason, role, position})
       when is_atom(reason) and role in [:lead, :highlight],
       do:
         "#{if role == :lead, do: "The lead", else: "Highlight #{position}"}: #{status_text(reason)}."

  defp blocker_text(reason) when is_atom(reason),
    do: Opening.withheld_reason(reason) |> String.capitalize()

  defp blocker_text(reason), do: inspect(reason)
end
