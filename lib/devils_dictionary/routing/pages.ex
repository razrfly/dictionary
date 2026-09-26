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
  import DevilsDictionary.Routing.Id, only: [is_id: 1]

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
  def ensure(role, target_object_id, locale \\ "en")

  def ensure(role, target_object_id, locale)
      when role in [:subject, :edition, :lexeme] and is_id(target_object_id) do
    with :ok <- fits(role, target_object_id) do
      insert_or_find(role, target_object_id, locale)
    end
  end

  # Refused before any query: a missing or malformed target must be one
  # record's error in a batch, not an exception that rolls the batch back.
  def ensure(role, nil, _locale) when role in [:subject, :edition, :lexeme],
    do: {:error, :target_required}

  def ensure(role, _target_object_id, _locale) when role in [:subject, :edition, :lexeme],
    do: {:error, :invalid_target}

  def ensure(_role, _target_object_id, _locale), do: {:error, :invalid_role}

  # What the database checks at commit, answered before it has to raise.
  defp fits(role, target_object_id) do
    kinds =
      Repo.one(
        from o in Object,
          left_join: e in DevilsDictionary.Registry.Entity,
          on: e.object_id == o.id,
          where: o.id == ^target_object_id,
          select: {o.kind, e.entity_kind}
      )

    case {role, kinds} do
      {:lexeme, {:lexeme, _}} -> :ok
      {:edition, {:entity, :edition}} -> :ok
      {:subject, {:entity, kind}} when kind not in [nil, :edition] -> :ok
      {_role, nil} -> {:error, :target_not_found}
      _mismatch -> {:error, :target_kind_mismatch}
    end
  end

  defp insert_or_find(role, target_object_id, locale) do
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
  #
  # Every refusal is decided before anything is written and returned from the
  # transaction rather than rolled back: a nested `Repo.rollback/1` would
  # abort a caller's batch transaction along with this one revision.
  def add_revision(page_id, attrs, memberships, author_actor_id)
      when is_id(page_id) and is_map(attrs) and is_list(memberships) do
    result =
      Repo.transaction(fn ->
        page = lock!(page_id)

        with :ok <- editable(page),
             :ok <- validate_revision(attrs),
             :ok <- validate_memberships(page, memberships),
             {:ok, revision} <- insert_revision(page, attrs, memberships, author_actor_id) do
          page |> Ecto.Changeset.change(current_revision_id: revision.id) |> Repo.update!()
          {:ok, revision}
        end
      end)

    case result do
      {:ok, outcome} -> outcome
      {:error, reason} -> {:error, reason}
    end
  end

  def add_revision(page_id, _attrs, _memberships, _author_actor_id) when not is_id(page_id),
    do: {:error, :invalid_page}

  def add_revision(_page_id, _attrs, _memberships, _author_actor_id),
    do: {:error, :invalid_revision}

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
    if is_id(id) and Repo.exists?(from a in Actor, where: a.id == ^id),
      do: :ok,
      else: {:error, :actor_required}
  end

  # What the columns and their checks would otherwise refuse by raising.
  defp validate_revision(attrs) do
    cond do
      not text?(attrs[:title]) or not text?(attrs[:body]) -> {:error, :invalid_revision}
      attrs[:body_format] not in [nil, :markdown, :text] -> {:error, :invalid_body_format}
      not (is_nil(attrs[:evidence]) or is_map(attrs[:evidence])) -> {:error, :invalid_evidence}
      is_nil(attrs[:reviewer_actor_id]) -> :ok
      actor(attrs[:reviewer_actor_id]) == :ok -> :ok
      true -> {:error, :invalid_reviewer}
    end
  end

  defp text?(value), do: is_nil(value) or is_binary(value)

  defp validate_memberships(page, memberships) do
    keys = Enum.map(memberships, &membership_key/1)

    cond do
      :invalid in keys -> {:error, :invalid_membership}
      length(Enum.uniq(keys)) != length(keys) -> {:error, :duplicate_membership}
      true -> validate_each(page, memberships)
    end
  end

  defp membership_key(%{} = member) do
    if text?(member[:rationale]) and (is_nil(member[:evidence]) or is_map(member[:evidence])),
      do: {member[:relationship], member[:target_object_id], member[:target_page_id]},
      else: :invalid
  end

  defp membership_key(_member), do: :invalid

  defp validate_each(page, memberships) do
    Enum.reduce_while(memberships, :ok, fn member, :ok ->
      case membership(page, member) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp membership(_page, %{target_object_id: object, target_page_id: page})
       when not is_nil(object) and not is_nil(page),
       do: {:error, :one_target_required}

  defp membership(%Page{id: id}, %{target_page_id: id}), do: {:error, :page_cannot_contain_itself}

  defp membership(_page, %{relationship: :split_successor}),
    do: {:error, :split_successors_are_written_by_the_ledger}

  defp membership(%Page{role: role}, %{relationship: :choice_option}) when role != :choice,
    do: {:error, :choice_options_belong_to_choice_pages}

  defp membership(_page, %{relationship: :choice_option} = member)
       when not is_map_key(member, :target_page_id) or is_nil(member.target_page_id),
       do: {:error, :choice_options_are_pages}

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

  defp target_kind(%{target_object_id: id}) when is_id(id) do
    Repo.one(from o in Object, where: o.id == ^id, select: o.kind)
  end

  defp target_kind(%{target_page_id: id}) when is_id(id) do
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
  def lock!(page_id) when not is_id(page_id), do: nil

  def lock!(page_id) do
    Repo.one(from p in Page, where: p.id == ^page_id, lock: "FOR UPDATE")
  end
end
