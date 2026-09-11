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
       reviewer: Contributions.reviewer?(socket.assigns[:current_scope]),
       review_items: [],
       review_form: to_form(%{"reason" => ""})
     )
     |> assign(subject: nil, object: nil, predicate: nil, rationale: "", locator: "")
     |> assign(subject_query: "", object_query: "")
     |> assign(
       predicates: [],
       error: nil,
       context: nil,
       context_query: "",
       evidence: nil,
       evidence_query: "",
       contribution_form: to_form(%{"rationale" => "", "locator" => ""})
     )
     |> stream(:subject_hits, [], dom_id: &"subject-result-#{&1.object_id}")
     |> stream(:object_hits, [], dom_id: &"object-result-#{&1.object_id}")
     |> stream(:context_hits, [], dom_id: &"context-result-#{&1.object_id}")
     |> stream(:evidence_hits, [], dom_id: &"evidence-result-#{&1.object_id}")}
  end

  # ── the detail page ───────────────────────────────────────────────────────

  @impl true
  def handle_params(params, _uri, %{assigns: %{live_action: :show}} = socket) do
    socket = assign(socket, :reviewer, Contributions.reviewer?(socket.assigns[:current_scope]))

    with {id, ""} <- Integer.parse(params["id"] || ""),
         {:ok, revision} <- revision_number(params["revision"]) do
      connection =
        Connection.build(id,
          revision: revision,
          visibility: if(socket.assigns.reviewer, do: :internal, else: :public)
        )

      {:noreply,
       assign(socket,
         id: id,
         connection: connection,
         review_items:
           if(connection, do: Contributions.context_items(connection.revision), else: []),
         page_title: "connection ##{id}"
       )}
    else
      _ -> {:noreply, assign(socket, connection: nil, page_title: "no such connection")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, page_title: "propose a connection")}
  end

  defp revision_number(nil), do: {:ok, nil}

  defp revision_number(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  # ── the composer ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("search-subject", %{"q" => q}, socket) do
    {:noreply,
     socket |> assign(:subject_query, q) |> stream(:subject_hits, search(q), reset: true)}
  end

  def handle_event("search-object", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:object_query, q) |> stream(:object_hits, search(q), reset: true)}
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

  def handle_event("search-evidence", %{"q" => q}, socket) do
    hits = Enum.filter(search(q), &(&1.kind in [:content, :sense]))
    {:noreply, socket |> assign(:evidence_query, q) |> stream(:evidence_hits, hits, reset: true)}
  end

  def handle_event("pick-evidence", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:evidence, Connection.endpoint(String.to_integer(id)))
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
    {:noreply, assign(socket, :predicate, key)}
  end

  def handle_event("change", %{"rationale" => rationale} = params, socket) do
    {:noreply,
     assign(socket,
       rationale: rationale,
       locator: params["locator"] || "",
       contribution_form: to_form(params)
     )}
  end

  def handle_event("submit", params, socket) do
    socket =
      assign(socket,
        rationale: params["rationale"] || socket.assigns.rationale,
        locator: params["locator"] || socket.assigns.locator
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

  defp propose(socket, subject, predicate, object, rationale) do
    evidence_id = socket.assigns.evidence && socket.assigns.evidence.object_id

    case Contributions.propose(
           socket.assigns.current_scope,
           subject.object_id,
           predicate,
           object.object_id,
           %{
             rationale: rationale,
             context_object_id: socket.assigns.context && socket.assigns.context.object_id
           },
           evidence_id,
           socket.assigns.locator
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
          detail: "thing · #{e.entity_kind}"
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
            detail: fragment("left(?, 120)", r.body)
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
                  · reviewer actor {review.reviewer_actor_id || "unknown"} · against revision {@connection.revision.revision_number}
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
        <.heading>Connect two things</.heading>
        <.text class="mt-2">
          Names help you find them; the thing you pick is what the claim points at. It goes
          to review and remains visibly attributed while it awaits a decision.
        </.text>

        <p :if={@error} id="composer-error" class="mt-4 text-sm/7 text-red-600">{@error}</p>

        <div class="mt-8 space-y-8">
          <.picker
            id="subject"
            label="Subject"
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
            label="Object"
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
            id="evidence"
            label="Evidence: a source meaning or passage"
            query={@evidence_query}
            hits={@streams.evidence_hits}
            chosen={@evidence}
            search="search-evidence"
            pick="pick-evidence"
          />
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
              label="Evidence locator"
              placeholder="Page, paragraph, timestamp or URL in the selected evidence"
            />

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

  # Kept so the module's `Markdown` and `Encyclopedia` aliases are load-bearing
  # rather than decorative: a content endpoint's body is rendered, and an
  # entity's QID comes from the view.
  @doc false
  def body_html(body, format), do: Markdown.to_html(body, format)

  @doc false
  def qid(object_id), do: Encyclopedia.qid(object_id)
end
