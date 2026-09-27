defmodule DevilsDictionary.Curation.LeadRule do
  @moduledoc """
  Bierce first (K10), read from the registry.

  The editorial rule of #156 and #193: **where a word has a *Devil's
  Dictionary* entry, that entry leads.** A composition cannot outvote it.

  An entry is *applicable* to a scope when it is on the scope's page:

    * a content item from the active `bierce` source;
    * whose current revision is active;
    * that a current, active `defines` claim links to a member lexeme or to a
      sense of one.

  This is the same join the word page makes (`Lexicon.WordPage`).

    * Where an applicable entry exists, only an applicable entry may lead
      (`:priority_source`). A version naming another lead is refused
      (`:priority_source_available`), and one naming none is refused
      (`:priority_source_missing`).
    * Where none exists, a person may choose any definition on the page
      (`:manual_fallback`), or no lead (`:none`). There is no automatic
      fallback order; that is still an open product decision.

  The check runs when a version is made, when it is reviewed and published,
  and again when it is read. A Bierce entry that appears later withholds a
  published fallback lead rather than being substituted for it.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Registry.{ContentItem, ContentRevision, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Source

  @priority_source "bierce"

  @doc "The slug of the source whose applicable entry leads."
  def priority_source, do: @priority_source

  @doc "The applicable Bierce entries for these member lexemes, as sorted content object ids."
  def applicable(member_ids) do
    member_ids
    |> defining()
    |> join(:inner, [ci], s in Source,
      on: s.id == ci.source_id and s.slug == @priority_source and s.active
    )
    |> select([ci], ci.object_id)
    |> distinct(true)
    |> Repo.all()
    |> Enum.sort()
  end

  @doc "Whether content object `content_id` is a definition on this scope's page."
  def defines?(content_id, member_ids) do
    member_ids
    |> defining()
    |> where([ci], ci.object_id == ^content_id)
    |> Repo.exists?()
  end

  @doc """
  The rule a lead (a content object id, or `nil`) is admitted under:
  `{:ok, :priority_source | :manual_fallback | :none}`, or `{:error, reason}`.
  """
  def check(member_ids, lead_id, applicable \\ nil) do
    applicable = applicable || applicable(member_ids)

    cond do
      is_nil(lead_id) and applicable == [] -> {:ok, :none}
      is_nil(lead_id) -> {:error, :priority_source_missing}
      lead_id in applicable -> {:ok, :priority_source}
      applicable != [] -> {:error, :priority_source_available}
      defines?(lead_id, member_ids) -> {:ok, :manual_fallback}
      true -> {:error, :lead_not_on_scope}
    end
  end

  defp defining(member_ids) do
    from ci in ContentItem,
      join: cr in ContentRevision,
      on: cr.content_id == ci.object_id and cr.is_current and cr.lifecycle_state == :active,
      join: link in AssertionRevision,
      on:
        link.subject_object_id == ci.object_id and link.is_current and
          link.lifecycle_state == :active,
      join: pr in assoc(link, :predicate),
      on: pr.key == "defines",
      left_join: sense in Sense,
      on: sense.object_id == link.object_object_id,
      where: link.object_object_id in ^member_ids or sense.lexeme_id in ^member_ids
  end
end
