defmodule DevilsDictionary.Routing.Subjects do
  @moduledoc """
  The Subjects section of an On page (#219 B3): one card per subject, each
  with the state its classification decision and page give it, read in **one
  bounded statement** per page.

  Two sources, kept apart:

    * **curated** — the ids an authored overview's current revision names, in
      its stored order. Never truncated and never reordered; a member that is
      no longer an active identity is withheld rather than replaced.
    * **discovered** — the identities the page's sources name (the thing,
      disagreements, `may_refer_to` candidates) and the active entities whose
      preferred label, or any recorded name, equals one of the page's lemmas
      after NFC and case folding. Deduplicated by object id, never by label,
      and without anything already curated. Sorted addressed first (an
      address the reading mode serves), then by family, label and id, and
      capped at `limit`, with the total kept.

  Nothing here writes: the section reads state and a draft is never shown as
  public (the link and the state come from `Routing.Links.served/3`, the
  resolver's own decision).

  ## Card states

  | state | when | link |
  |---|---|---|
  | `:addressed` | the page's canonical is served in the reading mode | the canonical (a draft marked in internal mode) |
  | `:not_yet_public` | an address, but a draft read publicly | `/entities/:id/:slug` |
  | `:no_address` | mapped, no address yet — or its page withdrawn, which reads as none | `/entities/:id/:slug` |
  | `:awaiting_review` | `needs_review`, with its candidate families | `/entities/:id/:slug` |
  | `:identity_review` | `identity_review` | `/entities/:id/:slug` |
  | `:source_page` | `excluded_source_page` | `/entities/:id/:slug` |
  | `:unclassified` | no decision | `/entities/:id/:slug` |

  On the published host, read publicly (#237 D2), a card with no served
  address has no link at all: `Routing.Links.fallback/3` gives it none, and
  the card shows its label as text.
  """

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.{Address, Links, Page, PublicPath}

  @default_limit 24

  # The statement's enum columns come back as text; these are the schemas' own
  # values, so no atom is made from a row (and none depends on a module having
  # been loaded first).
  @roles Map.new(Ecto.Enum.values(Page, :role), &{Atom.to_string(&1), &1})
  @publications Map.new(Ecto.Enum.values(Page, :publication_state), &{Atom.to_string(&1), &1})
  @lifecycles Map.new(Ecto.Enum.values(Page, :lifecycle_state), &{Atom.to_string(&1), &1})
  @kinds Map.new(Ecto.Enum.values(PublicPath, :kind), &{Atom.to_string(&1), &1})

  # The matched names come in through a lateral join per pattern, so each
  # pattern can use the trigram index on `entities.preferred_label` (a
  # `LIKE ANY (array)` cannot); the folded equality then decides. Recorded
  # names use the `lower(name)` index.
  @statement """
  WITH named AS (
    SELECT m.object_id
      FROM unnest($3::text[]) AS pattern(value)
      CROSS JOIN LATERAL (
        SELECT e.object_id FROM entities e
         WHERE e.preferred_label ILIKE pattern.value
           AND lower(normalize(e.preferred_label, NFC)) = ANY($4::text[])
      ) m
    UNION
    SELECT n.object_id FROM object_names n
     WHERE lower(n.name) = ANY($4::text[])
  ),
  wanted AS (
    SELECT id AS object_id, true AS curated FROM unnest($1::bigint[]) AS id
    UNION ALL
    SELECT d.object_id, false
      FROM (SELECT unnest($2::bigint[]) AS object_id UNION SELECT object_id FROM named) d
     WHERE d.object_id <> ALL($1::bigint[])
  ),
  cards AS (
    SELECT w.curated, e.object_id, e.preferred_label AS label, e.description,
           e.entity_kind::text AS kind, o.lifecycle_state::text AS identity,
           e.metadata->>'fixture' AS fixture,
           (SELECT min(x.external_id) FROM external_identifiers x
             WHERE x.object_id = e.object_id AND x.namespace = 'wikidata'
               AND x.status = 'verified') AS qid,
           d.status::text AS status, d.family::text AS decided_family,
           d.candidate_families::text[] AS candidate_families,
           p.id AS page_id, p.role::text AS role, p.publication_state::text AS publication,
           p.lifecycle_state::text AS lifecycle, p.canonical_path_id,
           c.id AS path_id, c.path, c.kind::text AS path_kind, c.destination_page_id,
           c.original_page_id
      FROM wanted w
      JOIN entities e ON e.object_id = w.object_id
      JOIN objects o ON o.id = e.object_id
      LEFT JOIN classification_decisions d ON d.object_id = e.object_id AND d.is_current
      LEFT JOIN pages p ON p.target_object_id = e.object_id
       AND p.role IN ('subject', 'edition') AND p.locale = 'en'
      LEFT JOIN public_paths c ON c.id = p.canonical_path_id
  )
  (SELECT *, NULL::bigint AS total FROM cards WHERE curated)
  UNION ALL
  (SELECT *, count(*) OVER () AS total FROM cards
    WHERE NOT curated AND identity = 'active'
    ORDER BY (path_id IS NOT NULL AND lifecycle = 'active'
              AND (publication = 'published' OR ($6::boolean AND publication = 'draft'))) DESC,
             coalesce(substring(path from '^/([^/]+)/'), decided_family) NULLS LAST,
             lower(label), object_id
    LIMIT $5)
  """

  @doc """
  The cards for a page. `curated` is the overview's subject ids in stored
  order, `discovered` the ids the page's sources name, `lemmas` the page's
  lemmas for name matching. Returns `%{curated: [card | {:withheld, id}],
  discovered: [card], discovered_total: n}`.
  """
  def cards(curated, discovered, lemmas, mode, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    {patterns, folded} = names(lemmas)
    curated = Enum.uniq(curated)

    %{rows: rows, columns: columns} =
      Repo.query!(@statement, [
        curated,
        Enum.uniq(discovered),
        patterns,
        folded,
        limit,
        # "Addressed" is what the mode serves (merged and split pages, which
        # `Links` resolves by id, sort as unaddressed).
        mode == :internal
      ])

    # The statement's own column names, a fixed set.
    keys = Enum.map(columns, &String.to_atom/1)
    rows = Enum.map(rows, &(keys |> Enum.zip(&1) |> Map.new()))
    {curated_rows, discovered_rows} = Enum.split_with(rows, & &1.curated)
    by_id = Map.new(curated_rows, &{&1.object_id, &1})

    %{
      curated:
        Enum.map(curated, fn id ->
          # Withdrawn content is withheld, never shown in its place (B3).
          case by_id[id] do
            %{identity: "active", publication: publication} = row
            when publication != "withdrawn" ->
              card(row, mode)

            _missing_inactive_or_withdrawn ->
              {:withheld, id}
          end
        end),
      discovered: Enum.map(discovered_rows, &card(&1, mode)),
      discovered_total: discovered_rows |> List.first(%{}) |> Map.get(:total) || 0
    }
  end

  @doc """
  The patterns and folded names a lemma set matches: each lemma NFC- and
  NFD-normalized and lowercased, so a label stored in either form is found
  and a shared label never needs to be anything but equal.
  """
  def names(lemmas) do
    folded =
      lemmas
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.flat_map(fn lemma ->
        [String.normalize(lemma, :nfc), String.normalize(lemma, :nfd)]
      end)
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    {Enum.map(folded, &escape_like/1), folded}
  end

  defp escape_like(text), do: String.replace(text, ~r/[\\%_]/u, "\\\\\\0")

  @doc "One card from a row of the statement, in `mode`."
  def card(row, mode) do
    {page, canonical} = page_rows(row)
    served = page && canonical && Links.served(page, canonical, mode)

    # A withdrawn page is withheld in both modes, as a request for its address
    # is: the card reads as if there were none. An unserved address is never
    # shown, nor its namespace.
    state =
      cond do
        served -> :addressed
        canonical && page.publication_state == :draft -> :not_yet_public
        row.status == "mapped" -> :no_address
        row.status == "needs_review" -> :awaiting_review
        row.status == "identity_review" -> :identity_review
        row.status == "excluded_source_page" -> :source_page
        true -> :unclassified
      end

    family =
      cond do
        served -> Address.family(row.path)
        # The decision's family, which an allocation must match: never the
        # unserved address itself.
        state in [:no_address, :not_yet_public] -> row.decided_family
        true -> nil
      end

    %{
      object_id: row.object_id,
      label: row.label,
      description: row.description,
      kind: row.kind,
      qid: row.qid,
      fixture: row.fixture,
      state: state,
      family: family,
      family_label: family && Address.label(family),
      candidate_families: row.candidate_families || [],
      role: page && page.role,
      page_id: page && page.id,
      address: served && canonical.path,
      draft?: state == :addressed and page.publication_state == :draft,
      path: served || Links.fallback(row.object_id, row.label, mode)
    }
  end

  defp page_rows(%{page_id: nil}), do: {nil, nil}

  defp page_rows(row) do
    page = %Page{
      id: row.page_id,
      role: Map.fetch!(@roles, row.role),
      target_object_id: row.object_id,
      publication_state: Map.fetch!(@publications, row.publication),
      lifecycle_state: Map.fetch!(@lifecycles, row.lifecycle),
      canonical_path_id: row.canonical_path_id
    }

    canonical =
      row.path_id &&
        %PublicPath{
          id: row.path_id,
          path: row.path,
          kind: Map.fetch!(@kinds, row.path_kind),
          destination_page_id: row.destination_page_id,
          original_page_id: row.original_page_id
        }

    {page, canonical}
  end
end
