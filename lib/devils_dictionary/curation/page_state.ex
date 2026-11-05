defmodule DevilsDictionary.Curation.PageState do
  @moduledoc """
  What a curated page says when it has no selection to show (#309 §4 H, D1
  rows 20–23), and the versions its footer lists.

    * `%{kind: :withheld, reasons, published_on, assessment}` — a version is
      published but withheld as a whole (`Published.current/1`), with the
      composition's latest assessment under the current configuration, or
      `nil`;
    * `%{kind: :abstained, editor, assessed_at, reason}` — nothing is
      published and the editor last assessed the words and chose not to
      select; `reason` is its stored abstain reason, or `nil` when none was
      stored or it was withheld;
    * `%{kind: :unpublished}` — nothing is published and the latest
      assessment did something else (it needs an editor, or a proposal
      waits for the owner);
    * `%{kind: :none}` — no editor has assessed the words under the current
      configuration, or the page has no composition.

  It reads the same rows the page's reader and refresh clock read: the global
  default configuration, the page's composition, its publication, its
  refresh row and, for an abstention, the latest abstained attempt under the
  composition and configuration version that finished by the row's last
  completion. Database reads only; no model,
  no write, and never an attempt's packet summary (#299 M5).
  """

  import Ecto.Query

  alias DevilsDictionary.Curation.{
    CompositionItem,
    CompositionPublication,
    CompositionVersion,
    Compositions,
    Configurations,
    Published,
    PublishedReader,
    Publications,
    Refresh
  }

  alias DevilsDictionary.Repo

  def for_page(page) do
    with {:ok, %{configuration: configuration, version: configuration_version}} <-
           Configurations.resolve_default(),
         {:ok, ids, language} <- PublishedReader.scope(page),
         %{} = composition <-
           Compositions.active(
             configuration.id,
             :lexical_page,
             language,
             Compositions.signature(ids)
           ) do
      assessment = assessment(composition.id, configuration_version.id)

      case Published.current(composition.id) do
        {:withheld, reasons} ->
          %{
            kind: :withheld,
            reasons: reasons,
            published_on: published_on(composition.id),
            version: version_number(composition.current_published_version_id),
            assessment: assessment
          }

        _ ->
          assessment || unassessed(composition.id, configuration_version.id)
      end
    else
      _ -> %{kind: :none}
    end
  end

  @doc """
  What the editor chose in a version: how many items it holds and whether
  one of them is the lead, for "The editor chose {k}" (D1 row 17c), which
  counts the version's items, shown or withheld at read time.
  """
  def chosen(composition_id, version) do
    Repo.one(
      from i in CompositionItem,
        join: v in CompositionVersion,
        on: v.id == i.composition_version_id,
        where: v.composition_id == ^composition_id and v.version == ^version,
        select: %{items: count(i.id), lead?: fragment("bool_or(? = 'lead')", i.role)}
    )
  end

  @doc "The composition's earlier published versions, newest first."
  def earlier_versions(composition_id, version) do
    Repo.all(
      from p in CompositionPublication,
        join: v in CompositionVersion,
        on: v.id == p.published_version_id,
        where:
          p.composition_id == ^composition_id and p.action == :publish and v.version < ^version,
        distinct: true,
        select: v.version
    )
    |> Enum.sort(:desc)
  end

  defp version_number(nil), do: nil

  defp version_number(version_id) do
    Repo.one(from v in CompositionVersion, where: v.id == ^version_id, select: v.version)
  end

  defp published_on(composition_id) do
    case Publications.latest(composition_id) do
      %{committed_at: %NaiveDateTime{} = at} -> NaiveDateTime.to_date(at)
      %{committed_at: %DateTime{} = at} -> DateTime.to_date(at)
      _ -> nil
    end
  end

  # The refresh row's outcome is the assessment. Its generation moves on as
  # soon as the next check is admitted, while the outcome and its time stay
  # the last completed run's, so the attempt is the latest abstention under
  # this composition and configuration version that finished by then — not
  # the one the current generation names (#309 review R1).
  defp assessment(composition_id, configuration_version_id) do
    case Refresh.state_for(composition_id, configuration_version_id) do
      %{last_outcome: :abstained, last_completed_at: %{} = at} ->
        attempt = abstention("proposal:#{composition_id}:#{configuration_version_id}:", at)

        %{
          kind: :abstained,
          assessed_at: at,
          attempt?: not is_nil(attempt),
          editor: attempt && attempt.editor,
          reason: attempt && present(attempt.reason),
          # The runtime blanks a reason that quoted provider text; the page
          # then says nothing about a reason rather than "gave no reason".
          reason_withheld?: (attempt && attempt.reason_withheld?) || false
        }

      _ ->
        nil
    end
  end

  defp unassessed(composition_id, configuration_version_id) do
    case Refresh.state_for(composition_id, configuration_version_id) do
      %{last_completed_at: %{}} -> %{kind: :unpublished}
      _ -> %{kind: :none}
    end
  end

  defp abstention(prefix, at) do
    finished_by = at |> DateTime.to_naive() |> NaiveDateTime.add(1, :second)

    Repo.one(
      from a in "inference_attempts",
        left_join: actor in "actors",
        on: actor.id == a.requested_by_actor_id,
        where:
          like(a.request_key, ^(prefix <> "%")) and a.outcome == "abstained" and
            a.finished_at <= type(^finished_by, :naive_datetime),
        order_by: [desc: a.finished_at, desc: a.id],
        limit: 1,
        select: %{
          editor: actor.label,
          reason: fragment("?->>'abstain_reason'", a.result),
          reason_withheld?: fragment("(?->>'abstain_reason_withheld') is not null", a.result)
        }
    )
  end

  defp present(text) when is_binary(text), do: if(String.trim(text) == "", do: nil, else: text)
  defp present(_text), do: nil
end
