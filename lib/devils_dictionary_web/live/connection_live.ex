defmodule DevilsDictionaryWeb.ConnectionLive do
  @moduledoc """
  `/connections/:id` — one claim, and `/connect` — proposing one.

  #74 §F's last two wireframes, and the two halves of its milestone 3: *"create
  one attributed artifact→sense/concept relationship with exact endpoints,
  context, rationale and evidence"* and *"show that same relationship from both
  endpoints with the same status and provenance"*.

  The second is not something this page arranges. There is **one directional
  row**; the inverse is derived for display. #73 is explicit that an
  independently editable mirror edge is how the two halves of one fact come
  apart, so the word page, the thing page and this page are three renderings of
  the same row and cannot disagree — including about whether it is visible,
  because they all read through `Claims.incoming/2` and `outgoing/2`.

  ## The composer

  Names help discovery; **selected ids determine endpoints** (#74 §F). So the
  form searches by name and submits object ids, the relation list offers only
  the predicates whose endpoint rules the chosen subject can actually satisfy,
  and a claim with no rationale is not accepted — an assertion nobody explained
  is one nobody can review.

  A submission is `needs_review` because that is what no review means, not
  because anything writes it. And it is attributed twice: `submitted_by_actor_id`
  is the account, `origin_actor_id` is who is claiming it. A curator account
  claiming to be a known author is not automatically linked to that author —
  #74 §B, and the reason those are two columns.
  """

  use DevilsDictionaryWeb, :live_view

  import Ecto.Query

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{Connection, Contributions}
  alias DevilsDictionary.{Encyclopedia, Lexicon, Markdown, Registry, Repo}

  on_mount {DevilsDictionaryWeb.UserAuth, :mount_current_scope}

  @results 8

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       connection: nil,
       id: nil,
       contributor: Contributions.internal_contributor?(socket.assigns[:current_scope]),
       reviewer: Contributions.reviewer?(socket.assigns[:current_scope]),
       editable: false,
       review_items: [],
       review_form: to_form(%{"reason" => ""}),
       edit_form: to_form(%{"rationale" => "", "change_reason" => ""}),
       challenge_form: to_form(%{"change_reason" => ""})
     )
     |> assign(
       subject: nil,
       object: nil,
       predicate: nil,
       rationale: "",
       locator: "",
       claimant_mode: "me",
       claimant: nil,
       language_tag: "",
       valid_from: "",
       valid_to: ""
     )
     |> assign(subject_query: "", object_query: "")
     |> assign(
       predicates: [],
       error: nil,
       context: nil,
       context_query: "",
       jurisdiction: nil,
       jurisdiction_query: "",
       evidence: nil,
       evidence_query: "",
       evidence_items: %{},
       evidence_form:
         to_form(%{"evidence_role" => "supports", "locator" => "", "attribution_text" => ""}),
       claimant_query: "",
       local_open: false,
       local_author: nil,
       local_author_query: "",
       local_kind: "artifact",
       local_form:
         to_form(%{
           "entity_kind" => "artifact",
           "preferred_label" => "",
           "target_role" => "subject"
         }),
       contribution_form:
         to_form(%{
           "rationale" => "",
           "locator" => "",
           "claimant" => "me",
           "language_tag" => "",
           "valid_from" => "",
           "valid_to" => ""
         })
     )
     |> stream(:subject_hits, [], dom_id: &"subject-result-#{&1.object_id}")
     |> stream(:object_hits, [], dom_id: &"object-result-#{&1.object_id}")
     |> stream(:context_hits, [], dom_id: &"context-result-#{&1.object_id}")
     |> stream(:jurisdiction_hits, [], dom_id: &"jurisdiction-result-#{&1.object_id}")
     |> stream(:claimant_hits, [], dom_id: &"claimant-result-#{&1.object_id}")
     |> stream(:author_hits, [], dom_id: &"author-result-#{&1.object_id}")
     |> stream(:duplicate_hits, [], dom_id: &"duplicate-result-#{&1.object_id}")
     |> stream(:selected_evidence, [], dom_id: & &1.id)
     |> stream(:evidence_hits, [], dom_id: &"evidence-result-#{&1.object_id}")}
  end

  # ── the detail page ───────────────────────────────────────────────────────

  @impl true
  def handle_params(params, _uri, %{assigns: %{live_action: action}} = socket)
      when action in [:show, :edit, :challenge] do
    reviewer = Contributions.reviewer?(socket.assigns[:current_scope])

    socket =
      assign(socket,
        reviewer: reviewer,
        contributor: Contributions.internal_contributor?(socket.assigns[:current_scope])
      )

    with {id, ""} <- Integer.parse(params["id"] || ""),
         {:ok, revision} <- revision_number(params["revision"]) do
      connection =
        Connection.build(id,
          revision: revision,
          visibility: if(reviewer, do: :internal, else: :public)
        )

      editable = connection && Contributions.can_revise?(socket.assigns[:current_scope], id)

      edit_form =
        to_form(%{
          "rationale" => connection && connection.revision.rationale,
          "change_reason" => "",
          "language_tag" => connection && connection.revision.language_tag,
          "valid_from" => connection && date_value(connection.revision.valid_from),
          "valid_to" => connection && date_value(connection.revision.valid_to)
        })

      {:noreply,
       assign(socket,
         id: id,
         connection: connection,
         context: connection && connection.context,
         jurisdiction:
           connection && connection.revision.jurisdiction_entity_id &&
             Connection.endpoint(connection.revision.jurisdiction_entity_id),
         review_items:
           if(connection, do: Contributions.context_items(connection.revision), else: []),
         editable: editable,
         edit_form: edit_form,
         challenge_form: to_form(%{"change_reason" => ""}),
         page_title: "#{action} connection ##{id}"
       )
       |> maybe_reject_edit(action, editable, id)}
    else
      _ -> {:noreply, assign(socket, connection: nil, page_title: "no such connection")}
    end
  end

  def handle_params(params, _uri, socket) do
    subject = preselected_subject(params["subject"])

    object = preselected_subject(params["object"])
    predicates = predicates_for(subject)

    predicate =
      Enum.find_value(predicates, fn option ->
        if option.key == params["predicate"], do: option.key
      end)

    object =
      if object && predicate && valid_object_hits([object], subject, predicate) != [],
        do: object,
        else: nil

    rationale = String.trim(params["rationale"] || "")
    locator = String.trim(params["evidence_locator"] || "")

    {evidence_items, evidence_rows} =
      preselected_evidence(params["evidence_revision"], locator)

    {:noreply,
     socket
     |> assign(
       page_title: "propose a connection",
       subject: subject,
       object: object,
       predicate: predicate,
       predicates: predicates,
       rationale: rationale,
       locator: locator,
       evidence_items: evidence_items,
       contribution_form:
         to_form(%{
           "rationale" => rationale,
           "locator" => locator,
           "claimant" => "me",
           "language_tag" => "",
           "valid_from" => "",
           "valid_to" => ""
         })
     )
     |> stream(:selected_evidence, evidence_rows, reset: true)}
  end

  defp preselected_subject(nil), do: nil

  defp preselected_subject(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> Connection.endpoint(id)
      _ -> nil
    end
  end

  defp preselected_subject(_value), do: nil

  defp preselected_evidence(nil, _locator), do: {%{}, []}

  defp preselected_evidence(value, locator) when is_binary(value) do
    with {id, ""} when id > 0 <- Integer.parse(value),
         true <- locator != "",
         true <-
           Repo.exists?(
             from revision in DevilsDictionary.Corpus.SourceRecordRevision,
               where: revision.id == ^id
           ) do
      item = %{
        id: "selected-evidence-source-#{id}",
        object_id: nil,
        label: "Artsy source observation",
        detail: "Direct provider assignment retained for review",
        target: %{source_record_revision_id: id},
        evidence_role: "supports",
        locator: locator,
        attribution_text: "Artsy direct artwork gene assignment"
      }

      {%{item.id => item}, [item]}
    else
      _ -> {%{}, []}
    end
  end

  defp preselected_evidence(_value, _locator), do: {%{}, []}

  defp revision_number(nil), do: {:ok, nil}

  defp revision_number(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp maybe_reject_edit(socket, :edit, false, id) do
    socket
    |> put_flash(:error, "Only the original submitter or a reviewer can revise this connection.")
    |> push_navigate(to: ~p"/connections/#{id}")
  end

  defp maybe_reject_edit(socket, _action, _editable, _id), do: socket

  # ── the composer ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("search-subject", %{"q" => q}, socket) do
    {:noreply,
     socket |> assign(:subject_query, q) |> stream(:subject_hits, search(q), reset: true)}
  end

  def handle_event("search-object", %{"q" => q}, socket) do
    hits = valid_object_hits(search(q), socket.assigns.subject, socket.assigns.predicate)
    {:noreply, socket |> assign(:object_query, q) |> stream(:object_hits, hits, reset: true)}
  end

  def handle_event("search-context", %{"q" => q}, socket) do
    {:noreply,
     socket |> assign(:context_query, q) |> stream(:context_hits, search(q), reset: true)}
  end

  def handle_event("pick-context", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:context, Connection.endpoint(String.to_integer(id)))
     |> stream(:context_hits, [], reset: true)}
  end

  def handle_event("search-jurisdiction", %{"q" => q}, socket) do
    hits = Enum.filter(search(q), &(&1.kind == :entity))

    {:noreply,
     socket
     |> assign(:jurisdiction_query, q)
     |> stream(:jurisdiction_hits, hits, reset: true)}
  end

  def handle_event("pick-jurisdiction", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:jurisdiction, Connection.endpoint(String.to_integer(id)))
     |> stream(:jurisdiction_hits, [], reset: true)}
  end

  def handle_event("search-claimant", %{"q" => q}, socket) do
    hits = Enum.filter(search(q), &claimant_endpoint?/1)

    {:noreply, socket |> assign(:claimant_query, q) |> stream(:claimant_hits, hits, reset: true)}
  end

  def handle_event("pick-claimant", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:claimant, Connection.endpoint(String.to_integer(id)))
     |> assign(:claimant_mode, "selected")
     |> stream(:claimant_hits, [], reset: true)}
  end

  def handle_event("choose-claimant", %{"mode" => mode}, socket)
      when mode in ["me", "unknown", "selected"] do
    {:noreply,
     socket
     |> assign(:claimant_mode, mode)
     |> then(fn socket ->
       if mode == "selected", do: socket, else: assign(socket, :claimant, nil)
     end)}
  end

  def handle_event("search-author", %{"q" => q}, socket) do
    hits = Enum.filter(search(q), &claimant_endpoint?/1)

    {:noreply,
     socket |> assign(:local_author_query, q) |> stream(:author_hits, hits, reset: true)}
  end

  def handle_event("toggle-local", _params, socket) do
    {:noreply, assign(socket, :local_open, !socket.assigns.local_open)}
  end

  def handle_event("pick-author", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:local_author, Connection.endpoint(String.to_integer(id)))
     |> stream(:author_hits, [], reset: true)}
  end

  def handle_event("search-evidence", %{"q" => q}, socket) do
    hits = Enum.filter(search(q), &(&1.kind in [:content, :sense]))
    {:noreply, socket |> assign(:evidence_query, q) |> stream(:evidence_hits, hits, reset: true)}
  end

  def handle_event("pick-evidence", %{"id" => id}, socket) do
    object_id = String.to_integer(id)
    endpoint = Connection.endpoint(object_id)

    {:noreply,
     socket
     |> assign(:evidence, Map.put(endpoint, :target, Contributions.revision_target(object_id)))
     |> stream(:evidence_hits, [], reset: true)}
  end

  def handle_event("pick-subject", %{"id" => id}, socket) do
    subject = Connection.endpoint(String.to_integer(id))

    {:noreply,
     socket
     |> assign(:subject, subject)
     |> stream(:subject_hits, [], reset: true)
     |> assign(:predicate, nil)
     |> assign(:predicates, predicates_for(subject))}
  end

  def handle_event("pick-object", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:object, Connection.endpoint(String.to_integer(id)))
     |> stream(:object_hits, [], reset: true)}
  end

  def handle_event("pick-predicate", %{"key" => key}, socket) do
    {:noreply,
     socket
     |> assign(:predicate, key)
     |> assign(:object, nil)
     |> stream(:object_hits, [], reset: true)}
  end

  def handle_event("change", %{"rationale" => rationale} = params, socket) do
    {:noreply,
     assign(socket,
       rationale: rationale,
       locator: params["locator"] || "",
       claimant_mode: params["claimant"] || socket.assigns.claimant_mode,
       language_tag: params["language_tag"] || "",
       valid_from: params["valid_from"] || "",
       valid_to: params["valid_to"] || "",
       contribution_form: to_form(params)
     )}
  end

  def handle_event("add-evidence", params, socket) do
    with %{target: target} = evidence when is_map(target) <- socket.assigns.evidence,
         locator when locator != "" <- String.trim(params["locator"] || ""),
         true <- map_size(socket.assigns.evidence_items) < 12 do
      id = "selected-evidence-#{System.unique_integer([:positive])}"

      item = %{
        id: id,
        object_id: evidence.object_id,
        label: evidence.label,
        detail: evidence.detail,
        target: target,
        evidence_role:
          if(socket.assigns.live_action == :challenge,
            do: "contradicts",
            else: params["evidence_role"] || "supports"
          ),
        locator: locator,
        attribution_text: String.trim(params["attribution_text"] || "")
      }

      {:noreply,
       socket
       |> assign(:evidence_items, Map.put(socket.assigns.evidence_items, id, item))
       |> assign(:evidence, nil)
       |> assign(
         :evidence_form,
         to_form(%{
           "evidence_role" => "supports",
           "locator" => "",
           "attribution_text" => ""
         })
       )
       |> stream_insert(:selected_evidence, item)}
    else
      _ ->
        {:noreply,
         socket
         |> assign(:error, "Choose a source meaning or passage and give its exact locator.")
         |> put_flash(:error, "Choose a source meaning or passage and give its exact locator.")}
    end
  end

  def handle_event("remove-evidence", %{"id" => id}, socket) do
    case Map.pop(socket.assigns.evidence_items, id) do
      {nil, _items} ->
        {:noreply, socket}

      {item, items} ->
        {:noreply,
         socket
         |> assign(:evidence_items, items)
         |> stream_delete(:selected_evidence, item)}
    end
  end

  def handle_event("change-local", params, socket) do
    label = String.trim(params["preferred_label"] || "")

    duplicates =
      if byte_size(label) < 2, do: [], else: Contributions.duplicate_candidates(label)

    {:noreply,
     socket
     |> assign(:local_kind, params["entity_kind"] || "artifact")
     |> assign(:local_form, to_form(params))
     |> stream(:duplicate_hits, duplicates, reset: true)}
  end

  def handle_event("create-local", params, socket) do
    params =
      if socket.assigns.local_author,
        do: Map.put(params, "author_entity_id", socket.assigns.local_author.object_id),
        else: params

    case Contributions.create_local_entity(socket.assigns.current_scope, params) do
      {:ok, entity} ->
        endpoint = Connection.endpoint(entity.object_id)

        socket =
          case params["target_role"] do
            "object" -> assign(socket, :object, endpoint)
            _ -> choose_subject(socket, endpoint)
          end

        {:noreply,
         socket
         |> put_flash(:info, "Local #{entity.entity_kind} created and selected.")
         |> assign(:local_open, false)
         |> assign(:local_author, nil)
         |> stream(:duplicate_hits, [], reset: true)}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           error: local_error(reason),
           local_kind: params["entity_kind"] || socket.assigns.local_kind,
           local_form: to_form(params)
         )}
    end
  end

  def handle_event("use-local-candidate", %{"id" => id, "role" => role}, socket) do
    endpoint = Connection.endpoint(String.to_integer(id))

    socket =
      case role do
        "object" -> assign(socket, :object, endpoint)
        _ -> choose_subject(socket, endpoint)
      end

    {:noreply, stream(socket, :duplicate_hits, [], reset: true)}
  end

  def handle_event("submit", params, socket) do
    socket =
      assign(socket,
        rationale: params["rationale"] || socket.assigns.rationale,
        locator: params["locator"] || socket.assigns.locator,
        language_tag: params["language_tag"] || socket.assigns.language_tag,
        valid_from: params["valid_from"] || socket.assigns.valid_from,
        valid_to: params["valid_to"] || socket.assigns.valid_to
      )

    %{subject: subject, object: object, predicate: predicate, rationale: rationale} =
      socket.assigns

    cond do
      is_nil(subject) or is_nil(object) or is_nil(predicate) ->
        {:noreply, assign(socket, :error, "Choose a subject, a relation and an object.")}

      String.trim(rationale) == "" ->
        {:noreply,
         assign(socket, :error, "Say why. A claim nobody explained is one nobody can review.")}

      true ->
        propose(socket, subject, predicate, object, rationale)
    end
  end

  def handle_event("review", params, socket) do
    connection = socket.assigns.connection

    result =
      if connection do
        Contributions.review(
          socket.assigns.current_scope,
          connection.assertion.id,
          connection.revision.id,
          params["decision"],
          params["reason"],
          socket.assigns.review_items
        )
      else
        {:error, :unauthorized}
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Review recorded.")
         |> push_patch(to: ~p"/connections/#{connection.assertion.id}")}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Review not saved. Check your reviewer access, enter a reason, and reload if the claim has changed."
         )}
    end
  end

  def handle_event("revise", params, socket) do
    connection = socket.assigns.connection

    attrs = %{
      rationale: params["rationale"],
      change_reason: params["change_reason"],
      language_tag: params["language_tag"],
      valid_from: parse_date(params["valid_from"]),
      valid_to: parse_date(params["valid_to"]),
      jurisdiction_entity_id:
        socket.assigns.jurisdiction && socket.assigns.jurisdiction.object_id,
      context_object_id: socket.assigns.context && socket.assigns.context.object_id
    }

    result =
      Contributions.revise(
        socket.assigns.current_scope,
        connection.assertion.id,
        connection.revision.id,
        attrs,
        evidence_params(socket)
      )

    mutation_result(socket, result, connection.assertion.id, "Revision saved for review.")
  end

  def handle_event("challenge", params, socket) do
    connection = socket.assigns.connection

    result =
      Contributions.challenge(
        socket.assigns.current_scope,
        connection.assertion.id,
        connection.revision.id,
        params["change_reason"],
        evidence_params(socket)
      )

    mutation_result(
      socket,
      result,
      connection.assertion.id,
      "Challenge and counterevidence saved."
    )
  end

  defp propose(socket, subject, predicate, object, rationale) do
    claimant =
      case socket.assigns.claimant_mode do
        "unknown" -> :unknown
        "selected" -> socket.assigns.claimant && socket.assigns.claimant.object_id
        _ -> :me
      end

    case Contributions.propose(
           socket.assigns.current_scope,
           subject.object_id,
           predicate,
           object.object_id,
           %{
             rationale: rationale,
             claimant: claimant,
             context_object_id: socket.assigns.context && socket.assigns.context.object_id,
             jurisdiction_entity_id:
               socket.assigns.jurisdiction && socket.assigns.jurisdiction.object_id,
             language_tag: socket.assigns.language_tag,
             valid_from: parse_date(socket.assigns.valid_from),
             valid_to: parse_date(socket.assigns.valid_to)
           },
           evidence_params(socket, include_pending: true)
         ) do
      {:ok, assertion} ->
        {:noreply,
         socket
         |> put_flash(:info, "Proposed with attribution; awaiting review.")
         |> push_navigate(to: ~p"/connections/#{assertion.id}")}

      {:error, _} ->
        {:noreply,
         assign(
           socket,
           :error,
           "Could not save. Select valid endpoints and a source meaning or passage for any evidence locator."
         )}
    end
  end

  # Names help discovery. Words come from the trigram index, things from their
  # label — and the id, not the name, is what the form submits.
  defp search(q) when byte_size(q) < 2, do: []

  defp search(q) do
    words =
      q
      |> Lexicon.search(limit: @results)
      |> Enum.map(
        &%{kind: :lexeme, object_id: &1.lexeme_id, label: &1.lemma, detail: "word · #{&1.pos}"}
      )

    things =
      Repo.all(
        from e in Registry.Entity,
          where: ilike(e.preferred_label, ^"%#{q}%"),
          order_by: e.preferred_label,
          limit: @results
      )
      |> Enum.map(fn e ->
        %{
          kind: :entity,
          object_id: e.object_id,
          label: e.preferred_label,
          detail: "thing · #{e.entity_kind}",
          entity_kind: e.entity_kind
        }
      end)

    senses =
      Repo.all(
        from s in Registry.Sense,
          join: r in Registry.SenseRevision,
          on: r.sense_id == s.object_id and r.is_current,
          join: l in Registry.Lexeme,
          on: l.object_id == s.lexeme_id,
          join: src in assoc(s, :source),
          where: ilike(l.lemma, ^"%#{q}%"),
          order_by: [l.lemma, s.object_id],
          limit: @results,
          select: %{
            kind: :sense,
            object_id: s.object_id,
            label: l.lemma,
            detail: fragment("? || ': ' || ?", src.name, r.gloss)
          }
      )

    content =
      Repo.all(
        from c in Registry.ContentItem,
          join: r in Registry.ContentRevision,
          on: r.content_id == c.object_id and r.is_current,
          where: ilike(r.headword, ^"%#{q}%") or ilike(r.body, ^"%#{q}%"),
          order_by: c.object_id,
          limit: @results,
          select: %{
            kind: :content,
            object_id: c.object_id,
            label: coalesce(r.headword, fragment("left(?, 60)", r.body)),
            detail: fragment("left(?, 120)", r.body),
            content_kind: c.content_kind
          }
      )

    words ++ things ++ senses ++ content
  end

  # Only the relations this subject can actually be the subject of. #74 §F:
  # "Only predicates valid for subject type" — read off the endpoint rules
  # rather than from a list somebody has to keep in step with them.
  defp predicates_for(nil), do: []

  defp predicates_for(subject) do
    kind = to_string(subject.kind)
    subkind = subject_subkind(subject)

    Repo.all(
      from p in Claims.Predicate,
        join: r in Claims.PredicateEndpointRule,
        on: r.predicate_id == p.id,
        where: r.subject_kind == ^kind,
        where: r.subject_subkind in ^[subkind, "-"],
        distinct: true,
        order_by: p.key,
        select: %{key: p.key, label: p.forward_label, description: p.description}
    )
  end

  defp subject_subkind(%{kind: :entity, entity_kind: kind}), do: to_string(kind)
  defp subject_subkind(%{kind: :content, content_kind: kind}), do: to_string(kind)
  defp subject_subkind(_), do: "-"

  defp valid_object_hits(_hits, nil, _predicate), do: []
  defp valid_object_hits(_hits, _subject, nil), do: []

  defp valid_object_hits(hits, subject, predicate) do
    subject_kind = to_string(subject.kind)
    subject_subkind = subject_subkind(subject)

    rules =
      Claims.endpoint_rules(predicate)
      |> Enum.filter(fn rule ->
        rule.subject_kind == subject_kind and
          rule.subject_subkind in [subject_subkind, "-"]
      end)

    Enum.filter(hits, fn hit ->
      {kind, subkind} = endpoint_kind(hit)

      Enum.any?(rules, fn rule ->
        rule.object_kind == kind and rule.object_subkind in [subkind, "-"]
      end)
    end)
  end

  defp endpoint_kind(%{kind: :entity, entity_kind: kind}), do: {"entity", to_string(kind)}
  defp endpoint_kind(%{kind: :content, content_kind: kind}), do: {"content", to_string(kind)}
  defp endpoint_kind(%{kind: kind}), do: {to_string(kind), "-"}

  defp claimant_endpoint?(%{kind: :entity, entity_kind: kind}),
    do: kind in [:person, :organization]

  defp claimant_endpoint?(_), do: false

  defp evidence_params(socket, opts \\ []) do
    selected =
      socket.assigns.evidence_items
      |> Map.values()
      |> Enum.map(fn item ->
        item.target
        |> Map.put(:evidence_role, item.evidence_role)
        |> Map.put(:locator, item.locator)
        |> Map.put(:attribution_text, item.attribution_text)
      end)

    pending =
      if opts[:include_pending] && socket.assigns.evidence &&
           String.trim(socket.assigns.locator || "") != "" do
        [
          socket.assigns.evidence.target
          |> Map.put(:evidence_role, :supports)
          |> Map.put(:locator, socket.assigns.locator)
        ]
      else
        []
      end

    selected ++ pending
  end

  defp choose_subject(socket, endpoint) do
    socket
    |> assign(:subject, endpoint)
    |> assign(:predicate, nil)
    |> assign(:predicates, predicates_for(endpoint))
    |> stream(:subject_hits, [], reset: true)
  end

  defp mutation_result(socket, {:ok, _revision}, assertion_id, message) do
    {:noreply,
     socket
     |> put_flash(:info, message)
     |> push_navigate(to: ~p"/connections/#{assertion_id}")}
  end

  defp mutation_result(socket, {:error, _reason}, _assertion_id, _message) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Change not saved. Check access, include a reason and exact citation locator, then reload if the claim changed."
     )}
  end

  defp parse_date(value) when value in [nil, ""], do: nil
  defp parse_date(%DateTime{} = value), do: value

  defp parse_date(value) do
    with {:ok, date} <- Date.from_iso8601(value),
         {:ok, datetime} <- DateTime.new(date, ~T[00:00:00], "Etc/UTC") do
      datetime
    else
      _ -> value
    end
  end

  defp date_value(nil), do: ""
  defp date_value(%DateTime{} = value), do: value |> DateTime.to_date() |> Date.to_iso8601()

  defp local_error(:external_id_evidence_required),
    do: "An external ID needs its namespace, ID and an http(s) source URL."

  defp local_error(:invalid_author), do: "Choose a person or organization as the work's creator."

  defp local_error(:unauthorized),
    do: "Your contribution access changed; reload before continuing."

  defp local_error(_),
    do: "The local object could not be created. Check its required typed fields."

  @impl true
  def render(%{live_action: :new} = assigns), do: composer(assigns)
  def render(assigns), do: detail(assigns)

  defp detail(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.container class="py-10">
        <%= if @connection == nil do %>
          <div id="no-such-connection" class="py-12">
            <.heading>No such connection</.heading>
            <.a navigate={~p"/"} class="mt-6">Start somewhere else</.a>
          </div>
        <% else %>
          <header id="connection-header">
            <.eyebrow>connection</.eyebrow>
            <p class="mt-2 text-2xl/9">
              <.endpoint_link endpoint={@connection.subject} />
              <span class="text-mist-500">— {@connection.predicate.forward_label} →</span>
              <.endpoint_link endpoint={@connection.object} />
            </p>
            <p class="mt-2 text-sm/7 text-mist-500">
              Claim #{@connection.assertion.id} · revision {@connection.revision.revision_number}
              <span :if={@connection.revision.lifecycle_state != :active}>
                · {@connection.revision.lifecycle_state}
              </span>
            </p>
          </header>

          <dl id="connection-attribution" class="mt-8 grid grid-cols-1 gap-2 text-sm/7 sm:grid-cols-2">
            <div>
              <dt class="text-mist-500">Original claimant</dt>
              <dd>{actor_label(@connection.claimant)}</dd>
            </div>
            <div>
              <dt class="text-mist-500">Submitted by</dt>
              <dd>{actor_label(@connection.submitted_by)}</dd>
            </div>
            <div>
              <dt class="text-mist-500">Review</dt>
              <dd id="connection-review">{review_label(@connection.review)}</dd>
            </div>
            <div>
              <dt class="text-mist-500">Relevance</dt>
              <dd>{@connection.score}</dd>
            </div>
            <div :if={@connection.context}>
              <dt class="text-mist-500">Context</dt>
              <dd>{@connection.context.label}</dd>
            </div>
            <div :if={@connection.revision.method}>
              <dt class="text-mist-500">Method</dt>
              <dd>
                {@connection.revision.method}
                <span :if={@connection.revision.confidence}>
                  · {@connection.revision.confidence}
                </span>
              </dd>
            </div>
          </dl>

          <section
            :if={@connection.review == :changed_since_review}
            id="connection-review-stale"
            class="mt-8 border-y border-mist-950/10 bg-mist-950/3 py-4 dark:border-white/10 dark:bg-white/5"
          >
            <p class="flex min-w-0 items-start gap-2 text-base/7 text-pretty sm:text-sm/6">
              <.icon
                name="hero-arrow-path"
                class="size-4 h-lh shrink-0 stroke-mist-500"
              />
              <span class="min-w-0">
                The displayed endpoint, evidence, or attribution changed after review. The historical
                decision is retained, but it does not approve this displayed version.
              </span>
            </p>
          </section>

          <section :if={@connection.revision.rationale} id="connection-rationale" class="mt-8">
            <.eyebrow>rationale</.eyebrow>
            <.text class="mt-2">{@connection.revision.rationale}</.text>
          </section>

          <.evidence_list
            :if={@connection.evidence != []}
            id="connection-evidence"
            label="evidence"
            evidence={@connection.evidence}
          />

          <.evidence_list
            :if={@connection.counterevidence != []}
            id="connection-counterevidence"
            label="counterevidence"
            evidence={@connection.counterevidence}
          />

          <p class="mt-4 max-w-2xl text-sm/7 text-mist-500">
            Citations record what supports or contradicts the claim. Relevance votes answer a
            separate question and never turn a source into editorial approval.
          </p>

          <div
            :if={@contributor && @live_action == :show}
            id="connection-actions"
            class="mt-8 flex flex-wrap gap-4 text-sm/7"
          >
            <.a :if={@editable} navigate={~p"/connections/#{@connection.assertion.id}/edit"}>
              Revise this connection
            </.a>
            <.a navigate={~p"/connections/#{@connection.assertion.id}/challenge"}>
              Challenge with counterevidence
            </.a>
          </div>

          <section
            :if={@live_action in [:edit, :challenge]}
            id="connection-mutation"
            class="mt-10 border-y border-mist-950/10 py-8 dark:border-white/10"
          >
            <.eyebrow>
              {if(@live_action == :edit, do: "revise connection", else: "challenge connection")}
            </.eyebrow>
            <.subheading class="mt-2">
              {if(@live_action == :edit,
                do: "Create a new accountable revision",
                else: "Add counterevidence without erasing the claim"
              )}
            </.subheading>
            <.text class="mt-3 max-w-2xl">
              The current version stays in history. Its reviews and relevance votes remain attached
              to that exact version and do not approve this new one.
            </.text>

            <div class="mt-6 space-y-6">
              <.picker
                id="evidence"
                label={
                  if(@live_action == :edit, do: "Additional exact citation", else: "Counterevidence")
                }
                query={@evidence_query}
                hits={@streams.evidence_hits}
                chosen={@evidence}
                search="search-evidence"
                pick="pick-evidence"
              />

              <.form
                for={@evidence_form}
                id="mutation-evidence-form"
                phx-submit="add-evidence"
                class="grid gap-4 sm:grid-cols-2"
              >
                <.input
                  field={@evidence_form[:evidence_role]}
                  type="hidden"
                  value={if(@live_action == :challenge, do: "contradicts", else: "supports")}
                />
                <.input
                  field={@evidence_form[:locator]}
                  label="Exact locator"
                  placeholder="Page, paragraph or timestamp"
                  required
                />
                <.input
                  field={@evidence_form[:attribution_text]}
                  label="Citation attribution"
                />
                <div class="self-end">
                  <.button id="mutation-evidence-add" type="submit">Add citation</.button>
                </div>
              </.form>

              <.selected_evidence evidence={@streams.selected_evidence} />

              <.form
                :if={@live_action == :edit}
                for={@edit_form}
                id="connection-edit-form"
                phx-submit="revise"
                class="space-y-4"
              >
                <.input field={@edit_form[:rationale]} type="textarea" label="Revised rationale" />
                <.input
                  field={@edit_form[:change_reason]}
                  type="textarea"
                  label="Why this changed"
                  required
                />
                <div class="grid gap-4 sm:grid-cols-3">
                  <.input field={@edit_form[:language_tag]} label="Language context" />
                  <.input field={@edit_form[:valid_from]} type="date" label="Applies from" />
                  <.input field={@edit_form[:valid_to]} type="date" label="Applies until" />
                </div>
                <.button id="connection-edit-submit" type="submit">Save new revision</.button>
              </.form>

              <.form
                :if={@live_action == :challenge}
                for={@challenge_form}
                id="connection-challenge-form"
                phx-submit="challenge"
                class="space-y-4"
              >
                <.input
                  field={@challenge_form[:change_reason]}
                  type="textarea"
                  label="Why this connection is challenged"
                  required
                />
                <.button id="connection-challenge-submit" type="submit">Submit challenge</.button>
              </.form>
            </div>
          </section>

          <.form
            :if={@reviewer}
            for={@review_form}
            id="connection-review-form"
            phx-submit="review"
            class="mt-8 space-y-3"
          >
            <.input field={@review_form[:reason]} type="textarea" label="Review reason" required />
            <.button id="review-accept" name="decision" value="accepted" type="submit">Accept</.button>
            <.button id="review-dispute" name="decision" value="disputed" type="submit">Dispute</.button>
            <.button id="review-reject" name="decision" value="rejected" type="submit">Reject</.button>
          </.form>
          <section
            id="connection-history"
            class="mt-10 border-t border-mist-950/10 pt-8 dark:border-white/10"
          >
            <.eyebrow>history</.eyebrow>
            <ul class="mt-2 space-y-1 text-sm/7">
              <li :for={revision <- @connection.history} id={"revision-#{revision.id}"}>
                <.a patch={
                  ~p"/connections/#{@connection.assertion.id}?revision=#{revision.revision_number}"
                }>
                  revision {revision.revision_number}
                </.a>
                <span class="text-mist-500">
                  · {revision.lifecycle_state}{if revision.is_current, do: " · current", else: ""}
                </span>
                <span :if={revision.rationale} class="text-mist-500">— {revision.rationale}</span>
              </li>
            </ul>
            <ul
              :if={@connection.reviews != []}
              id="review-history"
              role="list"
              class="mt-4 space-y-2 text-base/7 sm:text-sm/6"
            >
              <li :for={review <- @connection.reviews} id={"review-#{review.id}"}>
                {review.decision}
                <span class="text-mist-500">
                  · {actor_label(review.reviewer_actor)} · against exact revision {review.assertion_revision_id}
                </span>
                <span :if={review.reason} class="text-mist-500">— {review.reason}</span>
              </li>
            </ul>
          </section>
        <% end %>
      </.container>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :evidence, :list, required: true

  defp evidence_list(assigns) do
    ~H"""
    <section id={@id} class="mt-8">
      <.eyebrow>{@label}</.eyebrow>
      <ul class="mt-2 space-y-1 text-sm/7">
        <li :for={item <- @evidence} id={"#{@id}-#{item.id}"}>
          <.a navigate={evidence_path(item)}>Open exact cited revision</.a>
          <span :if={item.locator}>{item.locator}</span>
          <span :if={item.attribution_text} class="text-mist-500">
            — {item.attribution_text}
          </span>
          <span :if={item.source_record_revision_id} class="text-mist-500">
            · source record revision {item.source_record_revision_id}
          </span>
          <span :if={item.content_revision_id} class="text-mist-500">
            · content revision {item.content_revision_id}
          </span>
          <span :if={item.sense_revision_id} class="text-mist-500">
            · sense revision {item.sense_revision_id}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  attr :evidence, :any, required: true

  defp selected_evidence(assigns) do
    ~H"""
    <section id="selected-evidence" class="border-y border-mist-950/10 py-4 dark:border-white/10">
      <.eyebrow>Selected exact citations</.eyebrow>
      <div id="selected-evidence-items" phx-update="stream" class="mt-2 space-y-3 text-sm/7">
        <p id="selected-evidence-empty" class="hidden text-mist-500 only:block">
          No citations added yet.
        </p>
        <div
          :for={{dom_id, item} <- @evidence}
          id={dom_id}
          class="flex flex-wrap items-start justify-between gap-3 border-t border-mist-950/10 pt-3 first:border-0 first:pt-0 dark:border-white/10"
        >
          <p class="min-w-0">
            <span class="font-semibold">{item.label}</span>
            <span class="text-mist-500">
              · {item.evidence_role} · {target_label(item.target)} · {item.locator}
            </span>
          </p>
          <button
            id={"remove-#{item.id}"}
            type="button"
            phx-click="remove-evidence"
            phx-value-id={item.id}
            class="shrink-0 font-semibold underline decoration-mist-400 underline-offset-4 transition-colors hover:text-red-600"
          >
            Remove
          </button>
        </div>
      </div>
    </section>
    """
  end

  defp target_label(%{content_revision_id: id}), do: "content revision #{id}"
  defp target_label(%{sense_revision_id: id}), do: "sense revision #{id}"
  defp target_label(%{source_record_revision_id: id}), do: "source record revision #{id}"

  attr :endpoint, :map, default: nil

  defp endpoint_link(assigns) do
    ~H"""
    <span :if={@endpoint == nil}>—</span>
    <.a :if={@endpoint && @endpoint.path} navigate={@endpoint.path}>{@endpoint.label}</.a>
    <span :if={@endpoint && is_nil(@endpoint.path)}>{@endpoint.label}</span>
    """
  end

  defp composer(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.container class="py-10">
        <.eyebrow>propose</.eyebrow>
        <.heading>Add a connection</.heading>
        <.text class="mt-2">
          Connect two things with an exact, reviewable claim. Names help you find them; the thing
          you pick is what the claim points at. It goes
          to review and remains visibly attributed while it awaits a decision.
        </.text>

        <p :if={@error} id="composer-error" class="mt-4 text-sm/7 text-red-600">{@error}</p>

        <div class="mt-8 space-y-8">
          <details
            id="local-entity-creator"
            open={@local_open}
            class="group border-y border-mist-950/10 py-5 dark:border-white/10"
          >
            <summary
              phx-click="toggle-local"
              class="flex cursor-pointer list-none items-center justify-between gap-4 text-sm/7 font-semibold"
            >
              Create a local person, work, artifact, event or concept
              <.icon name="hero-plus" class="size-4 transition-transform group-open:rotate-45" />
            </summary>
            <div class="mt-6 space-y-5">
              <.picker
                :if={@local_kind == "work"}
                id="author"
                label="Author or creator (optional; unknown stays unknown)"
                query={@local_author_query}
                hits={@streams.author_hits}
                chosen={@local_author}
                search="search-author"
                pick="pick-author"
              />

              <.form
                for={@local_form}
                id="local-entity-form"
                phx-change="change-local"
                phx-submit="create-local"
                class="grid gap-4 sm:grid-cols-2"
              >
                <.input
                  field={@local_form[:entity_kind]}
                  type="select"
                  label="Type"
                  options={
                    Enum.map(Contributions.local_entity_kinds(), &{Phoenix.Naming.humanize(&1), &1})
                  }
                />
                <.input
                  field={@local_form[:target_role]}
                  type="select"
                  label="Use as"
                  options={[{"Connection subject", "subject"}, {"Connection object", "object"}]}
                />
                <.input field={@local_form[:preferred_label]} label="Name or title" required />
                <.input field={@local_form[:description]} label="Description" />

                <.input
                  :if={@local_kind == "person"}
                  field={@local_form[:birth_date]}
                  type="date"
                  label="Birth date"
                />
                <.input
                  :if={@local_kind == "person"}
                  field={@local_form[:death_date]}
                  type="date"
                  label="Death date"
                />

                <.input
                  :if={@local_kind == "work"}
                  field={@local_form[:work_kind]}
                  label="Work kind"
                  placeholder="painting, poem, film…"
                />
                <.input
                  :if={@local_kind == "work"}
                  field={@local_form[:original_language]}
                  label="Original language"
                  placeholder="en or zxx"
                />
                <.input
                  :if={@local_kind == "work"}
                  field={@local_form[:first_published_year]}
                  type="number"
                  label="First published year"
                />

                <.input
                  :if={@local_kind == "event"}
                  field={@local_form[:event_start]}
                  type="date"
                  label="Event start"
                />
                <.input
                  :if={@local_kind == "event"}
                  field={@local_form[:event_end]}
                  type="date"
                  label="Event end"
                />

                <.input
                  field={@local_form[:source_url]}
                  type="url"
                  label="Source or reference URL"
                  placeholder="https://catalog.example/item"
                />
                <div class="grid grid-cols-2 gap-3">
                  <.input
                    field={@local_form[:external_namespace]}
                    label="External namespace"
                    placeholder="wikidata"
                  />
                  <.input
                    field={@local_form[:external_id]}
                    label="External ID"
                    placeholder="optional"
                  />
                </div>

                <div class="sm:col-span-2">
                  <.button id="local-entity-submit" type="submit">Create and select</.button>
                </div>
              </.form>

              <div id="duplicate-results" phx-update="stream" class="space-y-2 text-sm/7">
                <div
                  :for={{dom_id, candidate} <- @streams.duplicate_hits}
                  id={dom_id}
                  class="flex flex-wrap items-center justify-between gap-3 border-t border-mist-950/10 pt-2 dark:border-white/10"
                >
                  <span>
                    Possible duplicate: {candidate.preferred_label}
                    <span class="text-mist-500">· {candidate.entity_kind} #{candidate.object_id}</span>
                  </span>
                  <button
                    id={"use-duplicate-#{candidate.object_id}"}
                    type="button"
                    phx-click="use-local-candidate"
                    phx-value-id={candidate.object_id}
                    phx-value-role={@local_form[:target_role].value || "subject"}
                    class="font-semibold underline underline-offset-4"
                  >
                    Use existing
                  </button>
                </div>
              </div>
            </div>
          </details>

          <.picker
            id="subject"
            label="Thing being connected"
            query={@subject_query}
            hits={@streams.subject_hits}
            chosen={@subject}
            search="search-subject"
            pick="pick-subject"
          />

          <section id="composer-relation">
            <.eyebrow>Relation</.eyebrow>
            <p :if={@subject == nil} class="mt-2 text-sm/7 text-mist-500">
              Choose a subject first — only the relations it can actually take are offered.
            </p>
            <div :if={@subject} class="mt-2 flex flex-wrap gap-2">
              <button
                :for={predicate <- @predicates}
                id={"predicate-#{predicate.key}"}
                type="button"
                phx-click="pick-predicate"
                phx-value-key={predicate.key}
                class={[
                  "rounded-full border px-3 py-1 text-sm/6",
                  if(@predicate == predicate.key,
                    do:
                      "border-mist-950 bg-mist-950 text-white dark:border-white dark:bg-white dark:text-mist-950",
                    else: "border-mist-950/20 dark:border-white/20"
                  )
                ]}
              >
                {predicate.key}
              </button>
            </div>
          </section>

          <.picker
            id="object"
            label="Exact meaning or object"
            query={@object_query}
            hits={@streams.object_hits}
            chosen={@object}
            search="search-object"
            pick="pick-object"
          />

          <.picker
            id="context"
            label="Context (optional): the work, event or meaning this connection applies in"
            query={@context_query}
            hits={@streams.context_hits}
            chosen={@context}
            search="search-context"
            pick="pick-context"
          />

          <.picker
            id="jurisdiction"
            label="Jurisdiction (optional)"
            query={@jurisdiction_query}
            hits={@streams.jurisdiction_hits}
            chosen={@jurisdiction}
            search="search-jurisdiction"
            pick="pick-jurisdiction"
          />

          <section id="composer-claimant" class="space-y-3">
            <.eyebrow>Who makes this interpretation?</.eyebrow>
            <div class="flex flex-wrap gap-2">
              <button
                :for={
                  {label, mode} <- [
                    {"My account", "me"},
                    {"Cited claimant", "selected"},
                    {"Unknown", "unknown"}
                  ]
                }
                id={"claimant-#{mode}"}
                type="button"
                phx-click="choose-claimant"
                phx-value-mode={mode}
                class={[
                  "rounded-full border px-3 py-1 text-sm/6 transition-colors",
                  if(@claimant_mode == mode,
                    do:
                      "border-mist-950 bg-mist-950 text-white dark:border-white dark:bg-white dark:text-mist-950",
                    else:
                      "border-mist-950/20 hover:border-mist-950/50 dark:border-white/20 dark:hover:border-white/50"
                  )
                ]}
              >
                {label}
              </button>
            </div>
            <.picker
              :if={@claimant_mode == "selected"}
              id="claimant"
              label="Select a person or organization; your account is only the submitter"
              query={@claimant_query}
              hits={@streams.claimant_hits}
              chosen={@claimant}
              search="search-claimant"
              pick="pick-claimant"
            />
            <p :if={@claimant_mode == "unknown"} class="text-sm/7 text-mist-500">
              Claimant will be recorded as unknown, not inferred from your account.
            </p>
          </section>

          <.picker
            id="evidence"
            label="Evidence: choose an exact source meaning or passage"
            query={@evidence_query}
            hits={@streams.evidence_hits}
            chosen={@evidence}
            search="search-evidence"
            pick="pick-evidence"
          />

          <.form
            for={@evidence_form}
            id="evidence-add-form"
            phx-submit="add-evidence"
            class="grid gap-4 sm:grid-cols-2"
          >
            <.input
              field={@evidence_form[:evidence_role]}
              type="select"
              label="Citation role"
              options={[{"Supports", "supports"}, {"Contradicts", "contradicts"}]}
            />
            <.input
              field={@evidence_form[:locator]}
              label="Exact locator"
              placeholder="Page, paragraph or timestamp"
              required
            />
            <.input
              field={@evidence_form[:attribution_text]}
              label="Citation attribution"
              placeholder="Optional source credit"
            />
            <div class="self-end">
              <.button id="evidence-add" type="submit">Add citation</.button>
            </div>
          </.form>

          <.selected_evidence evidence={@streams.selected_evidence} />

          <.form
            for={@contribution_form}
            id="composer-form"
            phx-change="change"
            phx-submit="submit"
            class="space-y-4"
          >
            <.input
              field={@contribution_form[:rationale]}
              id="composer-rationale"
              type="textarea"
              label="Rationale"
            />
            <.input
              field={@contribution_form[:locator]}
              id="composer-locator"
              label="Selected evidence locator (quick add)"
              placeholder="Page, paragraph, timestamp or URL in the selected evidence"
            />
            <div class="grid gap-4 sm:grid-cols-3">
              <.input
                field={@contribution_form[:language_tag]}
                label="Language context"
                placeholder="en"
              />
              <.input field={@contribution_form[:valid_from]} type="date" label="Applies from" />
              <.input field={@contribution_form[:valid_to]} type="date" label="Applies until" />
            </div>

            <p id="composer-preview" class="text-sm/7 text-mist-500">
              {preview(@subject, @predicate, @object)}
            </p>

            <.button id="composer-submit" type="submit">Submit for review</.button>
          </.form>
        </div>
      </.container>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :query, :string, default: ""
  attr :hits, :any, required: true
  attr :chosen, :map, default: nil
  attr :search, :string, required: true
  attr :pick, :string, required: true

  defp picker(assigns) do
    assigns = assign(assigns, :form, to_form(%{"q" => assigns.query}))

    ~H"""
    <section id={"composer-#{@id}"}>
      <.eyebrow>{@label}</.eyebrow>
      <p :if={@chosen} id={"composer-#{@id}-chosen"} class="mt-2">
        {@chosen.label}
        <span class="text-mist-500">— {@chosen.kind} #{@chosen.object_id}</span>
      </p>
      <.form for={@form} id={"#{@id}-search"} phx-change={@search}>
        <.input
          id={"composer-#{@id}-search"}
          field={@form[:q]}
          autocomplete="off"
          class="mt-2 w-full rounded-lg border border-mist-950/20 bg-transparent p-3 text-sm/6 dark:border-white/20"
          placeholder="Find an existing word or thing"
        />
      </.form>
      <ul id={"#{@id}-results"} phx-update="stream" class="mt-2 space-y-1 text-sm/7">
        <li :for={{dom_id, hit} <- @hits} id={dom_id}>
          <button
            type="button"
            id={"composer-#{@id}-hit-#{hit.object_id}"}
            phx-click={@pick}
            phx-value-id={hit.object_id}
            class="text-left underline decoration-mist-400 underline-offset-4"
          >
            {hit.label}
          </button>
          <span class="text-mist-500">— {hit.detail}</span>
        </li>
      </ul>
    </section>
    """
  end

  defp preview(nil, _predicate, _object), do: "Choose a subject, a relation and an object."
  defp preview(_subject, nil, _object), do: "Choose a relation."
  defp preview(_subject, _predicate, nil), do: "Choose an object."

  defp preview(subject, predicate, object),
    do: "“#{subject.label}” — #{predicate} → “#{object.label}”"

  defp actor_label(nil), do: "unknown — retained rather than invented"
  defp actor_label(actor), do: actor.label || "#{actor.actor_kind} ##{actor.id}"

  defp review_label(:changed_since_review), do: "changed since review"
  defp review_label(state), do: to_string(state)

  defp evidence_path(%{content_revision_id: id}) when not is_nil(id),
    do: "/evidence/content/#{id}"

  defp evidence_path(%{sense_revision_id: id}) when not is_nil(id),
    do: "/evidence/sense/#{id}"

  defp evidence_path(%{source_record_revision_id: id}),
    do: "/evidence/source-record/#{id}"

  # Kept so the module's `Markdown` and `Encyclopedia` aliases are load-bearing
  # rather than decorative: a content endpoint's body is rendered, and an
  # entity's QID comes from the view.
  @doc false
  def body_html(body, format), do: Markdown.to_html(body, format)

  @doc false
  def qid(object_id), do: Encyclopedia.qid(object_id)
end
