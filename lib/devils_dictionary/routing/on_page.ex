defmodule DevilsDictionary.Routing.OnPage do
  @moduledoc """
  What an On page adds to the lexical reader (#219 B1, B3): the authored
  overview at the requested address, whether it belongs to the words on the
  page, the overviews elsewhere that name those words, and the curated
  members of the one that does.

  **Identity, never a shared label or slug.** An overview is found only at
  its allocated address, through `Routing.Resolver` — the path the reader
  asked for — and nothing re-slugifies a lemma to look for one. It is the
  *treatment* of the lexical aggregate only when its current revision holds a
  `supplies_lexical_material` membership naming one of the page's lexemes or
  one of their senses. An overview at the same address that names none of
  them is a different thing that happens to share the spelling, and the page
  shows it as a separate choice. From a lexical page, the overviews linked
  are exactly those whose membership names one of its lexemes.

  Every read honours the reading mode: an overview, and every page it names,
  is shown only if `Resolver.visible?/2` allows it; a withdrawn page is
  withheld in both modes. Nothing here writes.
  """

  import Ecto.Query

  alias DevilsDictionary.Registry.{Entity, Lexeme, Object, Sense}
  alias DevilsDictionary.Sources.Actor
  alias DevilsDictionary.Repo

  alias DevilsDictionary.Routing.{
    Address,
    Links,
    Page,
    PageMembership,
    Pages,
    Resolution,
    Resolver
  }

  @doc """
  The overview at `raw_path` (the request path as received) in `mode`, or
  nil. Returns `%{resolution: resolution}` for an outcome the caller must
  answer itself (a redirect, gone, invalid, corrupt), and otherwise the
  overview: its page, current revision, address, whether it is the treatment
  of `lexeme_ids`, and its resolved members.
  """
  def overview(raw_path, lexeme_ids, mode) do
    case Resolver.resolve(raw_path, mode: mode) do
      %Resolution{outcome: :canonical, page: %Page{role: :overview} = page} = resolution ->
        treatment(page, lexeme_ids, mode, resolution.location)

      %Resolution{outcome: outcome} = resolution
      when outcome in [:redirect, :gone, :corrupt] ->
        %{resolution: resolution}

      # Missing, unavailable in this mode, not an overview, or not a path the
      # ledger could hold (a lexeme slug need not be a routing segment).
      _other ->
        nil
    end
  end

  defp treatment(page, lexeme_ids, mode, location) do
    case Pages.current_revision(page) do
      nil ->
        nil

      revision ->
        lexical = lexical_targets(revision.memberships)

        %{
          page: page,
          revision: revision,
          address: Address.encode(location),
          draft?: page.publication_state == :draft,
          associated?: associated?(lexical, lexeme_ids),
          members: members(revision.memberships, mode),
          author: actor_label(revision.author_actor_id),
          reviewer: actor_label(revision.reviewer_actor_id)
        }
    end
  end

  defp actor_label(nil), do: nil

  defp actor_label(id),
    do: Repo.one(from a in Actor, where: a.id == ^id, select: a.label)

  # The lexemes a revision supplies lexical material from: a lexeme member
  # itself, a sense member's lexeme.
  defp lexical_targets(memberships) do
    ids =
      for m <- memberships,
          m.relationship == :supplies_lexical_material,
          m.target_object_id,
          do: m.target_object_id

    lexemes = Repo.all(from l in Lexeme, where: l.object_id in ^ids, select: l.object_id)

    senses =
      Repo.all(from s in Sense, where: s.object_id in ^ids, select: s.lexeme_id)

    MapSet.new(lexemes ++ senses)
  end

  defp associated?(lexical, lexeme_ids), do: Enum.any?(lexeme_ids, &MapSet.member?(lexical, &1))

  @doc """
  Overviews other than `except_page_id` whose current revision names one of
  `lexeme_ids` (or one of their senses) as lexical material, each with its
  address in `mode`; an overview not served in `mode` is left out.
  """
  def linked(lexeme_ids, mode, except_page_id \\ nil)
  def linked([], _mode, _except), do: []

  def linked(lexeme_ids, mode, except_page_id) do
    senses = from s in Sense, where: s.lexeme_id in ^lexeme_ids, select: s.object_id

    from(p in Page,
      join: m in PageMembership,
      on: m.page_revision_id == p.current_revision_id,
      join: r in assoc(p, :current_revision),
      where: p.role == :overview and m.relationship == :supplies_lexical_material,
      where: m.target_object_id in ^lexeme_ids or m.target_object_id in subquery(senses),
      distinct: p.id,
      order_by: p.id,
      select: {p, r.title}
    )
    |> Repo.all()
    |> Enum.reject(fn {page, _title} -> page.id == except_page_id end)
    # Its own page, served in the mode: a merged or unserved overview's title
    # is never shown under its successor's address.
    |> Enum.filter(fn {page, _title} ->
      page.lifecycle_state == :active and Resolver.visible?(page, mode)
    end)
    |> Enum.flat_map(fn {page, title} ->
      case Resolver.link(page.id, mode: mode) do
        {:ok, path} ->
          [
            %{
              page_id: page.id,
              title: title,
              path: path,
              draft?: page.publication_state == :draft
            }
          ]

        :error ->
          []
      end
    end)
  end

  @doc """
  A revision's members in stored order, each resolved for reading:

    * `%{kind: :subject, object_id:}` — an entity, or a subject or edition
      page's entity, for the Subjects section's card;
    * `%{kind: :word, lexeme:}` — a lexeme, or a sense's lexeme, linked at
      its exact address;
    * `%{kind: :page, title:, path:}` — another editorial page served in
      `mode`;
    * `%{kind: :withheld, reason:}` — a member that cannot be shown: a
      withdrawn or unavailable page, an identity no longer active, a missing
      target. Never replaced by something else.

  Each keeps its `relationship`, `position` and `rationale`.
  """
  def members(memberships, mode) do
    memberships = Enum.sort_by(memberships, & &1.position)
    object_ids = memberships |> Enum.map(& &1.target_object_id) |> Enum.reject(&is_nil/1)
    page_ids = memberships |> Enum.map(& &1.target_page_id) |> Enum.reject(&is_nil/1)

    objects =
      Repo.all(
        from o in Object,
          left_join: e in Entity,
          on: e.object_id == o.id,
          where: o.id in ^object_ids,
          select: {o.id, {o, e.preferred_label}}
      )
      |> Map.new()

    lexemes =
      Repo.all(
        from l in Lexeme,
          left_join: s in Sense,
          on: s.lexeme_id == l.object_id,
          where: l.object_id in ^object_ids or s.object_id in ^object_ids,
          select: {s.object_id, l}
      )

    lexeme_of =
      Enum.reduce(lexemes, %{}, fn {sense_id, lexeme}, acc ->
        acc |> Map.put(lexeme.object_id, lexeme) |> maybe_put(sense_id, lexeme)
      end)

    pages =
      Repo.all(
        from p in Page,
          left_join: r in assoc(p, :current_revision),
          left_join: e in Entity,
          on: e.object_id == p.target_object_id,
          where: p.id in ^page_ids,
          select: {p.id, {p, r.title, e.preferred_label}}
      )
      |> Map.new()

    Enum.map(memberships, fn m ->
      m
      |> Map.take([:relationship, :position, :rationale])
      |> Map.merge(member(m, objects, lexeme_of, pages, mode))
    end)
  end

  defp maybe_put(map, nil, _value), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp member(%{target_object_id: id}, objects, lexeme_of, _pages, _mode) when is_integer(id) do
    case {objects[id], lexeme_of[id]} do
      {nil, _} ->
        %{kind: :withheld, reason: :missing}

      {{%Object{lifecycle_state: state}, _label}, _} when state != :active ->
        %{kind: :withheld, reason: state}

      {{%Object{kind: :entity}, label}, _} ->
        %{kind: :subject, object_id: id, label: label}

      {_object, %Lexeme{} = lexeme} ->
        %{kind: :word, lexeme: lexeme}

      {{%Object{kind: kind}, _label}, _} ->
        %{kind: :withheld, reason: kind}
    end
  end

  defp member(%{target_page_id: id}, _objects, _lexeme_of, pages, mode) do
    case pages[id] do
      nil ->
        %{kind: :withheld, reason: :missing}

      {%Page{publication_state: :withdrawn}, _title, _label} ->
        %{kind: :withheld, reason: :withdrawn}

      # A subject is named by its identity's label; the page's own revision
      # title is its content, which a draft does not show publicly.
      {%Page{role: role, target_object_id: object_id}, _title, label}
      when role in [:subject, :edition] ->
        %{kind: :subject, object_id: object_id, label: label}

      # Any other page shows its title only when it is itself served in the
      # mode, never through a successor.
      {%Page{} = page, title, label} ->
        with true <- page.lifecycle_state == :active and Resolver.visible?(page, mode),
             {:ok, path} <- Resolver.link(page.id, mode: mode) do
          %{kind: :page, title: title || label, path: path}
        else
          _unserved -> %{kind: :withheld, reason: :unavailable}
        end
    end
  end

  @doc "A subject member's link, through the one link helper."
  def subject_path(object_id, label, mode), do: Links.path(object_id, label, mode)
end
