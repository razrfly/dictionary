defmodule DevilsDictionary.Curation.LeadRule do
  @moduledoc """
  Bierce first (K10), read from the registry.

  The editorial rule of #156 and #193: **where a word has a *Devil's
  Dictionary* entry, that entry leads.** A composition cannot outvote it.

  A definition is *on* a scope's page when a current, active `defines` claim
  links it to a member lexeme or to a sense of one, and that claim passes the
  canonical public visibility policy (`Claims.visible/2`). A rejected or
  withdrawn claim, or one whose endpoint is retired or withdrawn, puts nothing
  on the page. The content's own current revision must be active. This is
  the same relationship the word page reads (`Lexicon.WordPage`), with the
  same review policy the rest of the public site applies.

  An entry is *applicable* when it is on the page, is from the active `bierce`
  source, and may itself lead now (`Eligibility.leadable?/1`). A source's
  priority never overrides its eligibility: a Bierce entry whose rights,
  record or source forbid display neither leads nor blocks another lead.

    * Where an applicable entry exists, only an applicable entry may lead
      (`:priority_source`). A version naming another lead is refused
      (`:priority_source_available`), and one naming none is refused
      (`:priority_source_missing`).
    * Where none exists, any definition on the page may lead
      (`:manual_fallback`), or no lead (`:none`). A definition not on the
      page, including one whose claim was rejected, is `:lead_not_on_scope`.
      There is no automatic fallback order; that is still an open product
      decision.

  The check runs when a version is made, reviewed, published and read. A
  published lead whose claim is later rejected, or a Bierce entry that
  appears after a fallback was published, withholds the lead. Nothing is
  substituted for it.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Curation.Eligibility
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
    |> join(:inner, [content: ci], s in Source,
      on: s.id == ci.source_id and s.slug == @priority_source and s.active
    )
    |> select([content: ci], ci.object_id)
    |> distinct(true)
    |> Repo.all()
    |> Enum.filter(&Eligibility.leadable?/1)
    |> Enum.sort()
  end

  @doc """
  Every definition on this scope's page, as sorted content object ids: the
  candidates a lead may come from, through the same visible `defines` claims.
  """
  def on_page(member_ids) do
    member_ids
    |> defining()
    |> select([content: ci], ci.object_id)
    |> distinct(true)
    |> Repo.all()
    |> Enum.sort()
  end

  @doc "Whether content object `content_id` is a definition on this scope's page."
  def defines?(content_id, member_ids) do
    member_ids
    |> defining()
    |> where([content: ci], ci.object_id == ^content_id)
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

  # The publicly visible `defines` claims from a content item to a member
  # lexeme or a member's sense. The claim revision is the query's root
  # binding, which is what `Claims.visible/2` filters.
  defp defining(member_ids) do
    from(link in AssertionRevision,
      join: pr in assoc(link, :predicate),
      on: pr.key == "defines",
      join: ci in ContentItem,
      as: :content,
      on: ci.object_id == link.subject_object_id,
      join: cr in ContentRevision,
      on: cr.content_id == ci.object_id and cr.is_current and cr.lifecycle_state == :active,
      left_join: sense in Sense,
      on: sense.object_id == link.object_object_id,
      where: link.is_current and link.lifecycle_state == :active,
      where: link.object_object_id in ^member_ids or sense.lexeme_id in ^member_ids
    )
    |> Claims.visible(:public)
  end
end
