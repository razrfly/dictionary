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

  alias DevilsDictionary.Claims.{
    AssertionEvidence,
    AssertionRevision,
    ReviewContext,
    ReviewContextItem
  }

  alias DevilsDictionary.Sources.ReconciliationCase
  alias DevilsDictionary.Sources.Actor

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

  @doc """
  Mints the person or organization a Wikidata QID names, credited by a
  provider for something it holds (#164 C7).

  Takes the attrs `SourceIdentity.Creators.prepare/2` read from the item — `qid`,
  `kind` (from `P31`), `label`, `description`, the dates — plus the
  `source_record_revision_id` of the Wikidata record they came from and the
  `minted_by` provider slug. The kind comes from Wikidata and never from the
  provider: a human is `create_person/1`, with a `person_details` row even when
  both dates are unknown so a minted page reads like a seeded one; an
  organization is `create_entity/1`. Anything else is
  `{:permanent, :not_a_creator_kind}` and nothing is written.

  The QID is added as a **verified** identifier. That unique index is the whole
  guarantee two providers crediting Q9068 get one Voltaire; the caller holds
  the advisory lock that makes the check-then-mint safe.
  """
  def mint_creator(%{qid: qid, kind: kind} = attrs) when kind in [:person, :organization] do
    metadata =
      %{
        "minted_by" => attrs[:minted_by],
        "minted_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "wikidata_instance_of" => attrs[:instance_of],
        "birth_year" => attrs[:birth_year],
        "death_year" => attrs[:death_year]
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
      |> Map.new()

    entity_attrs = %{
      preferred_label: attrs.label,
      description: attrs[:description],
      metadata: metadata
    }

    Repo.transaction(fn ->
      {:ok, entity} =
        case kind do
          :person ->
            create_person(
              Map.merge(entity_attrs, %{
                birth_date: attrs[:birth_date],
                death_date: attrs[:death_date]
              })
            )

          :organization ->
            create_entity(Map.put(entity_attrs, :entity_kind, :organization))
        end

      {:ok, _identifier} =
        add_external_id(entity.object_id, "wikidata", qid, %{
          source_record_revision_id: attrs[:source_record_revision_id],
          metadata: %{
            "asserted_by" => attrs[:minted_by],
            "identity_evidence" => "minted_from_wikidata"
          }
        })

      entity
    end)
  end

  def mint_creator(%{qid: _qid}), do: {:permanent, :not_a_creator_kind}

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
    with {:ok, inputs} <- lifecycle_inputs(input_ids, output_id),
         {:ok, reason} <- lifecycle_reason(opts) do
      Repo.transaction(fn ->
        objects = lock_lifecycle_objects(inputs ++ [output_id])
        validate_lifecycle_objects!(objects, inputs, [output_id])

        for id <- inputs do
          preserve_entity_label_as_alias(id, output_id)
          move_names(id, output_id)
          move_external_ids(id, output_id)

          Map.fetch!(objects, id)
          |> Ecto.Changeset.change(lifecycle_state: :merged)
          |> Repo.update!()
        end

        members = Enum.map(inputs, &{&1, :input}) ++ [{output_id, :output}]
        record_event(:merge, members, accountable_opts(opts, reason))
      end)
    end
  end

  defp lifecycle_inputs(input_ids, output_id) do
    inputs = input_ids |> Enum.uniq()

    cond do
      inputs == [] -> {:error, :inputs_required}
      output_id in inputs -> {:error, :output_cannot_be_input}
      true -> {:ok, inputs}
    end
  end

  defp lifecycle_reason(opts) do
    case opts[:reason] |> to_string() |> String.trim() do
      "" -> {:error, :reason_required}
      reason -> {:ok, reason}
    end
  end

  defp lock_lifecycle_objects(ids) do
    Object
    |> where([o], o.id in ^Enum.uniq(ids))
    |> order_by([o], o.id)
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp validate_lifecycle_objects!(objects, input_ids, output_ids) do
    ids = Enum.uniq(input_ids ++ output_ids)

    if map_size(objects) != length(ids), do: Repo.rollback(:object_not_found)

    if Enum.any?(ids, &(Map.fetch!(objects, &1).lifecycle_state != :active)),
      do: Repo.rollback(:object_not_active)

    signatures = ids |> Enum.map(&identity_signature(Map.fetch!(objects, &1))) |> Enum.uniq()
    if length(signatures) != 1, do: Repo.rollback(:incompatible_kinds)
  end

  defp identity_signature(%Object{kind: :entity, id: id}),
    do: {:entity, Repo.get!(Entity, id).entity_kind}

  defp identity_signature(%Object{kind: :content, id: id}),
    do: {:content, Repo.get!(ContentItem, id).content_kind}

  defp identity_signature(%Object{kind: kind}), do: {kind, nil}

  defp accountable_opts(opts, reason) do
    actor_id = opts[:actor_id] || lifecycle_actor!().id
    opts |> Keyword.put(:actor_id, actor_id) |> Keyword.put(:reason, reason)
  end

  defp lifecycle_actor! do
    label = "Registry lifecycle system"

    Repo.insert!(
      %Actor{
        actor_kind: :import,
        label: label,
        metadata: %{"accountability" => "caller did not supply a human actor"}
      },
      on_conflict: :nothing,
      conflict_target:
        {:unsafe_fragment,
         "(label) WHERE actor_kind = 'import' AND label = 'Registry lifecycle system'"}
    )

    Repo.get_by!(Actor, actor_kind: :import, label: label)
  end

  defp preserve_entity_label_as_alias(from_id, to_id) do
    with %Entity{preferred_label: label} when is_binary(label) and label != "" <-
           Repo.get(Entity, from_id),
         false <-
           Repo.exists?(
             from n in ObjectName,
               where:
                 n.object_id == ^to_id and n.name == ^label and n.name_kind == "alias" and
                   is_nil(n.language_tag)
           ) do
      %ObjectName{}
      |> ObjectName.changeset(%{object_id: to_id, name: label, name_kind: "alias"})
      |> Repo.insert!()
    else
      _ -> :ok
    end
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
    outputs = Enum.uniq(output_ids)

    with :ok <- validate_split_shape(input_id, outputs),
         {:ok, reason} <- lifecycle_reason(opts) do
      Repo.transaction(fn ->
        objects = lock_lifecycle_objects([input_id | outputs])
        validate_lifecycle_objects!(objects, [input_id], outputs)

        members = [{input_id, :input}] ++ Enum.map(outputs, &{&1, :output})
        opts = accountable_opts(opts, reason)
        event = record_event(:split, members, opts)

        open_split_cases(input_id, outputs, event, opts)

        Map.fetch!(objects, input_id)
        |> Ecto.Changeset.change(lifecycle_state: :split)
        |> Repo.update!()

        event
      end)
    end
  end

  defp validate_split_shape(input_id, outputs) do
    cond do
      length(outputs) < 2 -> {:error, :multiple_outputs_required}
      input_id in outputs -> {:error, :output_cannot_be_input}
      true -> :ok
    end
  end

  defp open_split_cases(input_id, output_ids, event, opts) do
    attached =
      Repo.all(
        from r in AssertionRevision,
          where:
            r.is_current and
              (r.subject_object_id == ^input_id or r.object_object_id == ^input_id or
                 r.context_object_id == ^input_id or r.jurisdiction_entity_id == ^input_id)
      )

    evidence_attached =
      Repo.all(
        from e in AssertionEvidence,
          join: r in AssertionRevision,
          on: r.id == e.assertion_revision_id and r.is_current,
          left_join: c in ContentRevision,
          on: c.id == e.content_revision_id,
          left_join: s in SenseRevision,
          on: s.id == e.sense_revision_id,
          where: c.content_id == ^input_id or s.sense_id == ^input_id,
          select: {r.assertion_id, r.id}
      )

    review_attached =
      Repo.all(
        from i in ReviewContextItem,
          join: context in ReviewContext,
          on: context.id == i.context_id,
          join: r in AssertionRevision,
          on: r.id == context.assertion_revision_id and r.is_current,
          left_join: c in ContentRevision,
          on: c.id == i.content_revision_id,
          left_join: s in SenseRevision,
          on: s.id == i.sense_revision_id,
          where: c.content_id == ^input_id or s.sense_id == ^input_id,
          select: {r.assertion_id, r.id}
      )

    attached =
      attached
      |> Enum.map(fn revision ->
        roles =
          []
          |> maybe_role(revision.subject_object_id == input_id, "subject")
          |> maybe_role(revision.object_object_id == input_id, "object")
          |> maybe_role(revision.context_object_id == input_id, "context")
          |> maybe_role(revision.jurisdiction_entity_id == input_id, "jurisdiction")

        {revision.assertion_id, revision.id, roles}
      end)

    attached =
      Enum.reduce(evidence_attached, attached, fn {assertion_id, revision_id}, rows ->
        add_attachment_role(rows, assertion_id, revision_id, "evidence")
      end)

    attached =
      Enum.reduce(review_attached, attached, fn {assertion_id, revision_id}, rows ->
        add_attachment_role(rows, assertion_id, revision_id, "review_context")
      end)

    for {assertion_id, revision_id, roles} <- attached do
      %ReconciliationCase{}
      |> ReconciliationCase.changeset(%{
        kind: "identity_split",
        object_id: input_id,
        assertion_id: assertion_id,
        opened_run_id: opts[:run_id],
        payload: %{
          "identity_event_id" => event.id,
          "assertion_revision_id" => revision_id,
          "endpoint_role" => if(length(roles) == 1, do: hd(roles), else: nil),
          "attachment_roles" => roles,
          "candidate_output_ids" => output_ids
        }
      })
      |> Repo.insert!()
    end
  end

  defp maybe_role(roles, true, role), do: [role | roles]
  defp maybe_role(roles, false, _role), do: roles

  defp add_attachment_role(rows, assertion_id, revision_id, role) do
    case Enum.split_with(rows, fn {id, _revision, _roles} -> id == assertion_id end) do
      {[], rest} -> [{assertion_id, revision_id, [role]} | rest]
      {[{id, rev, roles}], rest} -> [{id, rev, Enum.uniq([role | roles])} | rest]
    end
  end

  @doc """
  Where an identity went: `{:merged, id}`, `{:split, ids}`, `{:cycle, ids}`,
  `:itself`, or `nil` when the object does not exist.

  This is what keeps an old link meaningful after a merge. The link still points
  at the object it always pointed at — nothing was rewritten — and a reader that
  wants the live identity asks here rather than guessing from a label.
  """
  def resolve(object_id) do
    do_resolve(object_id, MapSet.new())
  end

  defp do_resolve(object_id, seen) do
    if MapSet.member?(seen, object_id) do
      {:cycle, Enum.sort(MapSet.to_list(seen))}
    else
      seen = MapSet.put(seen, object_id)

      case Repo.get(Object, object_id) do
        nil ->
          nil

        %Object{lifecycle_state: state} when state in [:merged, :split] ->
          operation = if(state == :merged, do: :merge, else: :split)
          outputs = event_outputs(object_id, operation)

          case {state, outputs} do
            {:merged, [id]} ->
              case do_resolve(id, seen) do
                {:merged, final_id} -> {:merged, final_id}
                :itself -> {:merged, id}
                other -> other
              end

            {:merged, []} ->
              :itself

            {:split, ids} ->
              {:split, ids}

            {:merged, ids} ->
              {:split, ids}
          end

        %Object{} ->
          :itself
      end
    end
  end

  @doc "The live canonical id for a merged identity, or the id itself."
  def canonical_id(object_id) do
    case resolve(object_id) do
      {:merged, id} -> id
      _ -> object_id
    end
  end

  @doc "The live canonical ids for a collection, resolved in bounded batches."
  def canonical_ids(object_ids) do
    ids = Enum.uniq(object_ids)
    merge_edges = load_merge_edges(ids, MapSet.new(), %{})

    Map.new(ids, fn id -> {id, canonical_from_edges(id, id, merge_edges, MapSet.new())} end)
  end

  @doc """
  Every historical merge input that canonically resolves to the same survivor.

  Claim revisions are immutable, so reads aggregate this family rather than
  rewriting historical endpoints during a merge.
  """
  def canonical_family(object_id) do
    canonical = canonical_id(object_id)

    collect_merge_inputs([canonical], MapSet.new()) |> MapSet.to_list()
  end

  defp collect_merge_inputs([], seen), do: seen

  defp collect_merge_inputs(ids, seen) do
    ids = Enum.reject(ids, &MapSet.member?(seen, &1))
    seen = Enum.reduce(ids, seen, &MapSet.put(&2, &1))

    inputs =
      Repo.all(
        from input in IdentityEventMember,
          join: event in assoc(input, :event),
          join: output in IdentityEventMember,
          on: output.event_id == event.id and output.role == :output,
          where: event.operation == :merge and input.role == :input and output.object_id in ^ids,
          select: input.object_id
      )
      |> Enum.uniq()

    collect_merge_inputs(inputs, seen)
  end

  defp load_merge_edges([], _seen, edges), do: edges

  defp load_merge_edges(frontier, seen, edges) do
    frontier = Enum.reject(frontier, &MapSet.member?(seen, &1))

    if frontier == [] do
      edges
    else
      seen = Enum.reduce(frontier, seen, &MapSet.put(&2, &1))

      objects =
        Repo.all(
          from object in Object,
            where: object.id in ^frontier,
            select: {object.id, object.lifecycle_state}
        )

      existing_ids = MapSet.new(objects, &elem(&1, 0))

      merged_ids =
        for {id, :merged} <- objects, do: id

      rows =
        Repo.all(
          from input in IdentityEventMember,
            join: event in assoc(input, :event),
            join: output in IdentityEventMember,
            on: output.event_id == event.id and output.role == :output,
            where:
              input.object_id in ^merged_ids and input.role == :input and
                event.operation == :merge,
            order_by: [asc: input.object_id, desc: event.id, asc: output.object_id],
            select: {input.object_id, event.id, output.object_id}
        )

      latest_edges =
        rows
        |> Enum.group_by(fn {input_id, _event_id, _output_id} -> input_id end)
        |> Map.new(fn {input_id, input_rows} ->
          latest_event_id = input_rows |> List.first() |> elem(1)

          outputs =
            input_rows
            |> Enum.take_while(fn {_input_id, event_id, _output_id} ->
              event_id == latest_event_id
            end)
            |> Enum.map(&elem(&1, 2))

          {input_id, outputs}
        end)

      missing_edges =
        frontier
        |> Enum.reject(&MapSet.member?(existing_ids, &1))
        |> Map.new(&{&1, :missing})

      edges = edges |> Map.merge(missing_edges) |> Map.merge(latest_edges)
      next = latest_edges |> Map.values() |> List.flatten() |> Enum.uniq()
      load_merge_edges(next, seen, edges)
    end
  end

  defp canonical_from_edges(current, original, edges, seen) do
    cond do
      MapSet.member?(seen, current) ->
        original

      true ->
        case Map.get(edges, current) do
          [next] -> canonical_from_edges(next, original, edges, MapSet.put(seen, current))
          :missing -> original
          nil -> current
          _ -> original
        end
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
