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

  **Beside the manual writer, two trusted ones (#264).** `create_version/3`
  and its note rule are unchanged: a note is the signed-in author's words,
  and attribution is never an input.

    * `write_proposal/2` writes the generic editor's **model version** from
      one completed attempt: its author the bound bot actor, its notes the
      model's reasons signed under the bot's own label, the owner's kept
      items carried as verified copies. It takes the binding and the frozen
      attempt, never caller-supplied attribution, and publishes nothing;
    * `take_version/3` writes the owner's **manual version from a
      proposal** (Take, Edit-publish): parented to the proposal, every item
      either a verified copy of a proposal item, keeping whoever wrote it, or
      the reviewer's own.

  **The owner's marks (#253 D8, #264 R15)**: `set_mode/4` (`:open` or
  `:mine`), `keep/4` and `unkeep/4`, reviewer acts that write no version and
  change no item.
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
           {:ok, items} <- cite_items(items, c.id, actor.id),
           :ok <-
             DevilsDictionary.Curation.ProviderText.validate(
               [reason, Enum.map(items, & &1.note)],
               items
             ),
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

          insert_items!(items, version)

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
    |> Enum.map(fn item ->
      %{
        item
        | basis:
            DevilsDictionary.Curation.ItemBasis.virtual(
              DevilsDictionary.Curation.ItemBasis.get(item.id)
            )
      }
    end)
  end

  @doc "The newest version of a composition, of any origin, or `nil`."
  def latest_version(composition_id) do
    Repo.one(
      from v in CompositionVersion,
        where: v.composition_id == ^composition_id,
        order_by: [desc: v.version],
        limit: 1
    )
  end

  @doc """
  The newest **manual** version of a composition, or `nil` (#264 R13.2): the
  version the ordinary form opens on and Publish's held path compares with.
  A proposal never makes it stale.
  """
  def latest_manual_version(composition_id) do
    Repo.one(
      from v in CompositionVersion,
        where: v.composition_id == ^composition_id and v.origin == :manual,
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
  # its own review: approval never transfers. Manual versions only (#264
  # R11.4): a proposal is unique by its attempt, and taking one unchanged
  # copies its arrangement exactly.
  defp not_duplicate(composition_id, configuration_version_id, arrangement, fingerprint) do
    case Repo.one(
           from v in CompositionVersion,
             where:
               v.composition_id == ^composition_id and v.origin == :manual and
                 v.configuration_version_id == ^configuration_version_id and
                 v.arrangement_hash == ^arrangement and v.eligibility_fingerprint == ^fingerprint,
             select: v.id
         ) do
      nil -> :ok
      id -> {:error, {:duplicate_version, id}}
    end
  end

  defp cite_items(items, composition_id, actor_id) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      if item.shelf && is_nil(item.shelf_citation_id) do
        case DevilsDictionary.Curation.ShelfCitations.cite(item.shelf, %{
               composition_id: composition_id,
               actor_id: actor_id
             }) do
          {:ok, citation} -> {:cont, {:ok, acc ++ [%{item | shelf_citation_id: citation.id}]}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, acc ++ [item]}}
      end
    end)
  end

  defp insert_items!(items, version, opts \\ []) do
    for item <- items do
      inserted = Repo.insert!(%{item | composition_version_id: version.id})
      DevilsDictionary.Curation.ItemBasis.record!(%{inserted | basis: item.basis}, version, opts)
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

  defp item(role, position, spec, actor) do
    with {:ok, canonical} <- owner_claim_spec(spec),
         do: build_item(role, position, canonical, actor)
  end

  defp owner_claim_spec(%{kind: :claim} = spec) do
    ids =
      case spec[:meaning] do
        {:lexeme, id} ->
          [id]

        {:sense_revision, id} ->
          case Repo.get(DevilsDictionary.Registry.SenseRevision, id) do
            nil -> []
            revision -> [Repo.get!(DevilsDictionary.Registry.Sense, revision.sense_id).lexeme_id]
          end

        _ ->
          []
      end

    basis = spec[:basis] || %{}

    choice =
      DevilsDictionary.Curation.LinkedClaims.for_scope(ids)
      |> Enum.find(fn c ->
        c.claim.id == spec[:assertion_revision_id] and c.meaning == spec[:meaning] and
          c.basis["witness_assertion_revision_id"] == basis["witness_assertion_revision_id"]
      end)

    if choice &&
         (not Map.has_key?(spec, :object_id) or choice.claim.subject_object_id == spec[:object_id]) &&
         Enum.all?(
           ~w(representation shown_object_id witness_assertion_revision_id),
           &(not Map.has_key?(basis, &1) or basis[&1] == choice.basis[&1])
         ) do
      {:ok,
       spec
       |> Map.put(:basis, choice.basis)
       |> Map.put(:object_id, choice.claim.subject_object_id)}
    else
      {:error, :claim_basis_mismatch}
    end
  end

  defp owner_claim_spec(spec), do: {:ok, spec}

  defp build_item(role, position, %{kind: kind} = spec, actor)
       when kind in [:content, :sense_quotation, :sense_definition, :work, :claim] do
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
           shelf_citation_id: spec[:shelf_citation_id],
           shelf: spec[:shelf],
           basis: spec[:basis],
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
  defp build_item(:highlight, position, %{kind: :exemplar} = spec, actor) do
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

  defp build_item(_role, _position, %{kind: :exemplar}, _actor),
    do: {:error, :exemplar_is_a_highlight}

  defp build_item(_role, _position, _spec, _actor), do: {:error, :unknown_item_kind}

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

  @doc """
  C6: within one arrangement that includes an exemplar, no two items show
  the same thing. `:ok`, or `{:error, {:duplicate_display_identity,
  object_id}}` naming the exemplar's object. `create_version/3` refuses on
  it; the operator screen (#257) asks it of an unsaved arrangement, so the
  form says what the record would.

  An item is identified by its object and, for words, by their digest: a
  passage's pinned revision, a quotation's hash, a definition's body. Only
  pairs with an exemplar are compared, so an arrangement of the other kinds
  is judged as slice 1 judged it.
  """
  def one_display_identity(items) do
    identities = Enum.map(items, &{&1, display_identity(&1)})

    exemplars =
      Enum.filter(identities, fn {item, _keys} ->
        item.item_kind in [:exemplar, :claim, :sense_definition] or
          not is_nil(item.shelf_citation_id) or not is_nil(item.shelf)
      end)

    duplicate =
      Enum.find_value(exemplars, fn {exemplar, keys} ->
        Enum.any?(identities, fn {other, other_keys} ->
          other != exemplar and not MapSet.disjoint?(keys, other_keys)
        end) && (exemplar.item_object_id || {:reference, Enum.sort(MapSet.to_list(keys))})
      end)

    if duplicate, do: {:error, {:duplicate_display_identity, duplicate}}, else: :ok
  end

  @doc """
  What an item shows, for C6: its object (a catalog work's registry work)
  and, for words, their digest. Two items whose identities meet show the
  same thing.
  """
  def display_identity(%CompositionItem{} = item) do
    words =
      case item do
        %{item_kind: :sense_definition, words_sha256: sha} -> sha
        %{item_kind: :sense_quotation, words_sha256: sha} -> sha
        %{content_revision_id: id} when is_integer(id) -> words_digest(id)
        _other -> nil
      end

    object =
      cond do
        item.item_kind == :sense_definition ->
          nil

        item.item_kind == :claim ->
          (item.basis && item.basis["shown_object_id"]) || item.item_object_id

        true ->
          item.item_object_id || catalog_object(item)
      end

    provider =
      cond do
        item.shelf_citation_id ->
          c = DevilsDictionary.Curation.ShelfCitations.get(item.shelf_citation_id)
          {:provider, c.source_id, c.external_ref_sha256}

        item.shelf ->
          row =
            Repo.get(
              DevilsDictionary.Discovery.Result,
              item.shelf[:result] || item.shelf["result"]
            )

          run = Repo.get!(DevilsDictionary.Discovery.Run, row.run_id) |> Repo.preload(:mapping)

          {:provider, run.mapping.source_id,
           Digest.sha256(row.external_namespace <> ":" <> row.external_id)}

        true ->
          nil
      end

    [object && {:object, object}, words && {:words, words}, provider]
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

  # ── the trusted writers (#264 R9, R11) ────────────────────────────────────

  # What an item shows, and nothing about why or where: the editor's
  # `@reference_fields` without role, position, meaning and note (#264 R15.2).
  @reference_fields ~w(item_kind item_object_id content_revision_id sense_revision_id
                       source_record_revision_id shelf_citation_id catalog_manifest catalog_checksum
                       catalog_identity locator words_sha256 assertion_revision_id)a

  # Everything a verified copy repeats (the database checks the same).
  @copied_fields @reference_fields ++
                   ~w(meaning_sense_revision_id meaning_lexeme_id note note_author_kind
                      note_author_label note_author_actor_id selection_origin basis)a

  @doc """
  An item's exact reference, as a map of its reference fields: what a kept
  mark names, and what "the same item" means across versions.
  """
  def reference(%CompositionItem{} = item) do
    ref = Map.take(item, @reference_fields)

    if item.item_kind == :claim do
      basis = item.basis || (item.id && DevilsDictionary.Curation.ItemBasis.get(item.id))

      witness =
        if is_struct(basis),
          do: basis.witness_assertion_revision_id,
          else: basis && basis["witness_assertion_revision_id"]

      Map.put(ref, :witness_assertion_revision_id, witness)
    else
      ref
    end
  end

  def reference(%{} = stored) do
    reference =
      Map.new(@reference_fields, fn field ->
        value = Map.get(stored, to_string(field), Map.get(stored, field))

        {field,
         if(field == :item_kind and is_binary(value),
           do: String.to_existing_atom(value),
           else: value
         )}
      end)

    if reference.item_kind == :claim,
      do:
        Map.put(
          reference,
          :witness_assertion_revision_id,
          Map.get(
            stored,
            "witness_assertion_revision_id",
            Map.get(stored, :witness_assertion_revision_id)
          )
        ),
      else: reference
  end

  @doc """
  A readable key for an item's reference, as the screen keys candidates:
  `content-<object>`, `quotation-<sense revision>-<n>`, `work-<object or
  catalog row>`, `exemplar-<claim revision>`.
  """
  def reference_key(%{item_kind: :content, item_object_id: id}), do: "content-#{id}"

  def reference_key(%{item_kind: :sense_quotation, locator: "quotation:" <> n} = ref),
    do: "quotation-#{ref.sense_revision_id}-#{n}"

  def reference_key(%{item_kind: :sense_definition, sense_revision_id: id}), do: "sense-#{id}"

  def reference_key(%{item_kind: :claim, assertion_revision_id: id} = ref),
    do: "claim-#{id}-#{Map.get(ref, :witness_assertion_revision_id) || 0}"

  def reference_key(%{shelf_citation_id: id}) when is_integer(id),
    do: "shelf-#{DevilsDictionary.Curation.ShelfCitations.get(id).discovery_result_id}"

  def reference_key(%{item_kind: :work, item_object_id: id}) when is_integer(id), do: "work-#{id}"

  def reference_key(%{item_kind: :work} = ref),
    do: "work-#{ref.catalog_manifest}-#{ref.catalog_identity}"

  def reference_key(%{item_kind: :exemplar, assertion_revision_id: id}), do: "exemplar-#{id}"
  def reference_key(ref), do: "item-#{inspect(ref)}"

  @doc """
  Writes the generic editor's model version (#264 R9.1–R9.2), inside the
  caller's transaction, under the composition's row lock. The trusted
  writer: `editor` is the binding as `Configurations.editor/1` resolved it,
  and `plan` is

      %{composition, configuration_version, attempt, items}

  where each item is `{:model, %CompositionItem{}}` (an editor's choice,
  its reference and meaning resolved through the frozen packet, its reason
  in `note`) or `{:copy, %CompositionItem{}}` (a kept item of the parent,
  carried with `role` and `position` set). The writer signs the model's
  notes as the bot under its own label and copies the owner's exactly; it
  takes no attribution from the caller.

  The version's parent is the composition's newest version (version history
  stays one line); scope, resolution, lead policy, arrangement hash and
  eligibility fingerprint are computed as `create_version/3` computes them.
  Refused unless the attempt is the binding's, completed and accepted, and
  the arrangement is eligible now under its lead rule and bound.
  """
  def write_proposal(editor, plan) do
    %{composition: c, configuration_version: cv, attempt: attempt} = plan
    bot = editor.bot_actor

    with :ok <- Transaction.check(c.state == :active, :composition_retired),
         :ok <-
           Transaction.check(
             attempt.state == :completed and attempt.outcome == :accepted and
               attempt.model_config_id == editor.model_config.id and
               attempt.requested_by_actor_id == bot.id,
             :attempt_not_the_binding
           ),
         items = proposal_arrangement(plan.items, bot),
         {:ok, items} <- cite_items(items, c.id, bot.id),
         :ok <-
           Transaction.check(
             Enum.count(items, &(&1.role == :highlight)) <= cv.max_highlights,
             {:too_many_highlights, cv.max_highlights}
           ),
         :ok <- one_display_identity(items) do
      members = member_ids(c.id)
      evaluation = Eligibility.evaluate(items, members, c.scope_signature, cv.id)
      latest = latest_version(c.id)

      with {:ok, rule} <- evaluation.lead_rule,
           :ok <- eligible(evaluation) do
        version =
          Repo.insert!(%CompositionVersion{
            composition_id: c.id,
            curation_configuration_id: c.curation_configuration_id,
            configuration_version_id: cv.id,
            version: if(latest, do: latest.version + 1, else: 1),
            parent_version_id: latest && latest.id,
            origin: :model,
            attempt_id: attempt.id,
            change_reason: "Proposed by #{author_label(bot)}, attempt ##{attempt.id}",
            created_by_actor_id: bot.id,
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
            arrangement_hash: Digest.arrangement_hash(items),
            eligibility_fingerprint: evaluation.fingerprint
          })

        insert_items!(items, version)

        {:ok, version}
      end
    end
  end

  @doc """
  The items `write_proposal/2` would write for `plan_items`, unsaved: an
  editor's choice signed by `bot` under its own label, a kept item copied.
  What the proposal's arrangement hash is computed over before it is
  written (#264 R8.4).
  """
  def proposal_arrangement(plan_items, bot), do: Enum.map(plan_items, &proposal_item(&1, bot))

  # An editor's choice is the model's, signed by the bot under its own
  # label; a carried item is the owner's, copied exactly.
  defp proposal_item({:model, %CompositionItem{} = item}, bot) do
    note =
      case item.note && String.trim(item.note) do
        text when is_binary(text) and text != "" ->
          %{
            note: text,
            note_author_kind: :model,
            note_author_label: author_label(bot),
            note_author_actor_id: bot.id
          }

        _blank ->
          %{note: nil, note_author_kind: nil, note_author_label: nil, note_author_actor_id: nil}
      end

    item
    |> Map.merge(note)
    |> Map.merge(%{selection_origin: :model, copied_from_item_id: nil, id: nil})
  end

  defp proposal_item({:copy, %CompositionItem{} = source}, _bot),
    do: copy(source, source.role, source.position)

  # A verified copy: every field the database compares, from the source, and
  # the place it takes now.
  defp copy(%CompositionItem{} = source, role, position) do
    struct(
      CompositionItem,
      source
      |> Map.take(@copied_fields)
      |> Map.merge(%{role: role, position: position, copied_from_item_id: source.id})
    )
  end

  @doc """
  The owner's manual version from a proposal (#264 R11.2–R11.3, #253 §5a
  step 5), as an author, inside the caller's transaction. `attrs`:

    * `:reason`;
    * `:items`: `{:copy, item_id, role, position}`, a verified copy of an
      item of the proposal version (a model item keeps the bot's note,
      signature and `selection_origin: :model`; a carried item keeps the
      owner's), or `{:own, spec, role, position}`, an item spec as
      `create_version/3` takes it, the reviewer's own (`selection_origin:
      :manual`, a human note signed by the reviewer).

  The version's parent is the proposal. Refused unless the proposal is
  still the composition's newest version (`{:stale_parent, newest}`), its
  configuration version is current and the composition active. An
  arrangement equal to an earlier manual version under the same
  configuration version and fingerprint is refused as `{:duplicate_version,
  id}`, as `create_version/3` refuses one (Stage 0 check, recommendation 3):
  Dismiss the proposal, or publish that version.
  """
  def take_version(scope, proposal_version_id, attrs) do
    with {:ok, actor} <- Authority.actor(scope, :author),
         {:ok, reason} <- Transaction.required(Map.to_list(attrs), :reason),
         {:ok, proposal} <-
           Transaction.need(Repo.get(CompositionVersion, proposal_version_id), :not_found),
         :ok <- Transaction.check(proposal.origin == :model, :not_a_proposal),
         {:ok, c} <- lock_active(proposal.composition_id),
         {:ok, _configuration, cv} <- Configurations.current(c.curation_configuration_id),
         :ok <-
           Transaction.check(cv.id == proposal.configuration_version_id, :configuration_changed),
         latest = latest_version(c.id),
         :ok <- expected_parent(latest, proposal.id),
         sources = Map.new(items(proposal.id), &{&1.id, &1}),
         {:ok, items} <- taken_items(Map.fetch!(attrs, :items), sources, actor),
         {:ok, items} <- cite_items(items, c.id, actor.id),
         :ok <-
           DevilsDictionary.Curation.ProviderText.validate(
             [reason, attrs[:quality_note], Enum.map(items, & &1.note)],
             items ++ Map.values(sources)
           ),
         :ok <-
           Transaction.check(
             Enum.count(items, &(&1.role == :highlight)) <= cv.max_highlights,
             {:too_many_highlights, cv.max_highlights}
           ),
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
            version: latest.version + 1,
            parent_version_id: proposal.id,
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

        insert_items!(items, version, review_source: proposal_version_id)

        {:ok, version}
      end
    end
  end

  defp taken_items(specs, sources, actor) do
    Enum.reduce_while(specs, {:ok, []}, fn
      {:copy, id, role, position}, {:ok, acc} ->
        case sources[id] do
          nil -> {:halt, {:error, {:not_a_proposal_item, id}}}
          source -> {:cont, {:ok, acc ++ [copy(source, role, position)]}}
        end

      {:own, spec, role, position}, {:ok, acc} ->
        source =
          if spec[:kind] == :claim do
            probe = DevilsDictionary.Curation.Candidates.probe(spec)

            Enum.find(Map.values(sources), fn source ->
              reference(source) == reference(probe) and
                source.meaning_lexeme_id == probe.meaning_lexeme_id and
                source.meaning_sense_revision_id == probe.meaning_sense_revision_id
            end)
          end

        result =
          if source,
            do: build_item(role, position, Map.put(spec, :basis, source.basis), actor),
            else: item(role, position, spec, actor)

        case result do
          {:ok, item} -> {:cont, {:ok, acc ++ [item]}}
          {:error, reason} -> {:halt, {:error, {reason, role, position}}}
        end
    end)
  end

  # ── the owner's marks (#253 D8, #264 R15) ─────────────────────────────────

  @doc """
  Sets a page's mode, as a reviewer: `:open` (proposals arrive as usual) or
  `:mine` (proposals are shown, flagged, and never taken for the owner).
  `opts`: none yet. Writes no version.
  """
  def set_mode(scope, composition_id, mode, _opts) when mode in [:open, :mine] do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :reviewer),
           {:ok, c} <- lock_active(composition_id) do
        c
        |> Ecto.Changeset.change(
          mode: mode,
          mode_set_by_actor_id: actor.id,
          mode_set_at: DateTime.utc_now()
        )
        |> Repo.update()
      end
    end)
  end

  def set_mode(_scope, _composition_id, _mode, _opts), do: {:error, :unknown_mode}

  @doc """
  Marks an item of the composition's **published** version kept, as a
  reviewer: every proposal carries it while it is marked and eligible
  (#264 R8). The mark names the item's exact reference, a readable key, who
  marked it and when. Writes no version and changes no item.
  """
  def keep(scope, composition_id, item_id, _opts) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :reviewer),
           {:ok, c} <- lock_active(composition_id),
           {:ok, item} <- published_item(c, item_id) do
        ref = reference(item)
        key = reference_key(ref)

        if Enum.any?(c.kept_items, &(&1["key"] == key)) do
          {:ok, c}
        else
          mark = %{
            "key" => key,
            "reference" => Map.new(ref, fn {k, v} -> {to_string(k), json(v)} end),
            "marked_by_actor_id" => actor.id,
            "marked_at" => DateTime.to_iso8601(DateTime.utc_now())
          }

          c |> Ecto.Changeset.change(kept_items: c.kept_items ++ [mark]) |> Repo.update()
        end
      end
    end)
  end

  @doc "Removes a kept mark by its key, as a reviewer. Writes no version."
  def unkeep(scope, composition_id, key, _opts) do
    Transaction.run(fn ->
      with {:ok, _actor} <- Authority.actor(scope, :reviewer),
           {:ok, c} <- lock_active(composition_id),
           :ok <- Transaction.check(Enum.any?(c.kept_items, &(&1["key"] == key)), :not_kept) do
        c
        |> Ecto.Changeset.change(kept_items: Enum.reject(c.kept_items, &(&1["key"] == key)))
        |> Repo.update()
      end
    end)
  end

  defp published_item(%Composition{current_published_version_id: nil}, _id),
    do: {:error, :unpublished}

  defp published_item(%Composition{current_published_version_id: version_id}, id) do
    Transaction.need(
      Repo.one(
        from i in CompositionItem, where: i.id == ^id and i.composition_version_id == ^version_id
      ),
      :not_a_published_item
    )
  end

  defp json(value) when is_atom(value) and not is_nil(value), do: to_string(value)
  defp json(value), do: value

  @doc "The labels of actors by id, as notes are attributed under them."
  def actor_labels(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Repo.all(from a in DevilsDictionary.Sources.Actor, where: a.id in ^ids)
    |> Map.new(&{&1.id, author_label(&1)})
  end

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
