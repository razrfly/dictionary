defmodule DevilsDictionary.Curation.Preview do
  @moduledoc """
  The opening an unsaved selection would publish (#257 §2.2), for the
  owner's curation screen: the form mapped onto `%Curation.Opening{}`, drawn
  by the public component.

  **One mapping.** The selection's items are the unsaved
  `CompositionItem`s `Curation.Candidates` built for it, with the author's
  notes attributed as `Compositions.create_version/3` would attribute them.
  They are then read exactly as a published version is:

    * `Curation.Eligibility.evaluate/5` decides which may be shown and under
      which lead rule, as `Published.current/1` does at read time; an item
      that may not is withheld, never replaced;
    * `Published.with_subject/1` describes an exemplar;
    * `PublishedReader.arrangement/3` maps the rest onto the opening.

  The record is what publishing it now would write: the reviewer selects,
  reviews and publishes today, as the next version. Nothing here has an id
  yet, so the preview names no receipt; otherwise it is the page's opening,
  which is what makes it a preview (#257 test 13).

  **What would stop it.** `problems` lists everything that would make the
  record refuse the selection, or the page withhold part of it, in the
  record's own words: an ineligible item, a broken lead rule, two items that
  show one thing (`Compositions.one_display_identity/1`), more highlights
  than the configuration allows, no enabled configuration.

  Reads only: no write, no provider, no model.
  """

  import Ecto.Query

  alias DevilsDictionary.Curation.{
    Compositions,
    Configurations,
    Eligibility,
    Opening,
    Published,
    PublishedReader
  }

  alias DevilsDictionary.Curation.Opening.Review
  alias DevilsDictionary.Examples
  alias DevilsDictionary.Examples.Provenance
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Actor

  @doc """
  The preview of `selection` on a built `page`, for the reviewer `scope`.

  `selection` is `%{lead: candidate | nil, lead_note: text, highlights:
  [{candidate, note_text}]}`, the candidates from `Candidates.for_page/1`.
  `opts`: `:composition` (the page's composition, if any) and
  `:next_version` (the version number this would be).

  Returns `%{opening: %Opening{} | nil, problems: [%{role, position,
  reason}], lead_rule: {:ok, rule} | {:error, reason} | nil, items:
  [CompositionItem]}`.
  """
  def build(page, candidates, selection, scope, opts \\ []) do
    author = author(scope)
    items = items(selection, author)

    case Configurations.resolve_default() do
      {:ok, %{configuration: configuration, version: configuration_version}} ->
        ids = candidates.scope.ids
        signature = Compositions.signature(ids)
        evaluation = Eligibility.evaluate(items, ids, signature, configuration_version.id)
        arrangement = arrangement(items, evaluation)

        opening =
          PublishedReader.arrangement(page, arrangement, %{
            composition: %{
              id: opts[:composition] && opts[:composition].id,
              version: opts[:next_version] || 1
            },
            configuration: configuration,
            configuration_version: configuration_version,
            review: review(author),
            provenance: &provenance(&1, author, opts)
          })

        %{
          opening: if(Opening.empty?(opening), do: nil, else: opening),
          problems:
            problems(
              opening,
              items,
              configuration_version,
              Enum.count(items, &(&1.role == :highlight))
            ),
          lead_rule: evaluation.lead_rule,
          items: items
        }

      {:unavailable, reason} ->
        %{
          opening: nil,
          problems: [%{role: nil, position: nil, reason: {:configuration, reason}}],
          lead_rule: nil,
          items: items
        }
    end
  end

  # ── the items ────────────────────────────────────────────────────────────

  defp items(selection, author) do
    lead =
      case selection.lead do
        %{item: %{} = item} -> [place(item, :lead, 1, selection[:lead_note], author)]
        _none -> []
      end

    highlights =
      selection.highlights
      |> Enum.with_index(1)
      |> Enum.map(fn {{candidate, note}, n} ->
        place(candidate.item, :highlight, n, note, author)
      end)

    lead ++ highlights
  end

  # The item where the selection puts it, with the note its author wrote,
  # attributed to that author and nobody else (K9).
  defp place(item, role, position, note, author) do
    note =
      case note do
        text when is_binary(text) ->
          if String.trim(text) == "", do: nil, else: text

        _none ->
          nil
      end

    %{
      item
      | role: role,
        position: position,
        note: note,
        note_author_kind: note && :human,
        note_author_label: note && author.label,
        note_author_actor_id: note && author.actor_id
    }
  end

  # What `Published.current/1` would answer for these items: the eligible
  # ones, an exemplar with its subject, and the rest withheld with the
  # record's reason. A broken lead rule withholds the lead.
  defp arrangement(items, evaluation) do
    statuses = Map.new(evaluation.results, fn {role, pos, status} -> {{role, pos}, status} end)

    status_of = fn item ->
      case {item.role, evaluation.lead_rule} do
        {:lead, {:error, reason}} -> reason
        _ -> Map.fetch!(statuses, {item.role, item.position})
      end
    end

    {shown, held} = Enum.split_with(items, &(status_of.(&1) == :ok))

    missing_lead =
      case evaluation.lead_rule do
        {:error, reason} ->
          if Enum.any?(items, &(&1.role == :lead)),
            do: [],
            else: [%{role: :lead, position: 1, reason: reason}]

        _ok ->
          []
      end

    %{
      lead: Enum.find(shown, &(&1.role == :lead)),
      highlights:
        shown |> Enum.filter(&(&1.role == :highlight)) |> Enum.map(&Published.with_subject/1),
      withheld:
        Enum.map(held, &%{role: &1.role, position: &1.position, reason: status_of.(&1)}) ++
          missing_lead
    }
  end

  defp problems(opening, items, configuration_version, highlights) do
    display =
      case Compositions.one_display_identity(items) do
        :ok -> []
        {:error, reason} -> [%{role: :highlight, position: nil, reason: reason}]
      end

    over =
      if highlights > configuration_version.max_highlights,
        do: [
          %{
            role: :highlight,
            position: nil,
            reason: {:too_many_highlights, configuration_version.max_highlights}
          }
        ],
        else: []

    opening.withheld ++ display ++ over
  end

  # ── the record it would write ────────────────────────────────────────────

  # Who is acting, read and never written: the account's actor and the label
  # its notes go out under (`Compositions.author_label/1`). An account that
  # has never acted has no actor yet, and its label is the one the first act
  # gives it.
  defp author(%{user: %{id: user_id}}) do
    case Repo.one(from a in Actor, where: a.user_id == ^user_id) do
      %Actor{} = actor -> %{actor_id: actor.id, label: Compositions.author_label(actor)}
      nil -> %{actor_id: nil, label: "Account ##{user_id}"}
    end
  end

  defp review(author) do
    today = Date.utc_today()
    person = %{kind: :human, label: author.label}

    %Review{
      state: :published,
      selected_by: person,
      selected_on: today,
      reviewed_by: author.label,
      reviewed_on: today,
      published_by: person,
      published_on: today,
      receipt_id: nil
    }
  end

  # An exemplar's provenance as the page will read it once this is
  # published: the claim's, as the public reads it, with this selection and
  # a publication today in place of the card's ranking.
  defp provenance(item, author, opts) do
    with %{lexeme_id: lexeme_id} <- meaning_lexeme(item),
         %{} = example <-
           Enum.find(
             Examples.exemplars([lexeme_id], :public),
             &(&1.claim.revision_id == item.assertion_revision_id)
           ),
         %Provenance{} = provenance <- Provenance.of(example, :public) do
      %{
        provenance
        | selection: %{
            kind: :composed,
            composition_id: opts[:composition] && opts[:composition].id,
            version: opts[:next_version] || 1,
            role: item.role,
            position: item.position,
            selection_origin: :manual,
            selected_by: %{kind: :user, label: author.label},
            note: item.note && %{text: item.note, author: item.note_author_label}
          },
          publication: %{
            receipt_id: nil,
            authority_kind: :operator,
            actor: %{label: author.label},
            committed_at: DateTime.utc_now(),
            superseded_at: nil,
            withdrawn_at: nil
          },
          featured: []
      }
    else
      _ -> nil
    end
  end

  defp meaning_lexeme(%{meaning_sense_revision_id: id}) when is_integer(id) do
    Repo.one(
      from r in DevilsDictionary.Registry.SenseRevision,
        join: s in DevilsDictionary.Registry.Sense,
        on: s.object_id == r.sense_id,
        where: r.id == ^id,
        select: %{lexeme_id: s.lexeme_id}
    )
  end

  defp meaning_lexeme(%{meaning_lexeme_id: id}) when is_integer(id), do: %{lexeme_id: id}
  defp meaning_lexeme(_item), do: nil
end
