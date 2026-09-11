defmodule DevilsDictionaryWeb.EvidenceLive do
  @moduledoc "Stable public destinations for exact revisions cited by a connection."

  use DevilsDictionaryWeb, :live_view

  import Ecto.Query

  alias DevilsDictionary.Claims.{Contributions, Visibility}
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Registry.{ContentItem, ContentRevision, Lexeme, Sense, SenseRevision}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.SourceRecord

  on_mount {DevilsDictionaryWeb.UserAuth, :mount_current_scope}

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, evidence: nil)}

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    visibility =
      if Contributions.reviewer?(socket.assigns.current_scope), do: :internal, else: :public

    evidence = load(socket.assigns.live_action, parse_id(id), visibility)

    {:noreply,
     assign(socket,
       evidence: evidence,
       page_title: if(evidence, do: "cited #{evidence.kind} revision", else: "no such evidence")
     )}
  end

  defp load(_kind, nil, _visibility), do: nil

  defp load(:content, id, visibility) do
    Repo.one(
      from r in ContentRevision,
        join: c in ContentItem,
        on: c.object_id == r.content_id,
        join: current in ContentRevision,
        on: current.content_id == r.content_id and current.is_current,
        left_join: source in assoc(c, :source),
        where: r.id == ^id,
        select: %{
          kind: :content,
          revision_id: r.id,
          revision_number: r.revision_number,
          object_id: r.content_id,
          label: r.headword,
          body: r.body,
          body_format: r.body_format,
          canonical_url: r.canonical_url,
          lifecycle_state: r.lifecycle_state,
          current?: r.is_current,
          rights_metadata: r.rights_metadata,
          current_lifecycle_state: current.lifecycle_state,
          current_rights_metadata: current.rights_metadata,
          source_name: source.name,
          source_slug: source.slug
        }
    )
    |> restrict_content(visibility)
  end

  defp load(:sense, id, visibility) do
    Repo.one(
      from r in SenseRevision,
        join: s in Sense,
        on: s.object_id == r.sense_id,
        join: current in SenseRevision,
        on: current.sense_id == r.sense_id and current.is_current,
        join: l in Lexeme,
        on: l.object_id == s.lexeme_id,
        left_join: source in assoc(s, :source),
        where: r.id == ^id,
        select: %{
          kind: :sense,
          revision_id: r.id,
          revision_number: r.revision_number,
          object_id: r.sense_id,
          label: l.lemma,
          body: r.gloss,
          canonical_url: r.url,
          lifecycle_state: r.lifecycle_state,
          current?: r.is_current,
          current_lifecycle_state: current.lifecycle_state,
          source_name: source.name,
          source_slug: source.slug,
          word_id: l.object_id,
          word_slug: l.slug
        }
    )
    |> restrict_sense(visibility)
  end

  defp load(:source_record, id, _visibility) do
    Repo.one(
      from r in SourceRecordRevision,
        join: record in SourceRecord,
        on: record.id == r.source_record_id,
        join: source in assoc(record, :source),
        where: r.id == ^id,
        select: %{
          kind: :source_record,
          revision_id: r.id,
          revision_number: nil,
          object_id: record.id,
          label: record.external_id,
          body: nil,
          canonical_url: record.url,
          lifecycle_state: :retained,
          current?: record.content_hash == r.revision_key,
          revision_key: r.revision_key,
          checksum: r.checksum,
          observed_at: r.observed_at,
          source_name: source.name,
          source_slug: source.slug,
          display_restricted?: true
        }
    )
  end

  defp restrict_content(nil, _visibility), do: nil

  defp restrict_content(evidence, visibility) do
    current = %{
      lifecycle_state: evidence.current_lifecycle_state,
      rights_metadata: evidence.current_rights_metadata
    }

    Visibility.restrict_historical_content(evidence, current, visibility)
  end

  defp restrict_sense(nil, _visibility), do: nil

  defp restrict_sense(evidence, visibility) do
    current = %{lifecycle_state: evidence.current_lifecycle_state}
    Visibility.restrict_historical_sense(evidence, current, visibility)
  end

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.container class="py-10">
        <%= if @evidence do %>
          <header id="evidence-header" class="max-w-3xl">
            <.eyebrow>cited evidence · immutable revision</.eyebrow>
            <.heading>{@evidence.label || "Source record #{@evidence.object_id}"}</.heading>
            <p class="mt-3 text-sm/7 text-mist-500">
              {@evidence.source_name || "Local contribution"} · revision {@evidence.revision_id}
              <span :if={@evidence.revision_number}> · version {@evidence.revision_number}</span>
              <span :if={!@evidence.current?}> · historical, not current</span>
            </p>
          </header>

          <section
            id="evidence-body"
            class="mt-10 max-w-3xl border-y border-mist-950/10 py-8 dark:border-white/10"
          >
            <p :if={@evidence.display_restricted?} class="text-sm/7 text-mist-500">
              The cited revision is retained, but its text is not publicly displayable.
            </p>
            <.text :if={@evidence.body && !@evidence.display_restricted?}>{@evidence.body}</.text>
            <dl :if={@evidence.kind == :source_record} class="grid gap-2 text-sm/7 sm:grid-cols-2">
              <div>
                <dt class="text-mist-500">Revision key</dt><dd class="break-all">
                  {@evidence.revision_key}
                </dd>
              </div>
              <div>
                <dt class="text-mist-500">Observed</dt><dd>{@evidence.observed_at}</dd>
              </div>
              <div :if={@evidence.checksum}>
                <dt class="text-mist-500">Checksum</dt><dd class="break-all">{@evidence.checksum}</dd>
              </div>
            </dl>
          </section>

          <div class="mt-6 flex flex-wrap gap-4 text-sm/7">
            <.a
              :if={@evidence.kind == :sense}
              navigate={"/words/#{@evidence.word_id}/#{@evidence.word_slug}"}
            >
              Open the word
            </.a>
            <.a :if={@evidence.source_slug} navigate={"/sources/#{@evidence.source_slug}"}>
              Open source record policy
            </.a>
            <.a :if={@evidence.canonical_url} href={@evidence.canonical_url}>Open source URL</.a>
          </div>
        <% else %>
          <div id="no-such-evidence" class="py-12">
            <.heading>No such evidence revision</.heading>
          </div>
        <% end %>
      </.container>
    </Layouts.app>
    """
  end
end
