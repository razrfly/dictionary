defmodule DevilsDictionary.Registry do
  @moduledoc """
  Creating and reading identities.

  Every object is two rows — the `objects` row and its typed subtype — and the
  database checks at COMMIT that both are there. So every creation here runs in
  a transaction, and the functions return `{:ok, struct}` or raise; there is no
  way to make half an identity through this module, and a caller that reaches
  around it is still refused by the database.

  What this module deliberately does **not** do: merge by name, infer identity
  from a slug, or require an external identifier. Names are evidence
  (`object_names`), external ids are namespaced and statused
  (`external_identifiers`), and a local artwork with neither is a first-class
  identity.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Sources.ReconciliationCase

  alias DevilsDictionary.Registry.{
    ContentItem,
    ContentRevision,
    EditionDetails,
    Entity,
    ExternalIdentifier,
    IdentityEvent,
    IdentityEventMember,
    Lexeme,
    LexemeForm,
    Object,
    ObjectName,
    PersonDetails,
    Sense,
    SenseRevision,
    WorkDetails
  }

  alias DevilsDictionary.Repo

  # ── creating identities ───────────────────────────────────────────────────

  @doc """
  Creates a lexeme: the `objects` row and the `lexemes` row, in one transaction.

  `lexical_key` is computed from language, lemma and part of speech rather than
  supplied, so two callers cannot disagree about what identifies a word.
  """
  def create_lexeme(attrs) do
    create_object(:lexeme, Lexeme, attrs)
  end

  @doc "Creates an entity of the given `entity_kind`."
  def create_entity(attrs) do
    create_object(:entity, Entity, attrs)
  end

  @doc """
  Creates a person: an entity plus its `person_details` row.

  There is no separate population of authors. This is the same call that makes
  a biography subject, because they are the same thing.
  """
  def create_person(attrs) do
    {details, entity_attrs} = Map.split(attrs, [:birth_date, :death_date])

    Repo.transaction(fn ->
      {:ok, entity} = create_entity(Map.put(entity_attrs, :entity_kind, :person))

      %PersonDetails{}
      |> PersonDetails.changeset(Map.put(details, :entity_id, entity.object_id))
      |> Repo.insert!()

      entity
    end)
  end

  @doc "Creates a work: an entity plus its `work_details` row."
  def create_work(attrs) do
    {details, entity_attrs} =
      Map.split(attrs, [:work_kind, :original_language, :first_published_year])

    Repo.transaction(fn ->
      {:ok, entity} = create_entity(Map.put(entity_attrs, :entity_kind, :work))

      %WorkDetails{}
      |> WorkDetails.changeset(Map.put(details, :entity_id, entity.object_id))
      |> Repo.insert!()

      entity
    end)
  end

  @doc """
  Creates an edition of a work.

  `work_id` references `work_details`, so an edition of a person is refused by
  the database rather than by a validation someone can forget to run.
  """
  def create_edition(attrs) do
    {details, entity_attrs} =
      Map.split(attrs, [:work_id, :edition_label, :publication_year, :language_tag])

    Repo.transaction(fn ->
      {:ok, entity} = create_entity(Map.put(entity_attrs, :entity_kind, :edition))

      %EditionDetails{}
      |> EditionDetails.changeset(Map.put(details, :entity_id, entity.object_id))
      |> Repo.insert!()

      entity
    end)
  end

  @doc """
  Creates a content item with its first revision, which becomes current.

  A content item with no revision would be a body-less definition, so the two
  are one call. The deferred exactly-one-current trigger would refuse the
  alternative anyway.
  """
  def create_content(attrs) do
    # `metadata` belongs to the revision — the printed grammar marker and the
    # thumbnail are facts about *this* version of the text. `item_metadata` is
    # the escape hatch for a fact about the item itself.
    {revision, item_attrs} =
      Map.split(attrs, [
        :body,
        :body_format,
        :canonical_url,
        :headword,
        :position,
        :year,
        :rights_metadata,
        :metadata,
        :source_record_revision_id
      ])

    item_attrs =
      case Map.pop(item_attrs, :item_metadata) do
        {nil, rest} -> rest
        {metadata, rest} -> Map.put(rest, :metadata, metadata)
      end

    Repo.transaction(fn ->
      {:ok, item} = create_object(:content, ContentItem, item_attrs)
      {:ok, _rev} = do_add_content_revision(item.object_id, revision)
      item
    end)
  end

  @doc """
  Creates a source-specific sense with its first revision.

  `external_key` is what the source called it — provenance, never identity.
  """
  def create_sense(attrs) do
    # `metadata` is a revision field: it carries the QIDs and the ILI a source
    # asserted *in this wording*, which is exactly the kind of thing that must
    # not be silently carried across a reword.
    {revision, sense_attrs} =
      Map.split(attrs, [
        :gloss,
        :group_key,
        :position,
        :tags,
        :topics,
        :examples,
        :url,
        :metadata,
        :source_record_revision_id
      ])

    Repo.transaction(fn ->
      {:ok, sense} = create_object(:sense, Sense, sense_attrs)
      {:ok, _rev} = do_add_sense_revision(sense.object_id, revision)
      sense
    end)
  end

  defp create_object(kind, module, attrs) do
    Repo.transaction(fn ->
      object =
        %Object{}
        |> Object.changeset(%{kind: kind})
        |> Repo.insert!()

      attrs = attrs |> normalize() |> Map.put(:object_id, object.id)

      # `Repo.insert`, not `insert!`: a duplicate `lexical_key` passes every
      # validation and is refused by the unique index, so the changeset is valid
      # right up until the database disagrees.
      case module |> struct() |> module.changeset(attrs) |> Repo.insert() do
        {:ok, row} -> row
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Callers hand these in as maps with atom keys, maps with string keys (from a
  # form or a JSON payload) or keyword lists. `to_existing_atom` rather than
  # `to_atom`: a string key from user input must not be able to grow the atom
  # table.
  defp normalize(attrs) when is_list(attrs), do: normalize(Map.new(attrs))

  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  # ── revisions ─────────────────────────────────────────────────────────────

  @doc """
  Adds a revision to a sense and makes it current.

  Two statements rather than one, and the old current is cleared before the new
  one lands: a partial unique index cannot be deferred, so the switch has to be
  ordered rather than simultaneous. Gate 0 measured that a single-statement flag
  move also works, but the ordered form is the one that stays correct if the
  index is ever rebuilt differently.
  """
  def add_sense_revision(sense_id, attrs) do
    Repo.transaction(fn ->
      lock_sense(sense_id)

      case do_add_sense_revision(sense_id, attrs) do
        {:ok, revision} -> revision
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp do_add_sense_revision(sense_id, attrs) do
    next = next_revision_number(SenseRevision, :sense_id, sense_id)

    # Currentness only. What the outgoing revision asserted is history, and
    # #74 keeps that separate from which revision is in force.
    from(r in SenseRevision, where: r.sense_id == ^sense_id and r.is_current)
    |> Repo.update_all(set: [is_current: false])

    %SenseRevision{}
    |> SenseRevision.changeset(
      attrs
      |> normalize()
      |> Map.merge(%{sense_id: sense_id, revision_number: next, is_current: true})
    )
    |> Repo.insert()
  end

  @doc "Adds a revision to a content item and makes it current."
  def add_content_revision(content_id, attrs) do
    Repo.transaction(fn ->
      lock_content(content_id)

      case do_add_content_revision(content_id, attrs) do
        {:ok, revision} -> revision
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp do_add_content_revision(content_id, attrs) do
    next = next_revision_number(ContentRevision, :content_id, content_id)

    from(r in ContentRevision, where: r.content_id == ^content_id and r.is_current)
    |> Repo.update_all(set: [is_current: false])

    %ContentRevision{}
    |> ContentRevision.changeset(
      attrs
      |> normalize()
      |> Map.merge(%{content_id: content_id, revision_number: next, is_current: true})
    )
    |> Repo.insert()
  end

  defp next_revision_number(module, key, id) do
    query = from r in module, where: field(r, ^key) == ^id, select: max(r.revision_number)
    (Repo.one(query) || 0) + 1
  end

  # Row locks, taken first. Without them two writers can each compute the same
  # next revision number and one loses to the unique index -- Gate 0 reproduced
  # exactly that with the statements ordered the other way round.
  defp lock_sense(id), do: lock_row("senses", "object_id", id)
  defp lock_content(id), do: lock_row("content_items", "object_id", id)

  defp lock_row(table, column, id) do
    Repo.query!("SELECT 1 FROM #{table} WHERE #{column} = $1 FOR UPDATE", [id])
  end

  # ── reading ───────────────────────────────────────────────────────────────

  @doc "The current revision of a sense, or nil."
  def current_sense_revision(sense_id) do
    Repo.one(from r in SenseRevision, where: r.sense_id == ^sense_id and r.is_current)
  end

  @doc "The current revision of a content item, or nil."
  def current_content_revision(content_id) do
    Repo.one(from r in ContentRevision, where: r.content_id == ^content_id and r.is_current)
  end

  @doc "A lexeme by its lossless identity key, or nil."
  def lexeme_by_key(language_tag, lemma, part_of_speech) do
    Repo.get_by(Lexeme, lexical_key: Lexeme.lexical_key(language_tag, lemma, part_of_speech))
  end

  @doc "An object's kind and lifecycle state, or nil."
  def object(id), do: Repo.get(Object, id)

  # ── names, identifiers, forms ─────────────────────────────────────────────

  @doc "Records a name an object is known by. Names never create identities."
  def add_name(object_id, name, attrs \\ %{}) do
    %ObjectName{}
    |> ObjectName.changeset(Map.merge(normalize(attrs), %{object_id: object_id, name: name}))
    |> Repo.insert()
  end

  @doc """
  Maps an object to an identifier in some other system.

  Defaults to `:verified`, which is unique per namespace. Pass
  `status: :candidate` for an unconfirmed match — several may coexist, and none
  of them silently becomes the answer.
  """
  def add_external_id(object_id, namespace, external_id, attrs \\ %{}) do
    %ExternalIdentifier{}
    |> ExternalIdentifier.changeset(
      Map.merge(normalize(attrs), %{
        object_id: object_id,
        namespace: namespace,
        external_id: external_id
      })
    )
    |> Repo.insert()
  end

  @doc "The object carrying a verified external identifier, or nil."
  def by_external_id(namespace, external_id) do
    Repo.one(
      from e in ExternalIdentifier,
        where:
          e.namespace == ^namespace and e.external_id == ^external_id and e.status == :verified,
        select: e.object_id
    )
  end

  @doc "Records a written form of a word, with the revision that attested it."
  def add_form(lexeme_id, written_form, attrs \\ %{}) do
    %LexemeForm{}
    |> LexemeForm.changeset(
      Map.merge(normalize(attrs), %{lexeme_id: lexeme_id, written_form: written_form})
    )
    |> Repo.insert()
  end

  # ── lifecycle ─────────────────────────────────────────────────────────────

  @doc """
  Retires an identity, with an audit trail.

  Never a delete. Everything that referenced it keeps resolving, its history
  stays inspectable, and the database refuses the alternative anyway — deleting
  a subtype row out from under a live object raises.
  """
  def retire(object_id, opts \\ []) do
    Repo.transaction(fn ->
      Repo.get!(Object, object_id) |> Object.retire_changeset() |> Repo.update!()
      record_event(:retire, [{object_id, :input}], opts)
    end)
  end

  @doc """
  Merges identities into a surviving one, recording every input and the output.

  #73: merge only with evidence, and preserve aliases, provenance and old links.
  What that means concretely, and what this does:

    * **Names move.** Every `object_names` row on a retired input is re-pointed
      at the survivor, because a merge's whole claim is that those names named
      this thing all along. A name the survivor already has is dropped rather
      than duplicated.
    * **External identifiers move**, keeping their namespace. Where the survivor
      already holds a *verified* id in that namespace, the incoming one lands as
      a `candidate` instead — the unique-among-verified index is the rule, and
      a merge is not a licence to break it or to silently discard the evidence.
    * **Assertions are not rewritten.** A revision is immutable and says what it
      said; re-pointing its endpoint would forge history. Old links keep
      resolving because the input object still exists, reads `merged`, and
      `resolve/1` follows the event to the survivor.

  Retirement is `merged`, not `retired`: they are different things that happened.
  """
  def merge(input_ids, output_id, opts \\ []) do
    inputs = Enum.reject(input_ids, &(&1 == output_id))

    Repo.transaction(fn ->
      for id <- inputs do
        move_names(id, output_id)
        move_external_ids(id, output_id)

        Repo.get!(Object, id)
        |> Ecto.Changeset.change(lifecycle_state: :merged)
        |> Repo.update!()
      end

      members = Enum.map(input_ids, &{&1, :input}) ++ [{output_id, :output}]

      record_event(:merge, members, opts)
    end)
  end

  # A name the survivor already carries is not worth a second row; the unique
  # index would refuse it anyway.
  defp move_names(from_id, to_id) do
    held =
      Repo.all(
        from n in ObjectName,
          where: n.object_id == ^to_id,
          select: {n.name, n.name_kind, n.language_tag}
      )
      |> MapSet.new()

    for name <- Repo.all(from n in ObjectName, where: n.object_id == ^from_id) do
      if MapSet.member?(held, {name.name, name.name_kind, name.language_tag}) do
        Repo.delete!(name)
      else
        name |> Ecto.Changeset.change(object_id: to_id) |> Repo.update!()
      end
    end
  end

  # `verified` is unique per namespace and external id. Where the survivor
  # already has one, the input's becomes a candidate: the evidence is kept and
  # the conflict is visible, which is what #74 asks for over a silent drop.
  defp move_external_ids(from_id, to_id) do
    for identifier <- Repo.all(from i in ExternalIdentifier, where: i.object_id == ^from_id) do
      taken? =
        Repo.exists?(
          from i in ExternalIdentifier,
            where:
              i.object_id == ^to_id and i.namespace == ^identifier.namespace and
                i.status == :verified
        )

      status =
        if taken? and identifier.status == :verified, do: :candidate, else: identifier.status

      identifier
      |> Ecto.Changeset.change(object_id: to_id, status: status)
      |> Repo.update!()
    end
  end

  @doc """
  Splits one identity into several, naming every output.

  A split has many outputs, which is why membership is a table. #73: ambiguous
  attachments enter explicit review; they are **never** reassigned by guesswork,
  so this deliberately moves nothing. Every current assertion revision touching
  the input opens a `reconciliation_cases` row naming the assertion and the
  candidate outputs, and a person decides which output it belonged to.

  The input reads `split` rather than `retired`, and `resolve/1` returns every
  output rather than picking one — an ambiguous identity has no single answer
  and pretending otherwise is the defect this guards against.
  """
  def split(input_id, output_ids, opts \\ []) do
    Repo.transaction(fn ->
      members = [{input_id, :input}] ++ Enum.map(output_ids, &{&1, :output})
      event = record_event(:split, members, opts)

      open_split_cases(input_id, output_ids, event, opts)

      Repo.get!(Object, input_id)
      |> Ecto.Changeset.change(lifecycle_state: :split)
      |> Repo.update!()

      event
    end)
  end

  defp open_split_cases(input_id, output_ids, event, opts) do
    attached =
      Repo.all(
        from r in AssertionRevision,
          where:
            r.is_current and
              (r.subject_object_id == ^input_id or r.object_object_id == ^input_id),
          select: {r.assertion_id, r.id, r.subject_object_id == ^input_id}
      )

    for {assertion_id, revision_id, subject?} <- attached do
      %ReconciliationCase{}
      |> ReconciliationCase.changeset(%{
        kind: "identity_split",
        object_id: input_id,
        assertion_id: assertion_id,
        opened_run_id: opts[:run_id],
        payload: %{
          "identity_event_id" => event.id,
          "assertion_revision_id" => revision_id,
          "endpoint_role" => if(subject?, do: "subject", else: "object"),
          "candidate_output_ids" => output_ids
        }
      })
      |> Repo.insert!()
    end
  end

  @doc """
  Where a retired identity went: `{:merged, id}`, `{:split, ids}`, or `:itself`.

  This is what keeps an old link meaningful after a merge. The link still points
  at the object it always pointed at — nothing was rewritten — and a reader that
  wants the live identity asks here rather than guessing from a label.
  """
  def resolve(object_id) do
    case Repo.get(Object, object_id) do
      nil ->
        nil

      %Object{lifecycle_state: state} when state in [:merged, :split] ->
        outputs = event_outputs(object_id, state)

        case {state, outputs} do
          {:merged, [id]} -> {:merged, id}
          {:merged, []} -> :itself
          {:split, ids} -> {:split, ids}
          {:merged, ids} -> {:split, ids}
        end

      %Object{} ->
        :itself
    end
  end

  # The most recent such event, then its outputs. An object can in principle be
  # merged twice; the latest event is the one that says where it is now.
  defp event_outputs(object_id, operation) do
    latest =
      Repo.one(
        from m in IdentityEventMember,
          join: e in assoc(m, :event),
          where: m.object_id == ^object_id and m.role == :input and e.operation == ^operation,
          order_by: [desc: e.id],
          limit: 1,
          select: e.id
      )

    case latest do
      nil ->
        []

      event_id ->
        Repo.all(
          from m in IdentityEventMember,
            where: m.event_id == ^event_id and m.role == :output and m.object_id != ^object_id,
            order_by: m.object_id,
            select: m.object_id
        )
    end
  end

  defp record_event(operation, members, opts) do
    event =
      %IdentityEvent{}
      |> IdentityEvent.changeset(%{
        operation: operation,
        actor_id: opts[:actor_id],
        reason: opts[:reason]
      })
      |> Repo.insert!()

    for {object_id, role} <- members do
      %IdentityEventMember{}
      |> IdentityEventMember.changeset(%{
        event_id: event.id,
        object_id: object_id,
        role: role
      })
      |> Repo.insert!()
    end

    event
  end

  @doc "The identity events an object took part in, newest first."
  def identity_history(object_id) do
    Repo.all(
      from m in IdentityEventMember,
        join: e in assoc(m, :event),
        where: m.object_id == ^object_id,
        order_by: [desc: e.inserted_at],
        preload: [event: e]
    )
  end
end
