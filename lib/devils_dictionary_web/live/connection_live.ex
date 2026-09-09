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
  alias DevilsDictionary.Claims.Connection
  alias DevilsDictionary.{Encyclopedia, Lexicon, Markdown, Registry, Repo}

  @results 8

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(connection: nil, id: nil)
     |> assign(subject: nil, object: nil, predicate: nil, rationale: "", locator: "")
     |> assign(subject_query: "", object_query: "", subject_hits: [], object_hits: [])
     |> assign(predicates: [], error: nil)}
  end

  # ── the detail page ───────────────────────────────────────────────────────

  @impl true
  def handle_params(params, _uri, %{assigns: %{live_action: :show}} = socket) do
    revision = params["revision"] && String.to_integer(params["revision"])

    case Integer.parse(params["id"] || "") do
      {id, ""} ->
        {:noreply,
         socket
         |> assign(:id, id)
         |> assign(:connection, Connection.build(id, revision: revision))
         |> assign(:page_title, "connection ##{id}")}

      _ ->
        {:noreply, assign(socket, connection: nil, page_title: "no such connection")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, page_title: "propose a connection")}
  end

  # ── the composer ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("search-subject", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:subject_query, q) |> assign(:subject_hits, search(q))}
  end

  def handle_event("search-object", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:object_query, q) |> assign(:object_hits, search(q))}
  end

  def handle_event("pick-subject", %{"id" => id}, socket) do
    subject = Connection.endpoint(String.to_integer(id))

    {:noreply,
     socket
     |> assign(:subject, subject)
     |> assign(:subject_hits, [])
     |> assign(:predicate, nil)
     |> assign(:predicates, predicates_for(subject))}
  end

  def handle_event("pick-object", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:object, Connection.endpoint(String.to_integer(id)))
     |> assign(:object_hits, [])}
  end

  def handle_event("pick-predicate", %{"key" => key}, socket) do
    {:noreply, assign(socket, :predicate, key)}
  end

  def handle_event("change", %{"rationale" => rationale} = params, socket) do
    {:noreply, assign(socket, rationale: rationale, locator: params["locator"] || "")}
  end

  def handle_event("submit", _params, socket) do
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

  defp propose(socket, subject, predicate, object, rationale) do
    actor = actor_for(socket.assigns.current_scope)

    attrs = %{
      submitted_by_actor_id: actor.id,
      origin_actor_id: actor.id,
      rationale: rationale,
      method: "curated"
    }

    case Claims.assert(subject.object_id, predicate, object.object_id, attrs) do
      {:ok, assertion} ->
        {:noreply,
         socket
         |> put_flash(:info, "Proposed. It is waiting for review.")
         |> push_navigate(to: ~p"/connections/#{assertion.id}")}

      {:error, _changeset} ->
        # The endpoint rules are a foreign key, so an impossible pair fails
        # here rather than being written and found later.
        {:noreply,
         assign(
           socket,
           :error,
           "Those two things cannot be connected that way. The relation's endpoint rules refused it."
         )}
    end
  end

  # An account is never automatically the person it claims to be (#74 §B), so
  # the actor is the *account*, found or made, and nothing more.
  defp actor_for(%{user: user}) do
    case Repo.get_by(DevilsDictionary.Sources.Actor, user_id: user.id) do
      nil ->
        Repo.insert!(%DevilsDictionary.Sources.Actor{
          actor_kind: :user,
          user_id: user.id,
          label: user.email
        })

      actor ->
        actor
    end
  end

  # Names help discovery. Words come from the trigram index, things from their
  # label — and the id, not the name, is what the form submits.
  defp search(q) when byte_size(q) < 2, do: []

  defp search(q) do
    words =
      q
      |> Lexicon.search(limit: @results)
      |> Enum.map(&%{object_id: &1.lexeme_id, label: &1.lemma, detail: "word · #{&1.pos}"})

    things =
      Repo.all(
        from e in Registry.Entity,
          where: ilike(e.preferred_label, ^"%#{q}%"),
          order_by: e.preferred_label,
          limit: @results
      )
      |> Enum.map(fn e ->
        %{object_id: e.object_id, label: e.preferred_label, detail: "thing · #{e.entity_kind}"}
      end)

    words ++ things
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
    <Layouts.app flash={@flash}>
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
              <dd id="connection-review">{@connection.review}</dd>
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
    <Layouts.app flash={@flash}>
      <.container class="py-10">
        <.eyebrow>propose</.eyebrow>
        <.heading>Connect two things</.heading>
        <.text class="mt-2">
          Names help you find them; the thing you pick is what the claim points at. It goes
          to review — nothing here is published by proposing it.
        </.text>

        <p :if={@error} id="composer-error" class="mt-4 text-sm/7 text-red-600">{@error}</p>

        <div class="mt-8 space-y-8">
          <.picker
            id="subject"
            label="Subject"
            query={@subject_query}
            hits={@subject_hits}
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
            hits={@object_hits}
            chosen={@object}
            search="search-object"
            pick="pick-object"
          />

          <form id="composer-form" phx-change="change" phx-submit="submit" class="space-y-4">
            <div>
              <.eyebrow>Rationale</.eyebrow>
              <textarea
                id="composer-rationale"
                name="rationale"
                rows="3"
                class="mt-2 w-full rounded-lg border border-mist-950/20 bg-transparent p-3 text-sm/6 dark:border-white/20"
                placeholder="Why is this true, and what should a reviewer look at?"
              >{@rationale}</textarea>
            </div>

            <div>
              <.eyebrow>Evidence locator</.eyebrow>
              <input
                id="composer-locator"
                name="locator"
                value={@locator}
                class="mt-2 w-full rounded-lg border border-mist-950/20 bg-transparent p-3 text-sm/6 dark:border-white/20"
                placeholder="A page, a line, a timestamp — where to look"
              />
            </div>

            <p id="composer-preview" class="text-sm/7 text-mist-500">
              {preview(@subject, @predicate, @object)}
            </p>

            <.button id="composer-submit" type="submit">Submit for review</.button>
          </form>
        </div>
      </.container>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :query, :string, default: ""
  attr :hits, :list, default: []
  attr :chosen, :map, default: nil
  attr :search, :string, required: true
  attr :pick, :string, required: true

  defp picker(assigns) do
    ~H"""
    <section id={"composer-#{@id}"}>
      <.eyebrow>{@label}</.eyebrow>
      <p :if={@chosen} id={"composer-#{@id}-chosen"} class="mt-2">
        {@chosen.label}
        <span class="text-mist-500">— {@chosen.kind} #{@chosen.object_id}</span>
      </p>
      <form phx-change={@search}>
        <input
          id={"composer-#{@id}-search"}
          name="q"
          value={@query}
          autocomplete="off"
          class="mt-2 w-full rounded-lg border border-mist-950/20 bg-transparent p-3 text-sm/6 dark:border-white/20"
          placeholder="Find an existing word or thing"
        />
      </form>
      <ul :if={@hits != []} class="mt-2 space-y-1 text-sm/7">
        <li :for={hit <- @hits}>
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

  # Kept so the module's `Markdown` and `Encyclopedia` aliases are load-bearing
  # rather than decorative: a content endpoint's body is rendered, and an
  # entity's QID comes from the view.
  @doc false
  def body_html(body, format), do: Markdown.to_html(body, format)

  @doc false
  def qid(object_id), do: Encyclopedia.qid(object_id)
end
