defmodule DevilsDictionaryWeb.CurationLive.Editor do
  @moduledoc """
  The owner's curation editor, `/ops/curation/on/:slug` (#257 §2.2, §2.4,
  §2.6; #253 §6, §6a).

  **The scope is the page's words**, shown and never typed: the On page the
  slug addresses, built as the reader builds it, and its
  `page.headword.lexemes` (`CurationLive.page/1`). A composition is
  `:lexical_page` over them. The exact-word pages overlap this scope and
  cannot have a separate active lexical-page composition (K3); they do not
  display this one either (the reader resolves exact signatures). The
  editor says so and offers nothing else.

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
    * *Re-open*: lifts the withdrawal's suppression of the refresh clock
      (`Refresh.reopen/1`, #259 §5.5), so the page's next visit queues one
      check, and opens the form again.

  **The refresh clock** (#259 §2.3): the header says when the page was last
  assessed, and a banner says when its inputs changed since, when the last
  check found an editor is needed, or when a check failed. A check looks at
  the inputs and does not judge them.

  **The editor's proposal (#264 §2.2–§2.4, R10–R15)**, at
  `?proposal=<version id>`: a strip above the form says who proposed it
  (read from its attempt's model config), from which attempt, what it was
  offered, which of the owner's kept items it carried and which it could
  not, what it chose with no place left, and whether the page moved since
  it was admitted. Below it, the quality form (`quality-form-v1`, five
  yes/no answers per item and a note) and the owner's three acts:

    * *Take as is* (`Proposals.take/3`), offered only while the proposal is
      the page's newest version;
    * *Edit then publish*: the form is filled from the proposal, and
      Publish publishes the edit (`Proposals.edit_publish/3`): items kept as
      offered stay the editor's, rewritten or added ones are the owner's;
    * *Dismiss*, with a reason (`Proposals.dismiss/3`).

  **No bypass (R13.2).** The ordinary form opens on the newest *manual*
  version and never loads a note the model wrote (its reason travels only
  by Take); Save is parented to the newest version of any origin; Publish
  publishes a held manual version even when a proposal is newer, and never
  a proposal.

  **The owner's marks (#253 D8)**: the page's mode (open to proposals, or
  mine) and a keep mark on each published item. **Request a proposal**
  (R18) while the editor is enabled.

  No job is queued except by Request, nothing is fetched and no model is
  called from this screen.
  """
  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Curation.{
    Candidates,
    CompositionVersion,
    Compositions,
    Configurations,
    Preview,
    Proposals,
    Publications,
    Refresh,
    Reviews,
    Standing
  }

  alias DevilsDictionary.Curation.Proposals.QualityForm

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
        refresh: nil,
        stale: nil,
        refusal: nil,
        notice: nil,
        withdraw_reason: "",
        proposal_id: nil,
        proposal: nil,
        editing: nil,
        quality: fresh_quality(),
        editor_on?: false,
        me: Preview.author(socket.assigns.current_scope),
        page_title: "Curate · #{slug}"
      )

    {:ok, if(connected?(socket), do: load(socket), else: socket)}
  end

  # `?proposal=<version id>` opens the editor's proposal (#264 §2.2).
  @impl true
  def handle_params(params, _uri, socket) do
    id =
      case Integer.parse(params["proposal"] || "") do
        {n, ""} -> n
        _none -> nil
      end

    socket = assign(socket, :proposal_id, id)

    {:noreply,
     if(socket.assigns.loaded?, do: socket |> load_proposal() |> preview(), else: socket)}
  end

  # The proposal open on this page, if the id names one of its versions.
  defp load_proposal(socket) do
    view =
      with id when is_integer(id) <- socket.assigns.proposal_id,
           %{} = view <- Proposals.view(id),
           %{composition: %{id: composition_id}} <- socket.assigns.record,
           true <- view.version.composition_id == composition_id do
        view
      else
        _none -> nil
      end

    socket =
      assign(socket,
        proposal: view,
        quality: fresh_quality()
      )

    if socket.assigns.editing && view == nil, do: stop_editing(socket), else: socket
  end

  defp fresh_quality, do: %{"answers" => %{}, "note" => "", "reason" => ""}

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
    |> assign(:editing, nil)
    |> then(&assign(&1, :selection, initial_selection(&1.assigns)))
    |> assign(:notice, nil)
    |> uncarried()
    |> load_proposal()
    |> preview()
  end

  # Items of the latest version this screen no longer offers (a revision
  # since superseded, a work no seam lists): the form leaves them out, and
  # says so, rather than drop them silently from the next version.
  defp uncarried(%{assigns: %{record: %{latest: %{} = latest}, candidates: c}} = socket) do
    case Enum.count(latest.items, &is_nil(item_key(&1, c))) do
      0 ->
        socket

      n ->
        assign(
          socket,
          :notice,
          "Version #{latest.version.version} holds #{n} #{if n == 1, do: "item", else: "items"} " <>
            "this screen does not offer now. A new version from this form leaves " <>
            "#{if n == 1, do: "it", else: "them"} out."
        )
    end
  end

  defp uncarried(socket), do: socket

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

  # ── the proposal (#264 R10–R12) ──────────────────────────────────────────

  def handle_event("quality", %{"quality" => params}, socket) do
    {:noreply, assign(socket, :quality, quality_of(params, socket.assigns.quality))}
  end

  def handle_event("quality", _params, socket), do: {:noreply, socket}

  def handle_event("proposal_action", %{"quality" => params} = all, socket) do
    socket = assign(socket, :quality, quality_of(params, socket.assigns.quality))

    case all["action"] do
      "take" -> {:noreply, take(socket)}
      "dismiss" -> {:noreply, dismiss(socket)}
      _other -> {:noreply, socket}
    end
  end

  def handle_event("edit_proposal", _params, %{assigns: %{proposal: %{} = view}} = socket) do
    {:noreply,
     socket
     |> assign(:editing, view)
     |> assign(:selection, edit_selection(view, socket.assigns.candidates))
     |> assign(:notice, edit_notice(view, socket.assigns.candidates))
     |> preview()}
  end

  def handle_event("edit_proposal", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_edit", _params, socket),
    do: {:noreply, socket |> stop_editing() |> preview()}

  # ── the owner's marks (#253 D8, #264 R15) and Request (R18) ─────────────

  def handle_event("set_mode", %{"mode" => mode}, socket) when mode in ["open", "mine"] do
    with %{composition: %{id: id}} <- socket.assigns.record,
         {:ok, _composition} <-
           Compositions.set_mode(
             socket.assigns.current_scope,
             id,
             String.to_existing_atom(mode),
             []
           ) do
      {:noreply,
       socket
       |> load_record()
       |> assign(refusal: nil, notice: mode_notice(mode))}
    else
      {:error, reason} -> {:noreply, refused(socket, reason)}
      _none -> {:noreply, socket}
    end
  end

  def handle_event("set_mode", _params, socket), do: {:noreply, socket}

  def handle_event("keep", %{"item" => item}, socket) do
    marked(socket, fn id ->
      Compositions.keep(socket.assigns.current_scope, id, String.to_integer(item), [])
    end)
  end

  def handle_event("unkeep", %{"key" => key}, socket) do
    marked(socket, fn id -> Compositions.unkeep(socket.assigns.current_scope, id, key, []) end)
  end

  def handle_event("request", _params, socket) do
    with true <- socket.assigns.editor_on?,
         %{composition: %{id: id}} <- socket.assigns.record do
      case Refresh.request(
             socket.assigns.current_scope,
             id,
             socket.assigns.slug,
             "requested from the curation screen"
           ) do
        {:ok, outcome} ->
          {:noreply,
           socket |> load_record() |> assign(refusal: nil, notice: request_notice(outcome))}

        {:error, reason} ->
          {:noreply, refused(socket, reason)}
      end
    else
      _off -> {:noreply, socket}
    end
  end

  def handle_event("reload", _params, socket) do
    {:noreply, socket |> assign(reopened?: false, refusal: nil, notice: nil) |> load()}
  end

  def handle_event("reopen", _params, socket) do
    case socket.assigns.record do
      %{composition: %{id: id}} -> Refresh.reopen(id)
      _none -> 0
    end

    {:noreply,
     socket
     |> load_record()
     |> assign(reopened?: true, refusal: nil)
     |> assign(
       :notice,
       "Re-opened: the page's checks resume, and its next visit queues one. Curate again and publish a new version."
     )
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
  #
  # The ordinary form never loads a note the model wrote (#264 R13.2): the
  # item comes with its reference and an empty reason, since Save signs
  # every note as the reviewer and must never re-sign the editor's words.
  # Edit then publish (`edit_selection/2`) does load them: what is kept as
  # offered is copied, still the editor's.
  defp version_selection(%{items: items}, candidates, model_notes \\ :blank) do
    keyed =
      for item <- items, key = item_key(item, candidates) do
        if model_notes == :blank and item.note_author_kind == :model,
          do: {%{item | note: nil, note_author_label: nil}, key},
          else: {item, key}
      end

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

  # The proposal's arrangement in the form, its notes as offered.
  defp edit_selection(view, candidates) do
    version_selection(%{items: view.items}, candidates, :keep)
  end

  defp edit_notice(view, candidates) do
    case Enum.count(view.items, &is_nil(item_key(&1, candidates))) do
      0 ->
        "Editing the proposal: items kept as offered stay the editor's; a reason you rewrite, or an item you add, is yours. Publish publishes the edit, with the quality form above."

      n ->
        "Editing the proposal: #{n} of its items this screen does not offer now, and the edit leaves #{if n == 1, do: "it", else: "them"} out."
    end
  end

  defp stop_editing(socket) do
    socket
    |> assign(:editing, nil)
    |> assign(:selection, initial_selection(socket.assigns))
    |> assign(:notice, nil)
  end

  # Items of the newest manual version whose reason the editor wrote: the
  # ordinary form left their reasons out (#264 R13.2).
  defp model_noted(%{record: %{latest: %{items: items}}, editing: nil}),
    do: Enum.count(items, &(&1.note_author_kind == :model))

  defp model_noted(_assigns), do: 0

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
    items = Preview.items(selection, socket.assigns.me)
    held = if socket.assigns.editing, do: nil, else: held(record, items)
    next = if record.newest, do: record.newest.version.version + 1, else: 1

    preview =
      Preview.build(page, candidates, selection, socket.assigns.current_scope,
        composition: record.composition,
        next_version: next,
        held:
          cond do
            held ->
              %{version: held.version, items: held.items, author: held.author}

            socket.assigns.editing ->
              edited(socket.assigns.editing, items, next, socket.assigns.me)

            true ->
              nil
          end
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

  # What Edit then publish would publish, for the preview: an item kept as
  # offered is the proposal's, still signed by whoever wrote it; any other
  # is the reviewer's, as the form attributes it.
  defp edited(view, items, next, me) do
    taken =
      Enum.map(items, fn item ->
        case Enum.find(view.items, &as_offered?(&1, item)) do
          nil -> item
          offered -> %{offered | role: item.role, position: item.position}
        end
      end)

    %{
      version: %CompositionVersion{
        version: next,
        inserted_at: DateTime.utc_now(),
        resolution: %{}
      },
      items: taken,
      author: me.label
    }
  end

  defp as_offered?(offered, item) do
    Map.take(offered, @reference_fields -- [:role, :position]) ==
      Map.take(item, @reference_fields -- [:role, :position])
  end

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
        if(assigns.editing && not QualityForm.complete?(quality_form(assigns)),
          do: [:quality_form_incomplete],
          else: []
        ),
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

    draft = if assigns.editing, do: common ++ [:editing_proposal], else: common
    %{draft: draft, publish: common ++ notes ++ published}
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
      # The new version signs every note as this reviewer's.
      {:ok, version} ->
        socket
        |> after_write("Saved version #{version.version} as a draft. Nothing was published.")
        |> assign(:selection, %{sel | reason: "", authors: %{}})
        |> preview()

      {:error, reason} ->
        refused(socket, reason)
    end
  end

  defp publish(%{assigns: %{blockers: %{publish: [_ | _] = blockers}}} = socket),
    do: assign(socket, refusal: hd(blockers), notice: nil)

  # Edit then publish (#264 R11.3): the edited arrangement, the quality form
  # and the compare-and-switch, in one transaction.
  defp publish(%{assigns: %{editing: %{} = view}} = socket) do
    %{current_scope: scope, selection: sel, record: record, candidates: candidates} =
      socket.assigns

    result =
      Proposals.edit_publish(scope, view.proposal.id,
        lead: lead_spec(sel, candidates),
        highlights: Enum.map(sel.highlights, &spec(candidates, &1, sel.notes[&1])),
        reason: sel.reason,
        expected_pointer: record.published_id,
        answers: socket.assigns.quality["answers"],
        note: socket.assigns.quality["note"]
      )

    case result do
      {:ok, %{version: version, receipt: receipt}} ->
        socket
        |> after_proposal(
          "Edited the proposal and published it as version #{version.version} (receipt ##{receipt.id})."
        )

      {:error, reason} ->
        refused(socket, reason)
    end
  end

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
      # A held version keeps its notes' authors; a new one signs them all as
      # this reviewer's.
      {:ok, {version, receipt}} ->
        socket
        |> after_write(
          "Published version #{version.version} (receipt ##{receipt.id}). The page shows it on its next request."
        )
        |> assign(:selection, %{sel | reason: "", authors: if(held, do: sel.authors, else: %{})})
        |> preview()

      {:error, reason} ->
        refused(socket, reason)
    end
  end

  # The held version, while it is still the newest manual one; otherwise a
  # new one, from the latest this form was opened on. A proposal, pending or
  # resolved, never makes it stale (#264 R13.2): it is never held, and only
  # a newer manual version moves it.
  defp publishable(_assigns, %{version: version}, _scope) do
    case Compositions.latest_manual_version(version.composition_id) do
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
        # Parented to the newest version of any origin (#264 R13.2).
        Compositions.create_version(scope, composition.id, %{
          lead: lead_spec(sel, candidates),
          highlights: Enum.map(sel.highlights, &spec(candidates, &1, sel.notes[&1])),
          reason: sel.reason,
          expected_parent: record.newest && record.newest.version.id
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

  # After Take, Edit-publish or Dismiss: the record as it is now, the
  # ordinary form on the newest manual version, and the proposal closed.
  defp after_proposal(socket, notice) do
    socket
    |> load_record()
    |> assign(editing: nil, proposal: nil, proposal_id: nil, quality: fresh_quality())
    |> then(&assign(&1, :selection, initial_selection(&1.assigns)))
    |> assign(refusal: nil, notice: notice)
    |> preview()
    |> push_patch(to: ~p"/ops/curation/on/#{socket.assigns.slug}")
  end

  defp take(%{assigns: %{proposal: %{} = view}} = socket) do
    q = socket.assigns.quality

    case Proposals.take(socket.assigns.current_scope, view.proposal.id,
           reason: q["reason"],
           expected_pointer: socket.assigns.record.published_id,
           answers: q["answers"],
           note: q["note"]
         ) do
      {:ok, %{version: version, receipt: receipt}} ->
        after_proposal(
          socket,
          "Took the proposal: published version #{version.version} (receipt ##{receipt.id}). Its items keep who wrote them."
        )

      {:error, reason} ->
        refused(socket, reason)
    end
  end

  defp take(socket), do: socket

  defp dismiss(%{assigns: %{proposal: %{} = view}} = socket) do
    q = socket.assigns.quality

    case Proposals.dismiss(socket.assigns.current_scope, view.proposal.id,
           reason: q["reason"],
           answers: q["answers"],
           note: q["note"]
         ) do
      {:ok, _proposal} ->
        after_proposal(
          socket,
          "Dismissed the proposal with your reason. The same arrangement from the same packet is not proposed again."
        )

      {:error, reason} ->
        refused(socket, reason)
    end
  end

  defp dismiss(socket), do: socket

  # The quality form as the strip holds it: answers by slot and question,
  # the note, and the reason the act carries.
  defp quality_of(params, old) do
    %{
      "answers" =>
        case params["answers"] do
          %{} = answers -> Map.merge(old["answers"], answers, fn _k, a, b -> Map.merge(a, b) end)
          _none -> old["answers"]
        end,
      "note" => text(params["note"], old["note"]),
      "reason" => text(params["reason"], old["reason"])
    }
  end

  # The stored shape of the strip's form, to ask whether it is complete.
  defp quality_form(%{proposal: %{items: items}, quality: q}) do
    case QualityForm.build(items, q["answers"], q["note"], nil) do
      {:ok, form} -> form
      {:error, _incomplete} -> nil
    end
  end

  defp quality_form(_assigns), do: nil

  defp marked(socket, fun) do
    with %{composition: %{id: id}} <- socket.assigns.record,
         {:ok, _composition} <- fun.(id) do
      {:noreply, socket |> load_record() |> assign(refusal: nil, notice: nil)}
    else
      {:error, reason} -> {:noreply, refused(socket, reason)}
      _none -> {:noreply, socket}
    end
  end

  defp mode_notice("mine"),
    do: "This page is yours: proposals still arrive, flagged, and nothing takes one for you."

  defp mode_notice("open"), do: "This page is open to proposals."

  defp request_notice(:admitted),
    do: "Requested: one run is queued. Its proposal appears on the Proposed tab when it lands."

  defp request_notice(:in_flight),
    do: "A run is already in flight for this page: nothing more was queued."

  defp request_notice(:suppressed), do: "This page is withdrawn: re-open it before requesting."
  defp request_notice(:busy), do: "The page is busy right now: try again in a moment."
  defp request_notice(outcome), do: "Requested: #{outcome}."

  # The record and its refresh clock. A withdrawn page whose clock is no
  # longer suppressed was re-opened, also after a reload.
  defp load_record(socket) do
    record = CurationLive.record(socket.assigns.candidates)
    refresh = CurationLive.refresh(record)

    editor_on? =
      not is_nil(record.composition) and not is_nil(record.configuration_version) and
        match?({:ok, _}, Configurations.editor_enabled(record.configuration_version.id))

    socket
    |> assign(record: record, refresh: refresh, editor_on?: editor_on?)
    |> assign(
      :reopened?,
      record.state == :withdrawn and not is_nil(refresh) and refresh.state != :suppressed
    )
  end

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
              <span :if={@record.composition} id="curation-clock-assessed">
                · last assessed {CurationLive.assessed_label(@refresh)}
              </span>
            </p>
            <p id="curation-shared" class="max-w-3xl text-sm/7 text-pretty text-mist-500">
              Exact-word pages overlap this editing scope and cannot have a separate active
              lexical-page composition; they do not currently display this composition.
            </p>
          </header>

          <.clock :if={@record.composition} refresh={@refresh} />

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

          <.marks
            :if={@record.composition}
            record={@record}
            candidates={@candidates}
            editor_on?={@editor_on?}
          />

          <.proposal_strip
            :if={@proposal}
            view={@proposal}
            candidates={@candidates}
            quality={@quality}
            editing={@editing}
            record={@record}
          />

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

              <p
                :if={model_noted(assigns) > 0}
                id="curation-model-notes"
                class="rounded-lg bg-mist-950/2.5 px-4 py-3 text-sm/7 text-pretty text-mist-700 dark:bg-white/5 dark:text-mist-300"
              >
                {model_noted(assigns)} {if model_noted(assigns) == 1,
                  do: "reason in this version was",
                  else: "reasons in this version were"} written by the editor. This form leaves {if model_noted(
                                                                                                      assigns
                                                                                                    ) ==
                                                                                                      1,
                                                                                                    do:
                                                                                                      "it",
                                                                                                    else:
                                                                                                      "them"} empty, because a version
                saved here signs every reason as yours: the editor's reasons travel only by Take.
              </p>

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
                    {if @editing, do: "Publish the edited proposal", else: "Publish"}
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
        kept off the page and not assessed again until you Re-open. Re-open to curate it again.
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
  attr :candidates, :map, required: true
  attr :editor_on?, :boolean, required: true

  # The owner's marks (#253 D8, #264 R15): the page's mode, and a keep mark
  # on each published item. Marking writes no version. And, while the editor
  # is enabled, Request (R18).
  defp marks(assigns) do
    assigns =
      assigns
      |> assign(:published, published_items(assigns.record, assigns.candidates))
      |> assign(:kept, Map.new(assigns.record.composition.kept_items, &{&1["key"], &1}))
      |> assign(:actors, mark_actors(assigns.record.composition))

    ~H"""
    <section
      id="curation-marks"
      class="flex flex-col gap-4 rounded-xl px-5 py-4 ring-1 ring-mist-950/10 ring-inset dark:ring-white/10"
    >
      <form id="curation-mode-form" phx-change="set_mode" class="flex flex-col gap-2">
        <fieldset class="flex flex-col gap-2 sm:flex-row sm:flex-wrap sm:items-center sm:gap-x-6">
          <legend class="mb-1 text-sm/7 font-medium text-mist-950 dark:text-white">This page</legend>
          <label id="mode-open" class="flex min-h-11 items-center gap-2 text-sm/6 sm:min-h-0">
            <input
              type="radio"
              name="mode"
              value="open"
              checked={@record.composition.mode == :open}
              class="size-4"
            /> open to proposals
          </label>
          <label id="mode-mine" class="flex min-h-11 items-center gap-2 text-sm/6 sm:min-h-0">
            <input
              type="radio"
              name="mode"
              value="mine"
              checked={@record.composition.mode == :mine}
              class="size-4"
            /> mine: proposals are shown, never taken for you
          </label>
        </fieldset>
        <p
          :if={@record.composition.mode_set_at}
          id="curation-mode-set"
          class="text-xs/5 text-mist-500"
        >
          Set by {@actors[@record.composition.mode_set_by_actor_id] || "a reviewer"} · {date(
            @record.composition.mode_set_at
          )}
        </p>
      </form>

      <div :if={@published != []} id="curation-kept" class="flex flex-col gap-2">
        <p class="text-sm/7 font-medium text-mist-950 dark:text-white">
          Published items
          <span class="font-normal text-mist-500">· a kept item is carried into every proposal</span>
        </p>
        <ul role="list" class="flex flex-col gap-1">
          <li
            :for={item <- @published}
            id={"kept-#{item.key}"}
            class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 text-sm/6"
          >
            <span class="min-w-0 text-mist-700 dark:text-mist-300">
              {if item.item.role == :lead, do: "Lead", else: "Highlight #{item.item.position}"} · {item.label}
            </span>
            <%= if mark = @kept[item.key] do %>
              <span class="flex items-center gap-2">
                <span class="text-xs/5 text-mist-600 dark:text-mist-400">
                  ⚑ kept by {@actors[mark["marked_by_actor_id"]] || "a reviewer"} · {mark_date(mark)}
                </span>
                <.button
                  id={"unkeep-#{item.key}"}
                  type="button"
                  phx-click="unkeep"
                  phx-value-key={item.key}
                  variant="soft"
                  class="min-h-11 sm:min-h-0"
                >
                  Unkeep
                </.button>
              </span>
            <% else %>
              <.button
                id={"keep-#{item.key}"}
                type="button"
                phx-click="keep"
                phx-value-item={item.item.id}
                variant="soft"
                class="min-h-11 sm:min-h-0"
              >
                ⚑ Keep
              </.button>
            <% end %>
          </li>
        </ul>
      </div>

      <div
        :if={@editor_on?}
        id="curation-request"
        class="flex flex-col gap-2 border-t border-mist-950/10 pt-3 sm:flex-row sm:items-center sm:justify-between dark:border-white/10"
      >
        <p class="text-sm/7 text-pretty text-mist-700 dark:text-mist-300">
          The editor is on. Ask it to assess this page now, whatever its inputs.
        </p>
        <.button id="curation-request-button" type="button" phx-click="request" class="min-h-11">
          Request a proposal
        </.button>
      </div>
    </section>
    """
  end

  attr :view, :map, required: true
  attr :candidates, :map, required: true
  attr :quality, :map, required: true
  attr :editing, :any, default: nil
  attr :record, :map, required: true

  # The editor's proposal (#264 §2.2): who proposed it and from what, what
  # it carried and could not, the quality form, and Take, Edit, Dismiss.
  defp proposal_strip(assigns) do
    view = assigns.view

    assigns =
      assigns
      |> assign(:pending?, view.proposal.state == :pending)
      |> assign(:carried, Enum.filter(view.proposal.carried, & &1["carried"]))
      |> assign(:not_carried, Enum.reject(view.proposal.carried, & &1["carried"]))
      |> assign(:labels, Map.new(view.items, &{&1.id, item_label(&1, assigns.candidates)}))
      # A carried mark names the parent's item; the strip names the copy.
      |> assign(
        :copies,
        for(%{copied_from_item_id: from} = i <- view.items, from, into: %{}, do: {from, i.id})
      )

    ~H"""
    <section
      id="proposal-strip"
      aria-labelledby="proposal-heading"
      class="flex flex-col gap-5 rounded-2xl bg-sky-50/60 px-5 py-5 ring-1 ring-sky-900/10 ring-inset sm:px-6 dark:bg-sky-400/5 dark:ring-sky-300/15"
    >
      <header class="flex flex-col gap-1">
        <h2
          id="proposal-heading"
          class="text-sm/7 font-semibold tracking-wide text-mist-950 uppercase dark:text-white"
        >
          Proposal
          <span class="ml-2 font-normal tracking-normal text-mist-700 normal-case dark:text-mist-300">
            version {@view.version.version} · {@view.proposed_by} ·
            <.link
              id="proposal-attempt"
              navigate={~p"/ops/curation/attempts/#{@view.version.attempt_id}"}
              class="underline underline-offset-4"
            >
              attempt {"##{@view.version.attempt_id}"}
            </.link>
            · {Calendar.strftime(@view.version.inserted_at, "%-d %b %H:%M")}
          </span>
        </h2>
        <p id="proposal-offered" class="text-sm/7 text-mist-700 dark:text-mist-300">
          Offered {@view.offered} of {@view.candidates_total} candidates ({@view.omitted} omitted:
          see the attempt) · reasons signed by the model
        </p>
        <p id="proposal-carried" class="text-sm/7 text-pretty text-mist-700 dark:text-mist-300">
          Carried, yours: {if @carried == [],
            do: "—",
            else: Enum.map_join(@carried, ", ", &(@labels[@copies[&1["item_id"]]] || &1["key"]))} · Not carried: {if @not_carried ==
                                                                                                                       [],
                                                                                                                     do:
                                                                                                                       "—",
                                                                                                                     else:
                                                                                                                       Enum.map_join(
                                                                                                                         @not_carried,
                                                                                                                         ", ",
                                                                                                                         &"#{&1["key"]} (#{&1["reason"]})"
                                                                                                                       )}
          <span :if={@view.proposal.overflow != []}>
            · Also chosen, no place left after your kept items: {Enum.join(
              @view.proposal.overflow,
              ", "
            )}
          </span>
        </p>
        <p
          :if={@view.proposal.superseded_on_arrival}
          id="proposal-superseded"
          class="text-sm/7 font-medium text-amber-800 dark:text-amber-300"
        >
          <span aria-hidden="true">⚠</span>
          The page changed since this run was admitted (superseded on arrival)
        </p>
        <p
          :if={@record.composition.mode == :mine}
          id="proposal-mine"
          class="text-sm/7 text-mist-700 dark:text-mist-300"
        >
          This page is yours: nothing takes this proposal for you.
        </p>
        <p
          :if={not @pending?}
          id="proposal-resolved"
          class="text-sm/7 font-medium text-mist-950 dark:text-white"
        >
          This proposal was {@view.proposal.state}{if @view.proposal.resolution_reason,
            do: ": “#{@view.proposal.resolution_reason}”"}.
        </p>
        <p
          :if={@pending? and not @view.newest?}
          id="proposal-not-newest"
          class="text-sm/7 text-pretty text-mist-700 dark:text-mist-300"
        >
          A newer version exists, so it cannot be taken: dismiss it, or edit it then publish.
        </p>
      </header>

      <.form
        :if={@pending?}
        for={to_form(@quality, as: :quality)}
        id="proposal-form"
        phx-change="quality"
        phx-submit="proposal_action"
        class="flex flex-col gap-5"
      >
        <fieldset class="flex flex-col gap-4">
          <legend class="mb-1 text-sm/7 font-medium text-mist-950 dark:text-white">
            Quality form
            <span class="font-normal text-mist-600 dark:text-mist-400">
              (required for Take and Edit; counts toward the five only when complete)
            </span>
          </legend>
          <div
            :for={item <- @view.items}
            id={"quality-#{slot_id(item)}"}
            class="flex flex-col gap-2 border-t border-mist-950/10 pt-3 first:border-t-0 first:pt-0 dark:border-white/10"
          >
            <p class="text-sm/6 text-mist-950 dark:text-white">
              <span class="font-medium">
                {if item.role == :lead, do: "Lead", else: "Highlight #{item.position}"}
              </span>
              · {@labels[item.id]}
              <span class="text-mist-600 dark:text-mist-400">
                · {if item.selection_origin == :model, do: "the editor's", else: "carried, yours"}
              </span>
            </p>
            <p :if={item.note} class="text-sm/6 text-pretty text-mist-700 dark:text-mist-300">
              “{item.note}” <span class="text-mist-500">— {item.note_author_label}</span>
            </p>
            <div class="grid grid-cols-1 gap-x-6 gap-y-1 sm:grid-cols-2 lg:grid-cols-3">
              <div
                :for={q <- QualityForm.questions()}
                class="flex min-h-11 items-center justify-between gap-3 text-sm/6 sm:min-h-9"
              >
                <span class="text-mist-700 dark:text-mist-300">{QualityForm.label(q)}</span>
                <span class="flex gap-3">
                  <label class="flex items-center gap-1">
                    <input
                      type="radio"
                      id={"quality-#{slot_id(item)}-#{q}-yes"}
                      name={"quality[answers][#{QualityForm.slot(item)}][#{q}]"}
                      value="yes"
                      checked={answer(@quality, item, q) == "yes"}
                      class="size-4"
                    /> yes
                  </label>
                  <label class="flex items-center gap-1">
                    <input
                      type="radio"
                      id={"quality-#{slot_id(item)}-#{q}-no"}
                      name={"quality[answers][#{QualityForm.slot(item)}][#{q}]"}
                      value="no"
                      checked={answer(@quality, item, q) == "no"}
                      class="size-4"
                    /> no
                  </label>
                </span>
              </div>
            </div>
          </div>
        </fieldset>

        <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
          <.input
            type="textarea"
            id="proposal-note"
            name="quality[note]"
            value={@quality["note"]}
            label="Note on this proposal"
            rows="2"
            phx-debounce="300"
          />
          <.input
            type="textarea"
            id="proposal-reason"
            name="quality[reason]"
            value={@quality["reason"]}
            label="Your reason (for Take, or to Dismiss)"
            rows="2"
            phx-debounce="300"
          />
        </div>

        <div class="flex flex-wrap items-center gap-3">
          <.button
            :if={@view.newest?}
            id="proposal-take"
            type="submit"
            name="action"
            value="take"
            disabled={not complete?(@view, @quality) or blank?(@quality["reason"])}
            class="min-h-11"
          >
            Take as is
          </.button>
          <.button
            :if={is_nil(@editing)}
            id="proposal-edit"
            type="button"
            phx-click="edit_proposal"
            variant="soft"
            class="min-h-11"
          >
            Edit then publish
          </.button>
          <.button
            :if={@editing}
            id="proposal-stop-edit"
            type="button"
            phx-click="cancel_edit"
            variant="soft"
            class="min-h-11"
          >
            Stop editing
          </.button>
          <.button
            id="proposal-dismiss"
            type="submit"
            name="action"
            value="dismiss"
            variant="soft"
            disabled={blank?(@quality["reason"])}
            class="min-h-11"
          >
            Dismiss
          </.button>
          <span class="text-xs/5 text-pretty text-mist-600 dark:text-mist-400">
            Take publishes it as your version, keeping who wrote each reason. Dismiss needs a
            reason; leave the quality form empty there, or complete every answer.
          </span>
        </div>
      </.form>
    </section>
    """
  end

  defp published_items(%{published_id: id, versions: versions}, candidates)
       when is_integer(id) do
    case Enum.find(versions, &(&1.version.id == id)) do
      nil ->
        []

      v ->
        for item <- Enum.sort_by(v.items, &{&1.role != :lead, &1.position}) do
          %{
            item: item,
            key: Compositions.reference_key(Compositions.reference(item)),
            label: item_label(item, candidates)
          }
        end
    end
  end

  defp published_items(_record, _candidates), do: []

  defp mark_actors(composition) do
    ids =
      [
        composition.mode_set_by_actor_id
        | Enum.map(composition.kept_items, & &1["marked_by_actor_id"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Compositions.actor_labels(ids)
  end

  defp mark_date(%{"marked_at" => at}) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _offset} -> date(dt)
      _bad -> at
    end
  end

  defp mark_date(_mark), do: ""

  # An item by what the screen calls its candidate, else by its reference.
  defp item_label(item, candidates) do
    key = candidates && item_key(item, candidates)
    candidate = key && Candidates.find(candidates, key)

    case candidate do
      %{} = c -> headline(c)
      nil -> "#{item.item_kind} #{item.item_object_id || item.catalog_identity}"
    end
  end

  defp slot_id(item), do: item |> QualityForm.slot() |> String.replace(":", "-")

  defp answer(quality, item, question),
    do: get_in(quality, ["answers", QualityForm.slot(item), question])

  defp complete?(view, quality) do
    case QualityForm.build(view.items, quality["answers"], quality["note"], nil) do
      {:ok, %{} = form} -> QualityForm.complete?(form)
      _incomplete -> false
    end
  end

  defp blank?(text), do: is_nil(text) or String.trim(text) == ""

  attr :refresh, :any, required: true

  # What the refresh clock says that the owner should act on (#259 §2.3): an
  # input changed since the last check, the last check found an editor is
  # needed, or a check failed. A withdrawn page says so in its standing.
  defp clock(assigns) do
    ~H"""
    <div
      :if={clock_lines?(@refresh)}
      id="curation-clock"
      class="flex flex-col gap-2 rounded-xl bg-amber-50 px-5 py-4 text-sm/7 text-pretty text-amber-950 dark:bg-amber-400/10 dark:text-amber-100"
    >
      <p :if={changed?(@refresh)} id="curation-clock-changed">
        <span aria-hidden="true">⚠</span>
        <span class="font-medium">Inputs changed since the last assessment:</span>
        {Refresh.change_label(@refresh.dirty_reason)}. {queued_line(@refresh)}; nothing changes
        on the page until you or an editor publishes a new version.
      </p>
      <p :if={needs_editor?(@refresh)} id="curation-clock-editor">
        <span class="font-medium">The last check found an editor is needed</span>
        ({editor_reason(@refresh.last_outcome_reason)}). The inputs were checked, not judged:
        while the editor is enabled, such a check goes on to the editor.
      </p>
      <p :if={@refresh.state == :deferred} id="curation-clock-deferred">
        <span class="font-medium">The last check failed</span>{if @refresh.last_error,
          do: " (#{@refresh.last_error})"}; it is retried after {CurationLive.short_date(
          @refresh.next_retry_at
        )}.
      </p>
    </div>
    """
  end

  defp clock_lines?(nil), do: false
  defp clock_lines?(%{state: :suppressed}), do: false

  defp clock_lines?(refresh),
    do: changed?(refresh) or needs_editor?(refresh) or refresh.state == :deferred

  # A publication makes the next check due without changing an input.
  defp changed?(%{dirty_at: %DateTime{}, dirty_reason: reason, state: state}),
    do: state != :suppressed and reason != "published"

  defp changed?(_refresh), do: false

  defp needs_editor?(%{last_outcome: :needs_editor, dirty_at: nil, state: state}),
    do: state not in [:suppressed, :deferred]

  defp needs_editor?(_refresh), do: false

  defp queued_line(%{state: state}) when state in [:queued, :running],
    do: "Re-assessment is queued"

  defp queued_line(_refresh), do: "Re-assessment is queued on the page's next visit"

  defp editor_reason("due"), do: "the periodic re-assessment came due"
  defp editor_reason("requested"), do: "a proposal was requested"

  defp editor_reason("packet_refused:" <> reason),
    do: "but no packet could be built: #{reason}"

  defp editor_reason("nothing_accepted"), do: "nothing has been accepted yet"
  defp editor_reason("fingerprint_version"), do: "the inputs are now identified differently"
  defp editor_reason(_changed), do: "the inputs changed"

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
          <span
            :if={v.version.origin == :model}
            class="ml-1 rounded-full bg-sky-100 px-2 py-0.5 text-xs/5 text-sky-900 dark:bg-sky-400/20 dark:text-sky-100"
          >
            proposal · attempt {"##{v.version.attempt_id}"}
          </span>
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

  defp not_current?({:stale, _}), do: true
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

  defp blocker_text(:quality_form_incomplete),
    do: "Fill the quality form: a yes or a no for every question of every item."

  defp blocker_text(:editing_proposal),
    do: "Editing a proposal publishes it or stops; it is not saved as a draft."

  defp blocker_text({:kept_item_missing, key}),
    do: "The proposal leaves out #{key}, which you keep: Edit then publish instead."

  defp blocker_text({:proposal_resolved, state}), do: "This proposal was already #{state}."
  defp blocker_text(:proposal_needs_take), do: "A proposal is taken, never accepted as it is."

  defp blocker_text(:proposal_not_publishable),
    do: "A proposal is taken, never published as it is."

  defp blocker_text(:not_a_proposal), do: "That version is not a proposal."
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
