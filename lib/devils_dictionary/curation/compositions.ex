defmodule DevilsDictionary.Curation.Compositions do
  @moduledoc """
  Configuration-scoped compositions and their manual versions (#196).

  **Identity (K1–K3).** A composition is `(scope_kind, scope_signature,
  language_tag, configuration)`. The configuration version is not part of
  it. `provision/3` takes registry lexeme ids, never a spelling or a slug.
  The signature is the SHA-256 of the sorted members, and the database
  recomputes it at commit.

  Provisioning is idempotent for an identical scope. It refuses a scope that
  *overlaps* another active composition of the same kind, language and
  configuration (`{:overlapping_scope, ids}`): a split or a merge is
  reconciled explicitly with `change_scope/4`, never guessed. Both run under
  a transaction-scoped advisory lock on (configuration, language), so two
  provisions cannot race past the overlap check.

  **Manual versions (K4–K10).** `create_version/3` freezes an arrangement:

    * at most one lead and up to the configuration version's highlight limit;
    * each item as exact references (`Eligibility`);
    * the Bierce-first rule (`LeadRule`);
    * the author, their reason, and the parent version it replaces.

  A version gets no run, no participant and no ballot: it is manual work and
  says so. Writing a version publishes nothing.
  """

  import Ecto.Query

  alias DevilsDictionary.Curation.{
    Authority,
    Composition,
    CompositionItem,
    CompositionMembership,
    CompositionVersion,
    Configurations,
    Digest,
    Eligibility,
    ScopeChange,
    Transaction
  }

  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.{ContentRevision, Lexeme}
  alias DevilsDictionary.Repo

  # ── identity ──────────────────────────────────────────────────────────────

  @doc """
  Provisions the composition for a scope under an enabled configuration, as
  an author. `attrs`:

    * `:scope_kind`: `:lexeme` (exactly one member) or `:lexical_page`;
    * `:lexeme_ids`: registry lexeme object ids, all in `:language_tag`;
    * `:language_tag`;
    * `:reason`.

  Answers the existing composition for an identical scope.
  """
  def provision(scope, configuration_id, attrs) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :author),
           {:ok, reason} <- Transaction.required(Map.to_list(attrs), :reason),
           {:ok, configuration, _version} <- Configurations.current(configuration_id),
           {:ok, ids} <- members(attrs.scope_kind, attrs.lexeme_ids, attrs.language_tag) do
        lock_scope_space(configuration.id, attrs.language_tag)
        signature = signature(ids)

        case active(configuration.id, attrs.scope_kind, attrs.language_tag, signature) do
          %Composition{} = existing ->
            {:ok, existing}

          nil ->
            with :ok <- no_overlap(configuration.id, attrs, ids, nil) do
              composition =
                Repo.insert!(%Composition{
                  curation_configuration_id: configuration.id,
                  scope_kind: attrs.scope_kind,
                  language_tag: attrs.language_tag,
                  scope_signature: signature,
                  created_by_actor_id: actor.id
                })

              put_members!(composition, [], ids)
              scope_receipt!(composition, nil, signature, ids, actor, reason)
              {:ok, composition}
            end
        end
      end
    end)
  end

  @doc """
  Changes a composition's scope to `lexeme_ids`, as an author, with a
  scope-change receipt. Existing versions keep the scope they were made
  against, so a published version whose scope has since changed is withheld
  on read (`:scope_changed`) until a version is made for the new scope and
  published.
  """
  def change_scope(scope, composition_id, lexeme_ids, opts) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :author),
           {:ok, reason} <- Transaction.required(opts, :reason),
           {:ok, c} <- lock_active(composition_id),
           {:ok, ids} <- members(c.scope_kind, lexeme_ids, c.language_tag) do
        lock_scope_space(c.curation_configuration_id, c.language_tag)
        signature = signature(ids)

        with :ok <- Transaction.check(signature != c.scope_signature, :scope_unchanged),
             :ok <-
               no_overlap(
                 c.curation_configuration_id,
                 %{scope_kind: c.scope_kind, language_tag: c.language_tag},
                 ids,
                 c.id
               ) do
          put_members!(c, member_ids(c.id), ids)
          scope_receipt!(c, c.scope_signature, signature, ids, actor, reason)

          c
          |> Ecto.Changeset.change(scope_signature: signature, lock_version: c.lock_version + 1)
          |> Repo.update()
        end
      end
    end)
  end

  @doc "The member lexeme ids of a composition, sorted."
  def member_ids(composition_id) do
    Repo.all(
      from m in CompositionMembership,
        where: m.composition_id == ^composition_id,
        order_by: m.object_id,
        select: m.object_id
    )
  end

  @doc "The active composition for a scope identity, or `nil`."
  def active(configuration_id, scope_kind, language_tag, signature) do
    Repo.one(
      from c in Composition,
        where:
          c.curation_configuration_id == ^configuration_id and c.scope_kind == ^scope_kind and
            c.language_tag == ^language_tag and c.scope_signature == ^signature and
            c.state == :active
    )
  end

  @doc "The signature of a scope of lexeme ids."
  def signature(lexeme_ids), do: Digest.scope_signature(Enum.map(lexeme_ids, &{:lexeme, &1}))

  defp members(kind, ids, language) when is_list(ids) do
    ids = ids |> Enum.uniq() |> Enum.sort()

    found =
      Repo.all(
        from l in Lexeme, where: l.object_id in ^ids, select: {l.object_id, l.language_tag}
      )

    cond do
      ids == [] ->
        {:error, :empty_scope}

      kind == :lexeme and length(ids) != 1 ->
        {:error, :lexeme_scope_has_one_member}

      length(found) != length(ids) ->
        {:error, {:not_lexemes, ids -- Enum.map(found, &elem(&1, 0))}}

      Enum.any?(found, &(elem(&1, 1) != language)) ->
        {:error, :language_mismatch}

      true ->
        {:ok, ids}
    end
  end

  defp members(_kind, _ids, _language), do: {:error, :empty_scope}

  defp no_overlap(configuration_id, attrs, ids, self_id) do
    query =
      from m in CompositionMembership,
        join: c in Composition,
        on: c.id == m.composition_id,
        where:
          c.curation_configuration_id == ^configuration_id and
            c.scope_kind == ^attrs.scope_kind and c.language_tag == ^attrs.language_tag and
            c.state == :active and m.object_id in ^ids,
        distinct: true,
        select: c.id

    query = if self_id, do: where(query, [_m, c], c.id != ^self_id), else: query
    overlapping = Repo.all(query)

    Transaction.check(overlapping == [], {:overlapping_scope, Enum.sort(overlapping)})
  end

  defp put_members!(composition, current, wanted) do
    removed = current -- wanted

    if removed != [] do
      Repo.delete_all(
        from m in CompositionMembership,
          where: m.composition_id == ^composition.id and m.object_id in ^removed
      )
    end

    for id <- wanted -- current do
      Repo.insert!(%CompositionMembership{composition_id: composition.id, object_id: id})
    end
  end

  defp scope_receipt!(composition, previous, signature, ids, actor, reason) do
    Repo.insert!(%ScopeChange{
      composition_id: composition.id,
      previous_signature: previous,
      scope_signature: signature,
      members: Enum.map(ids, &["lexeme", &1]),
      actor_id: actor.id,
      reason: reason
    })
  end

  defp lock_scope_space(configuration_id, language) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      "curation-scope:#{configuration_id}:#{language}"
    ])
  end

  # ── versions ──────────────────────────────────────────────────────────────

  @doc """
  Writes a manual version of a composition, as an author. `attrs`:

    * `:lead`: one item spec, or `nil`;
    * `:highlights`: a list of item specs, in order;
    * `:reason`;
    * `:expected_parent`: the latest version id the author saw, or `nil`.
      Required, so two authors cannot both write "version 2".

  An item spec is a map with `:kind` (`:content`, `:sense_quotation`,
  `:work` or `:exemplar`), `:object_id`, its exact reference, and `:meaning`
  (`{:lexeme, id}` or `{:sense_revision, id}`):

    * `:content`: `:content_revision_id`;
    * `:sense_quotation`: `:sense_revision_id`, `:locator`
      (`"quotation:N"`), `:words_sha256`;
    * `:work`: `:source_record_revision_id`, or `:catalog` as
      `%{manifest, checksum, identity}`;
    * `:exemplar` (#212, a highlight only): `:assertion_revision_id`, an
      accepted `illustrates` claim. It names no `:object_id`: the object is
      the claim's subject (`:subject_not_an_input`). A passage or quotation
      subject pins its words, the current content revision unless the spec
      names `:content_revision_id`; an entity has none to pin.

  An item may also carry `:assertion_revision_id`, a claim about the object
  it shows (`:claim_not_about_object` otherwise; the database's claim-subject
  key binds every kind), and `:note` as `%{text: text}`: the author's own
  words, attributed to the authenticated actor. A note spec naming its own
  author or kind is refused (`:note_attribution_not_an_input`).

  No two items of an arrangement that include an exemplar show the same
  thing: the same object (a catalog work counts as the registry work that
  carries its row's identity), or the same words
  (`{:duplicate_display_identity, object_id}`, C6).

  The same arrangement under the same configuration version is refused as
  `{:duplicate_version, id}`. Under a newer configuration version it is a new
  version, with no approval of its own until it is reviewed.
  """
  def create_version(scope, composition_id, attrs) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :author),
           {:ok, reason} <- Transaction.required(Map.to_list(attrs), :reason),
           {:ok, c} <- lock_active(composition_id),
           {:ok, _configuration, cv} <- Configurations.current(c.curation_configuration_id),
           latest = latest_version(c.id),
           :ok <- expected_parent(latest, Map.fetch!(attrs, :expected_parent)),
           highlights = Map.get(attrs, :highlights, []),
           :ok <-
             Transaction.check(
               length(highlights) <= cv.max_highlights,
               {:too_many_highlights, cv.max_highlights}
             ),
           {:ok, items} <- build_items(Map.get(attrs, :lead), highlights, actor),
           :ok <- one_display_identity(items) do
        members = member_ids(c.id)
        evaluation = Eligibility.evaluate(items, members, c.scope_signature, cv.id)
        arrangement = Digest.arrangement_hash(items)

        with {:ok, rule} <- evaluation.lead_rule,
             :ok <- eligible(evaluation),
             :ok <- not_duplicate(c.id, cv.id, arrangement, evaluation.fingerprint) do
          version =
            Repo.insert!(%CompositionVersion{
              composition_id: c.id,
              curation_configuration_id: c.curation_configuration_id,
              configuration_version_id: cv.id,
              version: if(latest, do: latest.version + 1, else: 1),
              parent_version_id: latest && latest.id,
              change_reason: reason,
              created_by_actor_id: actor.id,
              scope_signature: c.scope_signature,
              scope_members: Enum.map(members, &["lexeme", &1]),
              resolution:
                resolution(
                  %{
                    "lead_rule" => to_string(rule),
                    "priority_leads" => evaluation.applicable,
                    "language_tag" => c.language_tag,
                    "configuration_version" => cv.version
                  },
                  evaluation
                ),
              lead_policy: cv.lead_policy,
              arrangement_hash: arrangement,
              eligibility_fingerprint: evaluation.fingerprint
            })

          for item <- items, do: Repo.insert!(%{item | composition_version_id: version.id})

          {:ok, version}
        end
      end
    end)
  end

  # What the version was resolved against. An arrangement with an exemplar
  # also records the review context each claim was accepted under, which
  # its fingerprint was computed from (C3); one without is as slice 1 wrote
  # it.
  defp resolution(base, %{claim_contexts: contexts}) when contexts == %{}, do: base

  defp resolution(base, %{claim_contexts: contexts}),
    do: Map.put(base, "claim_contexts", contexts)

  @doc "A version's items, in `(role, position)` order."
  def items(version_id) do
    Repo.all(
      from i in CompositionItem,
        where: i.composition_version_id == ^version_id,
        order_by: [i.role, i.position]
    )
  end

  @doc "The newest version of a composition, or `nil`."
  def latest_version(composition_id) do
    Repo.one(
      from v in CompositionVersion,
        where: v.composition_id == ^composition_id,
        order_by: [desc: v.version],
        limit: 1
    )
  end

  defp expected_parent(nil, nil), do: :ok
  defp expected_parent(%CompositionVersion{id: id}, id), do: :ok
  defp expected_parent(latest, _seen), do: {:error, {:stale_parent, latest && latest.id}}

  defp eligible(%{ok?: true}), do: :ok

  defp eligible(%{results: results}),
    do: {:error, {:ineligible, Enum.reject(results, &(elem(&1, 2) == :ok))}}

  # The same arrangement under the same configuration version is the same
  # version. Under a newer configuration version it is a new one, which needs
  # its own review: approval never transfers.
  defp not_duplicate(composition_id, configuration_version_id, arrangement, fingerprint) do
    case Repo.one(
           from v in CompositionVersion,
             where:
               v.composition_id == ^composition_id and
                 v.configuration_version_id == ^configuration_version_id and
                 v.arrangement_hash == ^arrangement and v.eligibility_fingerprint == ^fingerprint,
             select: v.id
         ) do
      nil -> :ok
      id -> {:error, {:duplicate_version, id}}
    end
  end

  defp build_items(lead, highlights, actor) do
    specs =
      if(lead, do: [{:lead, 1, lead}], else: []) ++
        (highlights |> Enum.with_index(1) |> Enum.map(fn {spec, n} -> {:highlight, n, spec} end))

    Enum.reduce_while(specs, {:ok, []}, fn {role, position, spec}, {:ok, acc} ->
      case item(role, position, spec, actor) do
        {:ok, item} -> {:cont, {:ok, acc ++ [item]}}
        {:error, reason} -> {:halt, {:error, {reason, role, position}}}
      end
    end)
  end

  defp item(role, position, %{kind: kind} = spec, actor)
       when kind in [:content, :sense_quotation, :work] do
    with {:ok, meaning} <- meaning(spec[:meaning]),
         {:ok, note} <- note(spec[:note], actor) do
      catalog = spec[:catalog] || %{}

      {:ok,
       struct(
         CompositionItem,
         %{
           role: role,
           position: position,
           item_kind: kind,
           item_object_id: spec[:object_id],
           content_revision_id: spec[:content_revision_id],
           sense_revision_id: spec[:sense_revision_id],
           source_record_revision_id: spec[:source_record_revision_id],
           catalog_manifest: catalog[:manifest],
           catalog_checksum: catalog[:checksum],
           catalog_identity: catalog[:identity] && to_string(catalog[:identity]),
           locator: spec[:locator],
           words_sha256: spec[:words_sha256],
           assertion_revision_id: spec[:assertion_revision_id],
           selection_origin: :manual
         }
         |> Map.merge(meaning)
         |> Map.merge(note)
       )}
    end
  end

  # An exemplar shows a claim's subject, so the claim names the object, and
  # a passage's words are pinned when the version is made.
  defp item(:highlight, position, %{kind: :exemplar} = spec, actor) do
    with :ok <- Transaction.check(not Map.has_key?(spec, :object_id), :subject_not_an_input),
         {:ok, claim} <- claim(spec[:assertion_revision_id]),
         {:ok, words} <- pinned_words(claim, spec[:content_revision_id]),
         {:ok, meaning} <- meaning(spec[:meaning]),
         {:ok, note} <- note(spec[:note], actor) do
      {:ok,
       struct(
         CompositionItem,
         %{
           role: :highlight,
           position: position,
           item_kind: :exemplar,
           item_object_id: claim.subject_object_id,
           content_revision_id: words,
           assertion_revision_id: claim.id,
           selection_origin: :manual
         }
         |> Map.merge(meaning)
         |> Map.merge(note)
       )}
    end
  end

  defp item(_role, _position, %{kind: :exemplar}, _actor), do: {:error, :exemplar_is_a_highlight}

  defp item(_role, _position, _spec, _actor), do: {:error, :unknown_item_kind}

  defp claim(id) when is_integer(id) do
    Transaction.need(Repo.get(AssertionRevision, id), :claim_not_found)
  end

  defp claim(_id), do: {:error, :claim_required}

  defp pinned_words(%AssertionRevision{subject_kind: "content"} = claim, nil) do
    case Registry.current_content_revision(claim.subject_object_id) do
      %{id: id} -> {:ok, id}
      nil -> {:error, :words_not_found}
    end
  end

  defp pinned_words(%AssertionRevision{subject_kind: "content"}, id) when is_integer(id),
    do: {:ok, id}

  defp pinned_words(%AssertionRevision{}, nil), do: {:ok, nil}
  defp pinned_words(%AssertionRevision{}, _id), do: {:error, :entity_has_no_words}

  # C6: within one arrangement that includes an exemplar, no two items show
  # the same thing. An item is identified by its object and, for words, by
  # their digest: a passage's pinned revision, a quotation's hash, a
  # definition's body. Only pairs with an exemplar are compared, so an
  # arrangement of the other kinds is judged as slice 1 judged it.
  defp one_display_identity(items) do
    identities = Enum.map(items, &{&1, display_identity(&1)})
    exemplars = Enum.filter(identities, fn {item, _keys} -> item.item_kind == :exemplar end)

    duplicate =
      Enum.find_value(exemplars, fn {exemplar, keys} ->
        Enum.any?(identities, fn {other, other_keys} ->
          other != exemplar and not MapSet.disjoint?(keys, other_keys)
        end) && exemplar.item_object_id
      end)

    if duplicate, do: {:error, {:duplicate_display_identity, duplicate}}, else: :ok
  end

  defp display_identity(%CompositionItem{} = item) do
    words =
      case item do
        %{item_kind: :sense_quotation, words_sha256: sha} -> sha
        %{content_revision_id: id} when is_integer(id) -> words_digest(id)
        _other -> nil
      end

    object = item.item_object_id || catalog_object(item)

    [object && {:object, object}, words && {:words, words}]
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # A catalog-only work is the registry work carrying its row's identity,
  # when there is one: an exemplar of that work shows the same thing.
  defp catalog_object(%CompositionItem{item_kind: :work, catalog_manifest: name} = item)
       when is_binary(name),
       do: Eligibility.catalog_object(name, item.catalog_checksum, item.catalog_identity)

  defp catalog_object(_item), do: nil

  defp words_digest(content_revision_id) do
    case Repo.one(from r in ContentRevision, where: r.id == ^content_revision_id, select: r.body) do
      body when is_binary(body) -> Digest.sha256(body)
      _none -> nil
    end
  end

  defp meaning({:lexeme, id}) when is_integer(id),
    do: {:ok, %{meaning_lexeme_id: id, meaning_sense_revision_id: nil}}

  defp meaning({:sense_revision, id}) when is_integer(id),
    do: {:ok, %{meaning_sense_revision_id: id, meaning_lexeme_id: nil}}

  defp meaning(_meaning), do: {:error, :meaning_required}

  # A manual version's note is its author's own words, attributed to the
  # authenticated actor and nobody else. A note spec is its text alone:
  # attribution is never an input, so a caller naming an author, or a kind,
  # is refused rather than quietly overridden. A model note has no place in
  # manual work. The database checks the same (`note_author_actor_id`).
  defp note(nil, _actor),
    do:
      {:ok,
       %{note: nil, note_author_kind: nil, note_author_label: nil, note_author_actor_id: nil}}

  defp note(%{text: text} = note, actor) when is_binary(text) and map_size(note) == 1 do
    if String.trim(text) == "" do
      {:error, :note_empty}
    else
      {:ok,
       %{
         note: text,
         note_author_kind: :human,
         note_author_label: author_label(actor),
         note_author_actor_id: actor.id
       }}
    end
  end

  defp note(%{text: _text}, _actor), do: {:error, :note_attribution_not_an_input}
  defp note(_note, _actor), do: {:error, :note_invalid}

  @doc "The label an actor's notes are attributed under: its own, or its account number."
  def author_label(actor), do: actor.label || "Account ##{actor.id}"

  defp lock_active(id) do
    case Repo.one(from c in Composition, where: c.id == ^id, lock: "FOR UPDATE") do
      nil -> {:error, :not_found}
      %Composition{state: :active} = c -> {:ok, c}
      %Composition{} -> {:error, :composition_retired}
    end
  end
end
