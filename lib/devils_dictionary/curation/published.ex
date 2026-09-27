defmodule DevilsDictionary.Curation.Published do
  @moduledoc """
  The narrow read of a composition's published arrangement (R6).

  It answers only what was published, revalidated now. **It withholds and
  never substitutes.** A problem with the version as a whole withholds all
  of it (`{:withheld, reasons}`):

    * the composition is retired;
    * its configuration moved on or was disabled;
    * its scope changed;
    * its latest review is no longer an acceptance.

  A problem with one item withholds that item alone and says why. A
  withheld lead is not replaced by another definition, and a withheld
  highlight is not replaced by the next candidate. A Bierce entry that
  appears after a fallback lead was published withholds that lead
  (`:priority_source_available`); it does not promote itself.

  An exemplar it shows (#212) carries its `subject`, read from the registry
  now: the entity's label and kind, or a passage's label and its pinned
  words. Nothing is copied into the composition, and nothing here calls a
  provider or a model (C7).

  Nothing in the web layer calls this yet. Production selection stays
  disabled: no page reads compositions, and binding one to a page is #194's
  (#205). Mapping the answer onto the #156 opening view model waits for PR
  #202, which is not merged.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims.Visibility

  alias DevilsDictionary.Curation.{
    Composition,
    CompositionItem,
    CompositionVersion,
    Compositions,
    Publications,
    Standing
  }

  alias DevilsDictionary.Registry.{ContentItem, ContentRevision, Entity}
  alias DevilsDictionary.Repo

  @doc """
  The published arrangement of a composition, as one of:

    * `{:ok, %{composition, version, receipt, lead, highlights, withheld}}`,
      where `lead` is an item or `nil`, `highlights` are the eligible
      highlights in order, and `withheld` lists `%{role, position, reason}`.
      An exemplar highlight's `subject` is `%{object_id, kind: :entity |
      :content, subkind, label, words}`, `words` being `nil` for an entity;
    * `{:withheld, reasons}`;
    * `:unpublished`;
    * `{:error, :not_found}`.
  """
  def current(composition_id) do
    case Repo.get(Composition, composition_id) do
      nil ->
        {:error, :not_found}

      %Composition{current_published_version_id: nil} ->
        :unpublished

      %Composition{} = composition ->
        version = Repo.get!(CompositionVersion, composition.current_published_version_id)

        case version_reasons(version, composition) do
          [] -> {:ok, arrangement(version, composition)}
          reasons -> {:withheld, reasons}
        end
    end
  end

  defp version_reasons(version, composition) do
    [
      composition.state != :active && :composition_retired,
      reason(Standing.configuration(version)),
      reason(Standing.scope(version, composition)),
      not match?(%{decision: :accepted}, Standing.latest_review(version.id)) &&
        :approval_withdrawn
    ]
    |> Enum.filter(& &1)
  end

  defp reason(:ok), do: false
  defp reason({:error, reason}), do: reason

  defp arrangement(version, composition) do
    items = Compositions.items(version.id)
    evaluation = Standing.evaluate(version, composition)
    statuses = Map.new(evaluation.results, fn {role, pos, status} -> {{role, pos}, status} end)

    status_of = fn item ->
      case {item.role, evaluation.lead_rule} do
        {:lead, {:error, reason}} -> reason
        _ -> Map.fetch!(statuses, {item.role, item.position})
      end
    end

    {shown, held} = Enum.split_with(items, &(status_of.(&1) == :ok))

    withheld =
      Enum.map(held, &%{role: &1.role, position: &1.position, reason: status_of.(&1)}) ++
        missing_lead(items, evaluation.lead_rule)

    %{
      composition: composition,
      version: version,
      receipt: Publications.latest(composition.id),
      lead: Enum.find(shown, &(&1.role == :lead)),
      highlights: shown |> Enum.filter(&(&1.role == :highlight)) |> Enum.map(&with_subject/1),
      withheld: withheld
    }
  end

  # Only an exemplar that is shown is described: a withheld one's words are
  # not read.
  defp with_subject(%CompositionItem{item_kind: :exemplar} = item),
    do: %{item | subject: subject(item)}

  defp with_subject(item), do: item

  defp subject(%CompositionItem{item_object_id: id, content_revision_id: nil}) do
    {kind, label} =
      Repo.one!(
        from e in Entity,
          where: e.object_id == ^id,
          select:
            {e.entity_kind,
             coalesce(
               e.preferred_label,
               fragment(
                 "(SELECT external_id FROM external_identifiers WHERE object_id = ? AND namespace = 'wikidata' AND status = 'verified' ORDER BY external_id LIMIT 1)",
                 e.object_id
               )
             )}
      )

    %{object_id: id, kind: :entity, subkind: kind, label: label || "##{id}", words: nil}
  end

  defp subject(%CompositionItem{item_object_id: id, content_revision_id: revision_id}) do
    {kind, revision} =
      Repo.one!(
        from r in ContentRevision,
          join: c in ContentItem,
          on: c.object_id == r.content_id,
          where: r.id == ^revision_id and r.content_id == ^id,
          select: {c.content_kind, r}
      )

    %{
      object_id: id,
      kind: :content,
      subkind: kind,
      label:
        Visibility.content_label(revision.headword, revision.body, id, revision.rights_metadata),
      words: revision.body
    }
  end

  # A version published with no lead, on a scope where a Bierce entry has
  # since appeared, reports the gap rather than filling it.
  defp missing_lead(items, {:error, reason}) do
    if Enum.any?(items, &(&1.role == :lead)),
      do: [],
      else: [%{role: :lead, position: 1, reason: reason}]
  end

  defp missing_lead(_items, _rule), do: []
end
