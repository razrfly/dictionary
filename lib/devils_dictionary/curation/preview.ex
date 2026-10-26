defmodule DevilsDictionary.Curation.Preview do
  @moduledoc """
  The opening a selection would publish (#257 §2.2), for the owner's
  curation screen: the form mapped onto `%Curation.Opening{}`, drawn by the
  public component.

  **One mapping.** The items are either the unsaved `CompositionItem`s
  `Curation.Candidates` built for the selection, with the author's notes
  attributed as `Compositions.create_version/3` would attribute them, or,
  when Publish would publish the latest version as it stands (`:held`),
  that version's stored items. They are then read exactly as a published
  version is:

    * `Curation.Eligibility.evaluate/5` decides which may be shown and under
      which lead rule, and `Published.arrangement_of/2` splits them as
      `Published.current/1` does, describing each exemplar;
    * `PublishedReader.arrangement/3` maps them onto the opening;
    * an exemplar's provenance is the claim's, with this selection and a
      publication now (`Examples.Provenance.in_selection/3`).

  The record is what publishing it now would write: the version that would
  be published (the held one, or the next), selected by its author, reviewed
  and published today by the reviewer. Nothing has a receipt yet, so the
  preview names none; otherwise it is the page's opening (#257 test 13).

  **What would stop it.** `problems` lists everything that would make the
  record refuse the selection, or the page withhold part of it, in their
  own words: an ineligible item, a broken lead rule, two items that show one
  thing (`Compositions.one_display_identity/1`), more highlights than the
  configuration allows, no enabled configuration.

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
  alias DevilsDictionary.Registry.{Sense, SenseRevision}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Actor

  @doc """
  The preview of `selection` on a built `page`, for the reviewer `scope`.

  `selection` is `%{lead: candidate | nil, lead_note: text, highlights:
  [{candidate, note_text}]}`, the candidates from `Candidates.for_page/1`.
  `opts`:

    * `:composition`: the page's composition, if it has one;
    * `:next_version`: the number a new version would get;
    * `:held`: `%{version, items, author}` when Publish would publish that
      stored version as it stands, rather than write a new one.

  Returns `%{opening: %Opening{} | nil, problems: [%{role, position,
  reason}], lead_rule: {:ok, rule} | {:error, reason} | nil, items:
  [CompositionItem]}`.
  """
  def build(page, candidates, selection, scope, opts \\ []) do
    me = author(scope)
    held = opts[:held]
    items = if held, do: held.items, else: items(selection, me)

    case Configurations.resolve_default() do
      {:ok, %{configuration: configuration, version: configuration_version}} ->
        ids = candidates.scope.ids

        evaluation =
          Eligibility.evaluate(
            items,
            ids,
            Compositions.signature(ids),
            configuration_version.id,
            claim_contexts: held && (held.version.resolution || %{})["claim_contexts"]
          )

        selector = if held, do: held.author, else: me.label
        number = if held, do: held.version.version, else: opts[:next_version] || 1
        composition_id = opts[:composition] && opts[:composition].id

        opening =
          PublishedReader.arrangement(page, Published.arrangement_of(items, evaluation), %{
            composition: %{id: composition_id, version: number},
            configuration: configuration,
            configuration_version: configuration_version,
            review: review(me, selector, held && DateTime.to_date(held.version.inserted_at)),
            provenance: &provenance(&1, %{id: composition_id, version: number}, selector, me)
          })

        %{
          opening: if(Opening.empty?(opening), do: nil, else: opening),
          problems: problems(opening, items, configuration_version),
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

  @doc """
  The unsaved items of `selection`, in place, each note attributed to
  `author` (`author/1`) as `Compositions.create_version/3` attributes one.
  """
  def items(selection, author) do
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

  defp place(item, role, position, note, author) do
    note =
      case note do
        text when is_binary(text) -> if String.trim(text) == "", do: nil, else: text
        _none -> nil
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

  defp problems(opening, items, configuration_version) do
    display =
      case Compositions.one_display_identity(items) do
        :ok -> []
        {:error, reason} -> [%{role: :highlight, position: nil, reason: reason}]
      end

    max = configuration_version.max_highlights

    over =
      if Enum.count(items, &(&1.role == :highlight)) > max,
        do: [%{role: :highlight, position: nil, reason: {:too_many_highlights, max}}],
        else: []

    opening.withheld ++ display ++ over
  end

  # ── the record it would write ────────────────────────────────────────────

  @doc """
  Who is acting, read and never written: `%{actor_id, label}`, the account's
  actor and the label its notes go out under (`Compositions.author_label/1`).
  An account that has never acted has no actor yet, and its label is the one
  its first act gives it.
  """
  def author(%{user: %{id: user_id}}) do
    case Repo.one(from a in Actor, where: a.user_id == ^user_id) do
      %Actor{} = actor -> %{actor_id: actor.id, label: Compositions.author_label(actor)}
      nil -> %{actor_id: nil, label: "Account ##{user_id}"}
    end
  end

  defp review(me, selector, selected_on) do
    today = Date.utc_today()

    %Review{
      state: :published,
      selected_by: %{kind: :human, label: selector},
      selected_on: selected_on || today,
      reviewed_by: me.label,
      reviewed_on: today,
      published_by: %{kind: :human, label: me.label},
      published_on: today,
      receipt_id: nil,
      # An unsaved selection has no refresh clock (#259 §2.1).
      assessment: :preview
    }
  end

  # An exemplar's provenance as the page will read it once this is
  # published: the claim's, as the public reads it, with this selection.
  defp provenance(item, composition, selector, me) do
    with %{lexeme_id: lexeme_id} <- meaning_lexeme(item),
         %{} = example <-
           Enum.find(
             Examples.exemplars([lexeme_id], :public),
             &(&1.claim.revision_id == item.assertion_revision_id)
           ),
         %Provenance{} = provenance <- Provenance.of(example, :public) do
      Provenance.in_selection(
        provenance,
        %{
          composition_id: composition.id,
          version: composition.version,
          role: item.role,
          position: item.position,
          selected_by: %{kind: :human, label: selector},
          note: item.note && %{text: item.note, author: item.note_author_label}
        },
        %{actor: %{label: me.label}, committed_at: DateTime.utc_now()}
      )
    else
      _ -> nil
    end
  end

  defp meaning_lexeme(%{meaning_sense_revision_id: id}) when is_integer(id) do
    Repo.one(
      from r in SenseRevision,
        join: s in Sense,
        on: s.object_id == r.sense_id,
        where: r.id == ^id,
        select: %{lexeme_id: s.lexeme_id}
    )
  end

  defp meaning_lexeme(%{meaning_lexeme_id: id}) when is_integer(id), do: %{lexeme_id: id}
  defp meaning_lexeme(_item), do: nil
end
