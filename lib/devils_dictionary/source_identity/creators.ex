defmodule DevilsDictionary.SourceIdentity.Creators do
  @moduledoc """
  Creator identity for every provider (#164): a result credits a person by an
  identifier it read, the kit resolves or mints the person, and one assertion
  per relationship records the credit.

  A provider's whole contribution is the relationship on its entry —
  `%{role: "authored_by", target_identifiers: [%{namespace: "wikidata",
  external_id: "Q9068"}], certainty: :verified}`. It never names a person and
  never searches: **no label is consulted anywhere in this module.** A result
  with no creator identifier has no relationship, keeps its text line, and
  nothing here runs for it.

  ## Two phases (#164 C1)

  `prepare/2` runs **outside** the publication transaction. It collects every
  relationship target across a run's entries, looks them all up in
  `external_identifiers` in one query, crosswalks Open Library author keys to
  QIDs by Wikidata `P648`, and fetches only the QIDs still missing — each
  request drawn against the `wikidata` budget row through
  `Discovery.Budget.claim_shared/4`. What comes back is a map:

      %{"Q9068" => {:ok, attrs} | {:transient, reason} | {:permanent, reason},
        {"olid", "OL26320A"} => {:ok, "Q..."} | {:transient, _} | {:permanent, _}}

  `apply/3` runs **inside** it, under `SourceIdentity.lock_entries/2`, whose
  lock set includes every target key (and every crosswalked QID). It matches
  again under the lock — a person another run minted meanwhile is `:matched`,
  not minted twice — mints only what is still absent from the prepared attrs,
  and writes the assertions. It never touches the network.

  ## The lifecycle (#164 C3)

  `origin_key` is `"<role>:<subject stable id>"`, without the target, and a
  second creator in the same role is `":2"`, a third `":3"`, in the provider's
  own order. So a re-run upserts, a correction is a revision, and a creator the
  provider stopped naming is withdrawn with the reason
  `provider_removed_creator`. A current revision that is not the provider's own
  — another method, a review decision, or a `verifier` in its metadata — is
  never touched by a provider refresh; the result's creator entry says
  `overridden` instead.

  ## Failures (#164 C7)

  `{:transient, _}` (a 429, a timeout, an exhausted budget, or a target nobody
  prepared) leaves the relationship `deferred`: no assertion, no case, and the
  provider's next refresh tries again. `{:permanent, _}` (a missing or
  redirected item, a `P31` that is neither a human nor an organization) opens
  one `unresolved_creator` reconciliation case per `(source, QID)`, deduplicated
  by `reconciliation_cases_open_qid_index`.
  """

  import Ecto.Query

  alias DevilsDictionary.Absorb.Clients.Wikidata, as: Client
  alias DevilsDictionary.Absorb.Sources.Wikidata, as: WikidataSource
  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{Assertion, AssertionReview, AssertionRevision}
  alias DevilsDictionary.Claims.PredicateEndpointRule
  alias DevilsDictionary.Discovery.Budget
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.{ContentItem, Entity, ExternalIdentifier, Object}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.SourceIdentity.Entry
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.{Actor, MaterializedOutput, ReconciliationCase, Source}

  @method "provider_relationship"
  @removed "provider_removed_creator"
  @case_kind "unresolved_creator"

  # Wikidata's `P31` classes a creator may be. Direct instance-of only: a
  # subclass walk would make every item a candidate for something, and a class
  # this list lacks is a permanent case an operator can read, not a guess.
  @human "Q5"
  @organization_classes ~w(Q43229 Q4830453 Q163740 Q783794 Q11032 Q2085381 Q1320047
                           Q18127 Q375336 Q215380 Q16334295 Q7278 Q327333 Q3918 Q31855
                           Q33506 Q1331793 Q210167 Q5633421)
  # The statements a minted person's facts are read from, kept on the source
  # record beside `Sources.Wikidata.trim/1`'s own whitelist so the provenance
  # holds what the row was made from.
  @minted_properties ~w(P31 P569 P570 P648)

  @doc "How an assertion written by this module names its method."
  def method, do: @method

  @doc "The withdrawal reason for a creator a provider stopped naming."
  def removed_reason, do: @removed

  @doc "The reconciliation case kind for a creator identifier nothing can resolve."
  def case_kind, do: @case_kind

  @doc "The confidence a relationship's certainty lands as."
  def confidence(:verified), do: 1.0
  def confidence(:candidate), do: 0.5

  # ── the reader ───────────────────────────────────────────────────────────

  @doc """
  Who the registry credits for each subject **now**: `%{subject_id =>
  [%{object_id, label}]}`, from one `Claims.outgoing/2` read over all of them.

  The shelf's creator line is a link only where this says so (#164 C5). It
  reads current, active, publicly visible `authored_by` claims — whoever wrote
  them — so a curator's correction links the corrected person and a withdrawn
  or rejected credit is simply absent on the next render. The
  `preview_metadata["creators"]` a run wrote is never consulted here.
  """
  def credited([]), do: %{}

  def credited(subject_ids) when is_list(subject_ids) do
    subject_ids = Enum.uniq(subject_ids)
    canonical = Registry.canonical_ids(subject_ids)

    revisions =
      Claims.outgoing(subject_ids,
        predicate: "authored_by",
        subject_kind: nil,
        limit: 12 * length(subject_ids)
      )
      |> Enum.filter(&(&1.object_kind == "entity"))

    labels =
      Repo.all(
        from e in Entity,
          where: e.object_id in ^Enum.map(revisions, & &1.object_object_id),
          select: {e.object_id, e.preferred_label}
      )
      |> Map.new()

    by_subject =
      revisions
      |> Enum.group_by(& &1.subject_object_id)
      |> Map.new(fn {subject_id, rows} ->
        {subject_id,
         rows
         |> Enum.uniq_by(& &1.object_object_id)
         |> Enum.map(
           &%{object_id: &1.object_object_id, label: Map.get(labels, &1.object_object_id)}
         )
         |> Enum.reject(&is_nil(&1.label))}
      end)

    Map.new(subject_ids, fn id -> {id, Map.get(by_subject, Map.fetch!(canonical, id), [])} end)
  end

  # ── prepare: outside the transaction ─────────────────────────────────────

  @doc """
  Every relationship target key across entries, as `{namespace, external_id}`.
  """
  def targets(entries) do
    for %Entry{relationships: relationships} <- entries,
        relationship <- relationships,
        identifier <- relationship.target_identifiers,
        uniq: true,
        do: {identifier.namespace, identifier.external_id}
  end

  @doc """
  Resolves what can only be learned over the network, before any lock is taken.

  Options: `:run_id` (the discovery run whose budget context the fetches are
  recorded under), or `:claim`, a `fn stage -> {:ok, wait_ms} | other end` a
  caller outside discovery supplies. With neither, nothing is fetched and every
  missing target is `{:transient, :unbudgeted}` — the network is never reached
  by accident.
  """
  def prepare(entries, opts \\ []) do
    case targets(entries) do
      [] ->
        %{}

      targets ->
        claim = claim_fun(opts)
        held = held(targets)

        olid_misses =
          for {"olid", external_id} = key <- targets, not Map.has_key?(held, key), do: external_id

        {crosswalk, budget} = crosswalk(olid_misses, claim)

        crosswalked =
          for {_key, {:ok, qid}} <- crosswalk, uniq: true, do: {"wikidata", qid}

        held = Map.merge(held, held(crosswalked))

        missing =
          for {"wikidata", qid} = key <- targets ++ crosswalked,
              not Map.has_key?(held, key),
              uniq: true,
              do: qid

        {fetched, _budget} = fetch(missing, claim, budget)

        Map.merge(crosswalk, fetched)
    end
  end

  @doc """
  The lock keys a prepared map adds for one entry: the QID each Open Library
  key crosswalked to, so two runs reaching one person through two namespaces
  still serialise on it.
  """
  def crosswalk_lock_keys(%Entry{} = entry, prepared) do
    for relationship <- entry.relationships,
        %{namespace: "olid", external_id: external_id} <- relationship.target_identifiers,
        {:ok, qid} <- [Map.get(prepared, {"olid", external_id})],
        do: "wikidata:#{qid}"
  end

  defp held([]), do: %{}

  defp held(keys) do
    namespaces = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    external_ids = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    wanted = MapSet.new(keys)

    ExternalIdentifier
    |> where(
      [i],
      i.status == :verified and i.namespace in ^namespaces and i.external_id in ^external_ids
    )
    |> select([i], {i.namespace, i.external_id, i.object_id})
    |> Repo.all()
    |> Enum.filter(fn {namespace, external_id, _} ->
      MapSet.member?(wanted, {namespace, external_id})
    end)
    |> Map.new(fn {namespace, external_id, object_id} ->
      {{namespace, external_id}, object_id}
    end)
  end

  defp claim_fun(opts) do
    cond do
      is_function(opts[:claim], 1) ->
        opts[:claim]

      opts[:run_id] ->
        run_id = opts[:run_id]

        fn stage ->
          Budget.claim_shared("wikidata", run_id, stage,
            request_interval_ms: WikidataSource.rate_limit_ms()
          )
        end

      true ->
        fn _stage -> {:error, :unbudgeted} end
    end
  end

  # `budget` is `:open` until one claim is refused; after that nothing else is
  # asked for, and everything still waiting is deferred with the refusal.
  defp crosswalk(external_ids, claim) do
    Enum.reduce(external_ids, {%{}, :open}, fn external_id, {acc, budget} ->
      case spend(claim, "wikidata:crosswalk", budget) do
        {:ok, budget} ->
          outcome =
            case Client.items_with_statement("P648", external_id, rate_limit_ms: 0) do
              {:ok, [qid]} -> {:ok, qid}
              {:ok, []} -> {:permanent, :no_wikidata_item}
              {:ok, _several} -> {:permanent, :ambiguous_crosswalk}
              {:error, reason} -> {:transient, transient(reason)}
            end

          {Map.put(acc, {"olid", external_id}, outcome), budget}

        {:refused, reason, budget} ->
          {Map.put(acc, {"olid", external_id}, {:transient, reason}), budget}
      end
    end)
  end

  defp fetch(qids, claim, budget) do
    qids
    |> Enum.chunk_every(Client.batch_size())
    |> Enum.reduce({%{}, budget}, fn chunk, {acc, budget} ->
      case spend(claim, "wikidata:entity", budget) do
        {:ok, budget} ->
          outcomes =
            case Client.fetch(chunk, rate_limit_ms: 0) do
              {:ok, entities} -> Map.new(chunk, &{&1, classify(&1, entities)})
              {:error, reason} -> Map.new(chunk, &{&1, {:transient, transient(reason)}})
            end

          {Map.merge(acc, outcomes), budget}

        {:refused, reason, budget} ->
          {Map.merge(acc, Map.new(chunk, &{&1, {:transient, reason}})), budget}
      end
    end)
  end

  defp spend(_claim, _stage, {:refused, reason}), do: {:refused, reason, {:refused, reason}}

  defp spend(claim, stage, :open) do
    case claim.(stage) do
      {:ok, wait_ms} ->
        if wait_ms > 0, do: Process.sleep(wait_ms)
        {:ok, :open}

      {:deferred, _seconds} ->
        {:refused, :budget_exhausted, {:refused, :budget_exhausted}}

      {:error, reason} ->
        {:refused, reason, {:refused, reason}}
    end
  end

  defp transient({:rate_limited, _seconds}), do: :rate_limited
  defp transient({:http, status}), do: :"http_#{status}"
  defp transient({:transport, _}), do: :transport
  defp transient(reason) when is_atom(reason), do: reason
  defp transient(_reason), do: :request_failed

  @doc """
  What one fetched item is, as a creator: attrs to mint from, or why not.

  Public so the fixture tests can state the classification rule directly.
  """
  def classify(qid, entities) do
    case Map.get(entities, qid) do
      nil ->
        if Enum.any?(entities, fn {_id, entity} -> redirected_from?(entity, qid) end),
          do: {:permanent, :redirected},
          else: {:permanent, :missing}

      %{"id" => id} when id != qid ->
        {:permanent, :redirected}

      entity ->
        classes = Client.entity_ids(entity, "P31")

        cond do
          @human in classes ->
            {:ok, attrs(qid, :person, entity)}

          Enum.any?(classes, &(&1 in @organization_classes)) ->
            {:ok, attrs(qid, :organization, entity)}

          true ->
            {:permanent, :not_a_creator_kind}
        end
    end
  end

  defp redirected_from?(%{"redirects" => %{"from" => from}}, qid), do: from == qid
  defp redirected_from?(_entity, _qid), do: false

  defp attrs(qid, kind, entity) do
    {birth_date, birth_year} = date(entity, "P569")
    {death_date, death_year} = date(entity, "P570")

    %{
      qid: qid,
      kind: kind,
      # A display fact, read from the item the QID names, never used to find it.
      label:
        get_in(entity, ["labels", "en", "value"]) || get_in(entity, ["labels", "mul", "value"]) ||
          qid,
      description: get_in(entity, ["descriptions", "en", "value"]),
      birth_date: birth_date,
      death_date: death_date,
      birth_year: birth_year,
      death_year: death_year,
      instance_of: Client.entity_ids(entity, "P31"),
      payload: payload(entity)
    }
  end

  # The time value as Wikidata states it. A day-precision date is a `Date`; a
  # coarser one (a year, a century) is only a year, because `person_details`
  # holds dates and inventing "1 January" would print a day nobody asserted.
  defp date(entity, property) do
    case Client.statements(entity, property) |> Enum.reject(&(&1.rank == "deprecated")) do
      [%{value: %{"time" => time} = value} | _] ->
        year = year(time)
        precision = value["precision"]

        date =
          with true <- precision == 11,
               [_, y, m, d] <- Regex.run(~r/\A([+-]\d+)-(\d{2})-(\d{2})T/, time),
               {:ok, date} <-
                 Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
            date
          else
            _ -> nil
          end

        {date, year}

      _ ->
        {nil, nil}
    end
  end

  defp year(time) do
    case Regex.run(~r/\A([+-]\d+)-/, time) do
      [_, year] -> String.to_integer(year)
      _ -> nil
    end
  end

  defp payload(entity) do
    trimmed = WikidataSource.trim(entity)

    extra =
      entity
      |> Map.get("claims", %{})
      |> Map.take(@minted_properties)
      |> Map.new(fn {property, statements} ->
        {property, Enum.map(statements, &Map.take(&1, ["mainsnak", "rank", "type"]))}
      end)

    trimmed
    |> Map.update("claims", extra, &Map.merge(&1, extra))
    |> Map.put("_creator_identity_version", 1)
  end

  # ── apply: inside the transaction ────────────────────────────────────────

  @doc """
  Resolves and records every relationship of one resolved subject.

  Called by `SourceIdentity.resolve/2` inside its transaction, after the
  subject resolved and under the lock set that covers the targets. Returns one
  outcome per relationship, in the provider's order:

      %{role, target, qid, state, object_id, label, reason}

  where `state` is `:matched`, `:minted`, `:overridden`, `:deferred` or
  `:unresolved`.
  """
  def apply(entry, subject_id, prepared, opts \\ [])

  def apply(%Entry{relationships: []} = entry, _subject_id, _prepared, _opts)
      when is_nil(entry.source_id),
      do: []

  # An assertion's origin key is unique per source, so a credit with no source
  # to hold it could not be re-run idempotently. Such an entry (a hand-built
  # proposal, a corpus seed) is reported deferred and writes nothing.
  def apply(%Entry{source_id: nil} = entry, _subject_id, _prepared, _opts) do
    Enum.map(entry.relationships, fn relationship ->
      %{
        role: relationship.role,
        target: nil,
        qid: nil,
        state: :deferred,
        object_id: nil,
        label: nil,
        reason: "no_source",
        write: :none
      }
    end)
  end

  def apply(%Entry{} = entry, subject_id, prepared, opts) do
    subject = endpoint(subject_id)
    base = base_key(entry)
    actor_id = import_actor_id(entry)

    outcomes =
      entry.relationships
      |> Enum.with_index()
      |> Enum.group_by(fn {relationship, _index} -> relationship.role end)
      |> Enum.flat_map(fn {_role, group} ->
        group
        |> Enum.with_index()
        |> Enum.map(fn {{relationship, position}, n} ->
          key = origin_key(relationship.role, base, n)
          outcome = resolve_target(entry, relationship, subject, prepared)
          {position, record(entry, relationship, subject_id, key, actor_id, outcome, opts)}
        end)
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    withdraw_removed(entry, base, keys_named(entry, base))

    outcomes
  end

  defp base_key(%Entry{stable_identifier: stable}),
    do: "#{stable.namespace}:#{stable.external_id}"

  @doc "The origin key of the `n`th (zero-based) relationship of one role."
  def origin_key(role, base, 0), do: "#{role}:#{base}"
  def origin_key(role, base, n), do: "#{role}:#{base}:#{n + 1}"

  defp keys_named(entry, base) do
    entry.relationships
    |> Enum.group_by(& &1.role)
    |> Enum.flat_map(fn {role, group} ->
      group |> Enum.with_index() |> Enum.map(fn {_r, n} -> origin_key(role, base, n) end)
    end)
    |> MapSet.new()
  end

  defp endpoint(object_id) do
    Repo.one(
      from o in Object,
        left_join: e in Entity,
        on: e.object_id == o.id,
        left_join: c in ContentItem,
        on: c.object_id == o.id,
        where: o.id == ^object_id,
        select: %{
          id: o.id,
          kind: o.kind,
          lifecycle_state: o.lifecycle_state,
          subkind: fragment("coalesce(?::text, ?::text)", e.entity_kind, c.content_kind)
        }
    )
  end

  # ── targets ──────────────────────────────────────────────────────────────

  defp resolve_target(_entry, %{role: role} = relationship, subject, prepared) do
    target = describe_target(relationship)

    case Claims.predicate(role) do
      nil ->
        unresolved(target, :unknown_predicate)

      predicate ->
        located = relationship |> locate(prepared) |> check_endpoint(predicate, subject)

        # The QID a crosswalk found outranks the target's own (an `olid` key
        # has none); the target description fills whatever is left.
        target
        |> Map.take([:target, :qid])
        |> Map.merge(located, fn
          :qid, own, nil -> own
          _key, _own, found -> found
        end)
        |> Map.put(:predicate, predicate)
        |> case_for_refused_endpoint()
    end
  end

  defp describe_target(%{target_object_id: id}) when is_integer(id),
    do: %{target: %{"object_id" => id}, qid: nil}

  defp describe_target(%{target_identifiers: identifiers}) do
    first = hd(identifiers)

    qid =
      Enum.find_value(identifiers, fn
        %{namespace: "wikidata", external_id: qid} -> qid
        _ -> nil
      end)

    %{target: %{"namespace" => first.namespace, "external_id" => first.external_id}, qid: qid}
  end

  # Where the target is, without writing anything yet: an existing object, a
  # person to mint from prepared attrs, or the reason there is neither.
  defp locate(%{target_object_id: id}, _prepared) when is_integer(id) do
    canonical = Registry.canonical_id(id)

    case endpoint(canonical) do
      %{kind: :entity, lifecycle_state: :active} = target ->
        %{state: :matched, object_id: canonical, endpoint: target}

      _ ->
        %{state: :unresolved, reason: :target_not_an_active_entity}
    end
  end

  defp locate(%{target_identifiers: identifiers}, prepared) do
    keys = Enum.map(identifiers, &{&1.namespace, &1.external_id})
    matches = held(keys)

    case matches |> Map.values() |> Enum.map(&Registry.canonical_id/1) |> Enum.uniq() do
      [object_id] ->
        matched(object_id, identifiers, matches)

      [_ | _] ->
        %{state: :unresolved, reason: :identifiers_resolve_to_different_objects}

      [] ->
        case qid_for(identifiers, prepared) do
          {:ok, qid} ->
            case held([{"wikidata", qid}]) do
              %{{"wikidata", ^qid} => object_id} ->
                object_id |> Registry.canonical_id() |> matched(identifiers, matches, qid)

              _ ->
                mintable(qid, identifiers, prepared)
            end

          {:transient, reason} ->
            %{state: :deferred, reason: reason}

          {:no_qid, reason} ->
            %{state: :unresolved, reason: reason}
        end
    end
  end

  defp matched(object_id, identifiers, matches, qid \\ nil) do
    case endpoint(object_id) do
      %{kind: :entity} = target ->
        %{
          state: :matched,
          object_id: object_id,
          endpoint: target,
          qid: qid,
          cache: uncached(identifiers, matches)
        }

      _ ->
        %{state: :unresolved, reason: :target_not_an_entity}
    end
  end

  # Only Open Library keys are cached on a person (#164 C6): they are the one
  # namespace this module had to crosswalk, and the cache is what spares the
  # next run the search. A provider's other identifiers are its own business.
  defp uncached(identifiers, matches) do
    for %{namespace: "olid"} = identifier <- identifiers,
        not Map.has_key?(matches, {identifier.namespace, identifier.external_id}),
        do: identifier
  end

  defp qid_for(identifiers, prepared) do
    direct =
      Enum.find_value(identifiers, fn
        %{namespace: "wikidata", external_id: qid} -> qid
        _ -> nil
      end)

    olid = Enum.find(identifiers, &(&1.namespace == "olid"))

    cond do
      direct ->
        {:ok, direct}

      olid ->
        case Map.get(prepared, {"olid", olid.external_id}) do
          nil -> {:transient, :not_prepared}
          {:ok, qid} -> {:ok, qid}
          {:transient, reason} -> {:transient, reason}
          # An author key Wikidata has no item for is not a QID nobody can
          # resolve: it is a provider with no creator identifier, which keeps
          # its text line and opens nothing (#164 Design 4).
          {:permanent, reason} -> {:no_qid, reason}
        end

      true ->
        {:no_qid, :no_supported_namespace}
    end
  end

  defp mintable(qid, identifiers, prepared) do
    case Map.get(prepared, qid) do
      {:ok, attrs} ->
        %{
          state: :mint,
          qid: qid,
          attrs: attrs,
          endpoint: %{kind: :entity, subkind: to_string(attrs.kind)},
          cache: Enum.filter(identifiers, &(&1.namespace == "olid"))
        }

      nil ->
        %{state: :deferred, qid: qid, reason: :not_prepared}

      {:transient, reason} ->
        %{state: :deferred, qid: qid, reason: reason}

      {:permanent, reason} ->
        %{state: :unresolved, qid: qid, reason: reason, open_case: true}
    end
  end

  # A held target the predicate's endpoint rules refuse — typically a creator
  # QID the registry holds as an untyped `concept` (#165) — is reported and,
  # when its QID is known, opens the same `unresolved_creator` case a missing
  # item does, so the operator can count it (#164 audit residual 5). The card
  # line stays text either way.
  defp check_endpoint(%{endpoint: target} = located, predicate, subject) do
    if endpoint_allowed?(predicate.id, subject, target),
      do: located,
      else: %{
        state: :unresolved,
        reason: :endpoint_not_allowed,
        qid: located[:qid],
        object_id: located[:object_id]
      }
  end

  defp check_endpoint(located, _predicate, _subject), do: located

  # The QID is known only after the target's own description is merged in
  # (a held target is located by its identifiers, not by a prepared QID), so
  # the case is decided here, last.
  defp case_for_refused_endpoint(
         %{state: :unresolved, reason: :endpoint_not_allowed, qid: qid} = m
       )
       when is_binary(qid),
       do: Map.put(m, :open_case, true)

  defp case_for_refused_endpoint(m), do: m

  defp endpoint_allowed?(predicate_id, subject, target) do
    none = PredicateEndpointRule.none()

    Repo.exists?(
      from r in PredicateEndpointRule,
        where:
          r.predicate_id == ^predicate_id and r.subject_kind == ^to_string(subject.kind) and
            r.subject_subkind == ^(subject.subkind || none) and
            r.object_kind == ^to_string(target.kind) and
            r.object_subkind == ^(target.subkind || none)
    )
  end

  defp unresolved(target, reason), do: Map.merge(target, %{state: :unresolved, reason: reason})

  # ── writes ───────────────────────────────────────────────────────────────

  defp record(entry, relationship, subject_id, key, actor_id, located, opts) do
    located =
      case located do
        %{state: :mint} = mint -> mint!(entry, mint)
        other -> other
      end

    located = maybe_open_case(entry, relationship, located)

    case located do
      %{state: state, object_id: object_id} = resolved when state in [:matched, :minted] ->
        cache!(object_id, resolved[:cache] || [], entry)

        entry
        |> write(relationship, subject_id, object_id, key, actor_id, resolved, opts)
        |> outcome(relationship, resolved)

      other ->
        outcome(other, relationship, other)
    end
  end

  defp mint!(entry, %{qid: qid, attrs: attrs} = mint) do
    wikidata = Repo.get_by!(Source, slug: "wikidata")

    {:ok, record} =
      Sources.upsert_record(wikidata, %{
        external_id: qid,
        url: "https://www.wikidata.org/wiki/#{qid}",
        raw: attrs.payload
      })

    {:ok, entity} =
      Registry.mint_creator(
        Map.merge(attrs, %{
          source_record_revision_id: record.current_revision.id,
          minted_by: entry.source_slug
        })
      )

    now = DateTime.utc_now()

    %MaterializedOutput{}
    |> MaterializedOutput.changeset(%{
      source_record_id: record.id,
      output_role: "entity",
      output_key: qid,
      output_object_id: entity.object_id,
      retired_at: nil,
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert!(
      on_conflict: {:replace, [:output_object_id, :retired_at, :updated_at]},
      conflict_target: [:source_record_id, :output_role, :output_key]
    )

    mint
    |> Map.drop([:attrs])
    |> Map.merge(%{state: :minted, object_id: entity.object_id, label: entity.preferred_label})
  end

  defp cache!(_object_id, [], _entry), do: :ok

  defp cache!(object_id, identifiers, entry) do
    Enum.each(identifiers, fn identifier ->
      if is_nil(Registry.by_external_id(identifier.namespace, identifier.external_id)) do
        {:ok, _} =
          Registry.add_external_id(object_id, identifier.namespace, identifier.external_id, %{
            metadata: %{
              "asserted_by" => entry.source_slug,
              "identity_evidence" => "wikidata_crosswalk_P648"
            }
          })
      end
    end)
  end

  defp maybe_open_case(entry, relationship, %{open_case: true, qid: qid} = located) do
    now = DateTime.utc_now()

    Repo.insert_all(
      ReconciliationCase,
      [
        %{
          source_id: entry.source_id,
          source_record_id: entry.source_record_id,
          kind: @case_kind,
          payload: %{
            "qid" => qid,
            "reason" => to_string(located.reason),
            "role" => relationship.role,
            "subject" => base_key(entry),
            "provider_creator" =>
              entry.metadata["author_display_name"] || entry.metadata["artist_display_name"]
          },
          status: :open,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target:
        {:unsafe_fragment, "(source_id, kind, (payload->>'qid')) WHERE status = 'open'"}
    )

    Map.delete(located, :open_case)
  end

  defp maybe_open_case(_entry, _relationship, located), do: located

  # The table in #164 C3, one row per branch.
  defp write(entry, relationship, subject_id, object_id, key, actor_id, resolved, opts) do
    confidence = confidence(relationship.certainty)
    metadata = assertion_metadata(entry, relationship, opts[:adapter_version])

    case existing(entry.source_id, key) do
      nil ->
        {:ok, _assertion} =
          Claims.assert(subject_id, relationship.role, object_id, %{
            source_id: entry.source_id,
            origin_key: key,
            origin_actor_id: actor_id,
            method: @method,
            confidence: confidence,
            metadata: metadata
          })

        :written

      {assertion, current} ->
        cond do
          protected?(current) ->
            {:overridden, current}

          current.lifecycle_state in [:withdrawn, :rejected] and current.rationale != @removed ->
            # A human withdrawal stays withdrawn; the provider's opinion is
            # reported, not applied.
            {:overridden, current}

          current.lifecycle_state == :withdrawn ->
            revise!(assertion.id, object_id, confidence, metadata, lifecycle_state: :active)
            :reinstated

          current.object_object_id == object_id and current.confidence == confidence and
            same_credit?(current.metadata, metadata) and current.method == @method ->
            :unchanged

          true ->
            revise!(assertion.id, object_id, confidence, metadata, [])
            :revised
        end
    end
    |> then(&{&1, resolved})
  end

  defp revise!(assertion_id, object_id, confidence, metadata, extra) do
    {:ok, _revision} =
      Claims.revise(
        assertion_id,
        Map.merge(
          %{
            object_object_id: object_id,
            confidence: confidence,
            metadata: metadata,
            method: @method,
            rationale: nil
          },
          Map.new(extra)
        )
      )
  end

  # The provider's adapter version is recorded on a credit but does not make
  # it a different credit: bumping the version on a refresh that names the same
  # person the same way writes nothing, rather than a revision per held result
  # (#164 audit residual 2). The version on the revision is then the one that
  # first wrote or last changed it, which is what a history should say.
  defp same_credit?(current, proposed) do
    Map.delete(current || %{}, "adapter_version") == Map.delete(proposed, "adapter_version")
  end

  defp assertion_metadata(entry, relationship, adapter_version) do
    %{
      "provider" => entry.source_slug,
      "adapter_version" => adapter_version,
      "certainty" => to_string(relationship.certainty),
      "provider_identifier" => provider_identifier(relationship)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp provider_identifier(%{target_object_id: id}) when is_integer(id), do: "object:#{id}"

  defp provider_identifier(%{target_identifiers: [identifier | _]}),
    do: "#{identifier.namespace}:#{identifier.external_id}"

  defp existing(source_id, key) do
    Repo.one(
      from a in Assertion,
        join: r in AssertionRevision,
        on: r.assertion_id == a.id and r.is_current,
        where: a.source_id == ^source_id and a.origin_key == ^key,
        select: {a, r}
    )
  end

  @doc """
  Whether a current revision is someone else's to change.

  A revision is the provider's only while its method is still
  `provider_relationship`, nobody has reviewed it, and no verifier has written
  into it. Anything else — a curator's correction, build 5's verifier, an
  accept or a reject — outranks a provider refresh (#164 C3).
  """
  def protected?(%AssertionRevision{} = revision) do
    revision.method != @method or Map.has_key?(revision.metadata || %{}, "verifier") or
      Repo.exists?(from r in AssertionReview, where: r.assertion_revision_id == ^revision.id)
  end

  defp withdraw_removed(entry, base, named) do
    pattern = ~r/\A[a-z0-9_]+:#{Regex.escape(base)}(?::\d+)?\z/

    Repo.all(
      from a in Assertion,
        join: r in AssertionRevision,
        on: r.assertion_id == a.id and r.is_current,
        where:
          a.source_id == ^entry.source_id and r.lifecycle_state == :active and
            (like(a.origin_key, ^"%:#{base}") or like(a.origin_key, ^"%:#{base}:%")),
        select: {a, r}
    )
    |> Enum.filter(fn {assertion, _} ->
      Regex.match?(pattern, assertion.origin_key) and
        not MapSet.member?(named, assertion.origin_key)
    end)
    |> Enum.reject(fn {_assertion, current} -> protected?(current) end)
    |> Enum.each(fn {assertion, _} ->
      {:ok, _} = Claims.withdraw(assertion.id, reason: @removed)
    end)
  end

  defp outcome({write, resolved}, relationship, _located) do
    {state, object_id} =
      case write do
        {:overridden, current} -> {:overridden, current.object_object_id}
        _ -> {resolved.state, resolved.object_id}
      end

    %{
      role: relationship.role,
      target: resolved[:target],
      qid: resolved[:qid],
      state: state,
      object_id: object_id,
      label: resolved[:label] || label(object_id),
      reason: nil,
      write: if(is_tuple(write), do: :none, else: write)
    }
  end

  defp outcome(other, relationship, _located) do
    reason = other[:reason]

    %{
      role: relationship.role,
      target: other[:target],
      qid: other[:qid],
      state: other.state,
      object_id: nil,
      label: nil,
      reason: reason && to_string(reason),
      write: :none
    }
  end

  defp label(nil), do: nil

  defp label(object_id),
    do: Repo.one(from e in Entity, where: e.object_id == ^object_id, select: e.preferred_label)

  # One `import` actor per provider source, found by its source id in the
  # metadata and created on first use under an advisory lock, so two runs of a
  # new provider do not make two.
  defp import_actor_id(%Entry{source_id: nil}), do: nil

  defp import_actor_id(%Entry{source_id: source_id, source_slug: slug}) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "creator-identity-actor:#{source_id}"
    ])

    existing =
      Repo.one(
        from a in Actor,
          where:
            a.actor_kind == :import and
              fragment("?->>'creator_identity_source_id'", a.metadata) == ^to_string(source_id),
          select: a.id,
          limit: 1
      )

    existing ||
      %Actor{}
      |> Actor.changeset(%{
        actor_kind: :import,
        label: "#{slug} (provider relationships)",
        metadata: %{
          "process" => "creator_identity",
          "creator_identity_source_id" => to_string(source_id)
        }
      })
      |> Repo.insert!()
      |> Map.fetch!(:id)
  end
end
