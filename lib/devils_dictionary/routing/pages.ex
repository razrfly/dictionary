defmodule DevilsDictionary.Routing.Pages do
  @moduledoc """
  Page identities and their immutable editorial revisions (ADR 0004 §4–5).

  This is storage, not an editor: the On editing UI and human review are
  Stage 4. A revision is written whole — title, body, actors, evidence and its
  complete ordered membership — and becomes the page's current revision in the
  same transaction. Nothing here allocates an address or publishes a page.

  Membership is typed and never asserts identity. Nothing here writes
  `object_names`, assertions or external identifiers, so an editorial
  association such as Putin/poutine stays an association.
  """

  import Ecto.Query

  alias DevilsDictionary.Registry.Object
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.{Page, PageMembership, PageRevision}
  alias DevilsDictionary.Sources.Actor

  @doc "Creates a new, unrouted draft page."
  def create(attrs) do
    attrs |> Page.create_changeset() |> Repo.insert()
  end

  @doc """
  The page for a target object and locale, created if absent.

  Idempotent under concurrency: the unique target-and-locale index decides, so
  two callers get the same page. A resumable backfill relies on this rather
  than on checking first.
  """
  def ensure(role, target_object_id, locale \\ "en") when role in [:subject, :edition, :lexeme] do
    changeset =
      Page.create_changeset(%{role: role, target_object_id: target_object_id, locale: locale})

    index =
      if role == :lexeme,
        do: "(target_object_id, locale) WHERE role = 'lexeme'",
        else: "(target_object_id, locale) WHERE role IN ('subject','edition')"

    with {:ok, _page} <-
           Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: {:unsafe_fragment, index}
           ) do
      page = by_target(role, target_object_id, Ecto.Changeset.get_field(changeset, :locale))
      if page && page.role == role, do: {:ok, page}, else: {:error, :target_has_other_role}
    end
  end

  defp by_target(:lexeme, target, locale),
    do: Repo.get_by(Page, role: :lexeme, target_object_id: target, locale: locale)

  defp by_target(_role, target, locale) do
    Repo.one(
      from p in Page,
        where: p.target_object_id == ^target and p.locale == ^locale,
        where: p.role in [:subject, :edition]
    )
  end

  def get(id), do: Repo.get(Page, id)

  @doc """
  Writes a new revision and makes it current.

  `attrs` takes `:title`, `:body`, `:body_format`, `:reviewer_actor_id` and
  `:evidence`. Each membership is a map with `:relationship`, exactly one of
  `:target_object_id` or `:target_page_id`, and optional `:rationale` and
  `:evidence`; list order is position. Only an active page is edited here.
  Split successors are written by `Routing.Ledger.split/3`, never by a caller.
  """
  def add_revision(page_id, attrs, memberships, author_actor_id) do
    Repo.transaction(fn ->
      page = lock!(page_id)

      with :ok <- editable(page),
           :ok <- validate_memberships(page, memberships),
           {:ok, revision} <- insert_revision(page, attrs, memberships, author_actor_id) do
        page |> Ecto.Changeset.change(current_revision_id: revision.id) |> Repo.update!()
        revision
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp editable(nil), do: {:error, :page_not_found}
  defp editable(%Page{lifecycle_state: :active}), do: :ok
  defp editable(%Page{}), do: {:error, :page_not_editable}

  @doc false
  # The ledger's entry point: writes a sealed revision without moving the
  # page's pointer, so a split can record the pointer in its route change.
  def insert_revision(%Page{} = page, attrs, memberships, author_actor_id) do
    with :ok <- actor(author_actor_id) do
      number =
        Repo.one(
          from r in PageRevision, where: r.page_id == ^page.id, select: max(r.revision_number)
        )

      revision =
        Repo.insert!(%PageRevision{
          page_id: page.id,
          revision_number: (number || 0) + 1,
          title: attrs[:title],
          body: attrs[:body],
          body_format: attrs[:body_format] || :markdown,
          author_actor_id: author_actor_id,
          reviewer_actor_id: attrs[:reviewer_actor_id],
          evidence: attrs[:evidence] || %{},
          membership_count: length(memberships)
        })

      memberships
      |> Enum.with_index(1)
      |> Enum.each(fn {member, position} ->
        Repo.insert!(%PageMembership{
          page_id: page.id,
          page_revision_id: revision.id,
          position: position,
          relationship: member.relationship,
          target_object_id: member[:target_object_id],
          target_page_id: member[:target_page_id],
          rationale: member[:rationale],
          evidence: member[:evidence] || %{}
        })
      end)

      {:ok, revision}
    end
  end

  defp actor(id) do
    if is_integer(id) and Repo.exists?(from a in Actor, where: a.id == ^id),
      do: :ok,
      else: {:error, :actor_required}
  end

  defp validate_memberships(page, memberships) do
    Enum.reduce_while(memberships, :ok, fn member, :ok ->
      case membership(page, member) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp membership(_page, %{relationship: :split_successor}),
    do: {:error, :split_successors_are_written_by_the_ledger}

  defp membership(%Page{role: role}, %{relationship: :choice_option}) when role != :choice,
    do: {:error, :choice_options_belong_to_choice_pages}

  defp membership(_page, %{relationship: :supplies_lexical_material} = member) do
    case target_kind(member) do
      kind when kind in [:lexeme, :sense] -> :ok
      _other -> {:error, :lexical_material_must_be_a_lexeme_or_sense}
    end
  end

  defp membership(_page, %{relationship: relationship} = member) do
    cond do
      relationship not in PageMembership.relationships() -> {:error, :unknown_relationship}
      is_nil(target_kind(member)) -> {:error, :membership_target_not_found}
      true -> :ok
    end
  end

  defp membership(_page, _member), do: {:error, :relationship_required}

  defp target_kind(%{target_object_id: id}) when is_integer(id) do
    Repo.one(from o in Object, where: o.id == ^id, select: o.kind)
  end

  defp target_kind(%{target_page_id: id}) when is_integer(id) do
    if Repo.exists?(from p in Page, where: p.id == ^id), do: :page
  end

  defp target_kind(_member), do: nil

  @doc "A page's current revision with its ordered membership, or nil."
  def current_revision(%Page{current_revision_id: nil}), do: nil

  def current_revision(%Page{current_revision_id: id}) do
    PageRevision |> Repo.get!(id) |> Repo.preload(:memberships)
  end

  @doc "Every revision of a page, oldest first, with membership."
  def revisions(page_id) do
    Repo.all(
      from r in PageRevision,
        where: r.page_id == ^page_id,
        order_by: r.revision_number,
        preload: :memberships
    )
  end

  @doc false
  def lock!(page_id) do
    Repo.one(from p in Page, where: p.id == ^page_id, lock: "FOR UPDATE")
  end
end
