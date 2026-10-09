defmodule DevilsDictionary.Routing.ReviewRule do
  @moduledoc """
  The owner's standing review rule (#237 Part A′): one file,
  `priv/routing/review-rule.json`, signed once by the owner's reviewer
  account, that decides every record of a routing population no human has
  decided — so no human reviews rows again, and none is reviewed for the
  owner by a session either.

  ## The file

  `format` (`dd.review-rule/1`), `implementation`, `name`, `issue`,
  `statement`, the `clauses` and the `signature`. The clauses are the
  owner-readable statement of what the rule does; this module implements
  them by `id`, and refuses a file whose clauses are not exactly these, in
  this order, with these actions:

  | clause | action |
  |---|---|
  | `standing_decision` | keep a human's decision: an allocated address, an override, a deferral, a retired, merged or split page, a tombstone |
  | `excluded_source_page` | defer |
  | `identity_lifecycle_review` | defer |
  | `classification_review` | defer anything not `mapped` |
  | `duplicate_identity_review` | defer |
  | `uncontested_mapping` | confirm a mapped record at its uncontested, readable candidate path |
  | `qualified_collision` | confirm a whole collision group at generated qualifiers |
  | `unqualified_collision` | defer the whole group otherwise |
  | `publish_confirmed` | publish a confirmed page that passes the eight gates (Stage 5) |
  | `index_lexical` | list the lexical pages the launch manifest may index (Stage 5, D1) |

  The text is the floor of what the rule does, and the code is stricter
  wherever the two could be read apart: a member a human deferred or held
  for review blocks its whole group, and a population record held for
  classification review is deferred even when its decision is now
  `mapped`.

  `implementation` names the version of `decide/2` the clauses are signed
  for, and `@implementation` here must equal it. A change in what the rule
  does bumps both, so the old file is refused and the owner signs again.

  The rule's digest, `sha256`, is the SHA-256 of its canonical content
  without the signature (keys sorted, no whitespace), so it names the
  clauses and the implementation the owner signed, whatever the file's
  formatting. It is in the run key of every backfill run the rule decides
  and on that run's row (`routing_backfill_runs.rule_sha256`), on every
  override the rule writes (`rule_ids`: `review_rule:<sha256>`), and on
  every publication receipt made under it.

  ## The signature

  `sign/3` writes it in two places at once: a row in
  `review_rule_signatures` (the digest signed, the signer's user id, the
  time, the method and the attestation; append-only, and only for an
  account holding the reviewer role) and the same facts into the file. It
  checks the account's password first
  (`Accounts.get_user_by_email_and_password/2`) and the reviewer role, so
  the signing command needs the account's holder at the keyboard. `load/1`
  refuses a rule that is not signed, whose content changed after it was
  signed, whose signer is not (or is no longer) a reviewer account, or
  whose signature has no matching row on this installation. So editing the
  file alone cannot make a rule usable, and forging a signature needs write
  access to the repository and to that table. It is an attestation, not
  cryptography: what it records is that the signing act happened here.

  ## Deciding

  `decide/2` is a pure function of the records' states (see `t:state/0`)
  and the addresses the ledger holds. It decides every record at once, so a
  collision group is decided together and the order records arrive in
  decides nothing.
  """

  import Ecto.Query

  alias DevilsDictionary.{Accounts, Repo}
  alias DevilsDictionary.Accounts.User

  alias DevilsDictionary.Routing.{
    AuditSnapshot,
    BackfillItem,
    Policy,
    Qualifier,
    ReviewRuleSignature
  }

  @format "dd.review-rule/1"
  @implementation 1
  @keys ~w(format implementation name issue statement clauses signature)

  @clauses [
    {"standing_decision", "keep"},
    {"excluded_source_page", "defer"},
    {"identity_lifecycle_review", "defer"},
    {"classification_review", "defer"},
    {"duplicate_identity_review", "defer"},
    {"uncontested_mapping", "confirm"},
    {"qualified_collision", "confirm"},
    {"unqualified_collision", "defer"},
    {"publish_confirmed", "publish"},
    {"index_lexical", "list"}
  ]

  @signature_keys ~w(signer user_id rule_sha256 signed_at method attestation)

  @doc "The committed rule: `priv/routing/review-rule.json`."
  def path, do: Path.join(Policy.root(), "review-rule.json")

  @doc "The clauses this code implements, as `{id, action}`, in order."
  def clauses, do: @clauses

  @doc "The version of `decide/2` a rule file must name to be read by this code."
  def implementation, do: @implementation

  # ── reading ──────────────────────────────────────────────────────────────

  @doc """
  Reads a rule file and checks its shape and clauses; no database. Returns
  `{:ok, rule}` with `:sha256` (the content digest), `:doc` and
  `:signature` (nil when unsigned), or `{:error, message}`.
  """
  def read(path) do
    with {:ok, bytes} <- file(path),
         {:ok, doc} <- json(path, bytes),
         :ok <- shape(path, doc) do
      {:ok,
       %{
         path: path,
         doc: doc,
         sha256: digest(doc),
         signature: doc["signature"],
         file_sha256: AuditSnapshot.digest(bytes)
       }}
    end
  end

  defp file(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  # Decoded twice: once keeping every pair in order, to refuse a key given
  # twice (the digest would cover its last value while a reader may see the
  # first), and once as the map the code reads.
  defp json(path, bytes) do
    case Jason.decode(bytes, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = ordered} ->
        with :ok <- unique_keys(path, ordered, []), do: {:ok, Jason.decode!(bytes)}

      {:ok, _other} ->
        {:error, "rule #{path}: not a JSON object"}

      {:error, _reason} ->
        {:error, "rule #{path}: not JSON"}
    end
  end

  defp unique_keys(path, %Jason.OrderedObject{values: values}, trail) do
    keys = Enum.map(values, &elem(&1, 0))

    case keys -- Enum.uniq(keys) do
      [] ->
        Enum.reduce_while(values, :ok, fn {key, value}, :ok ->
          case unique_keys(path, value, [key | trail]) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      [key | _] ->
        {:error, "rule #{path}: the key #{inspect(key)} is given twice#{under(trail)}"}
    end
  end

  defp unique_keys(path, list, trail) when is_list(list) do
    Enum.reduce_while(list, :ok, fn value, :ok ->
      case unique_keys(path, value, trail) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp unique_keys(_path, _scalar, _trail), do: :ok

  defp under([]), do: ""
  defp under(trail), do: " under " <> Enum.join(Enum.reverse(trail), ".")

  defp shape(path, doc) do
    clauses = doc["clauses"]

    cond do
      doc["format"] != @format ->
        {:error, "rule #{path}: format #{inspect(doc["format"])}, not #{@format}"}

      (extra = Map.keys(doc) -- @keys) != [] ->
        {:error, "rule #{path}: unknown keys #{Enum.join(extra, ", ")}"}

      doc["implementation"] != @implementation ->
        {:error,
         "rule #{path}: implementation #{inspect(doc["implementation"])}, but this code is " <>
           "implementation #{@implementation} of #{@format}: a rule is signed for one version of " <>
           "what its clauses do, and a changed implementation needs a new signature"}

      not Enum.all?(~w(name statement), &text?(doc[&1])) ->
        {:error, "rule #{path}: a rule has a name and a statement"}

      not (is_list(clauses) and Enum.all?(clauses, &is_map/1)) ->
        {:error, "rule #{path}: clauses is a list of objects"}

      Enum.map(clauses, &{&1["id"], &1["action"]}) != @clauses ->
        {:error,
         "rule #{path}: the clauses must be exactly " <>
           Enum.map_join(@clauses, ", ", fn {id, action} -> "#{id} (#{action})" end) <>
           ", in that order: this code implements those and no others"}

      not Enum.all?(clauses, &(map_size(&1) == 3 and text?(&1["text"]))) ->
        {:error, "rule #{path}: every clause has an id, an action and its text, and nothing else"}

      not (is_nil(doc["signature"]) or is_map(doc["signature"])) ->
        {:error, "rule #{path}: a signature is an object, or null before signing"}

      true ->
        :ok
    end
  end

  defp text?(value), do: is_binary(value) and String.trim(value) != "" and String.valid?(value)

  @doc "The rule's digest: its canonical content without the signature."
  def digest(doc) do
    doc
    |> Map.delete("signature")
    |> canonical()
    |> Jason.encode!()
    |> AuditSnapshot.digest()
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  @doc """
  Reads a rule and requires its signature: it covers this content, its
  signer is an account holding the reviewer role, by the email and the id
  it names, and this installation recorded that signing
  (`review_rule_signatures`). Returns the rule with `:signer` (the `User`).
  """
  def load(path) do
    with {:ok, rule} <- read(path),
         {:ok, signature} <- signed(rule),
         {:ok, user} <- signer(path, signature),
         :ok <- attested(path, rule.sha256, signature, user) do
      {:ok, Map.put(rule, :signer, user)}
    end
  end

  defp signed(%{signature: nil, path: path}),
    do: {:error, "rule #{path} is not signed: only its signer's signature makes it a decision"}

  defp signed(%{signature: signature, sha256: sha256, path: path}) do
    cond do
      Map.keys(signature) |> Enum.sort() != Enum.sort(@signature_keys) ->
        {:error, "rule #{path}: a signature names exactly #{Enum.join(@signature_keys, ", ")}"}

      signature["rule_sha256"] != sha256 ->
        {:error,
         "rule #{path} was signed as #{inspect(signature["rule_sha256"])} but its content is #{sha256}: " <>
           "it changed after it was signed, and must be signed again"}

      not (is_binary(signature["signer"]) and is_integer(signature["user_id"])) ->
        {:error, "rule #{path}: the signature names its signer's email and user id"}

      not match?({:ok, _, _}, DateTime.from_iso8601(signature["signed_at"] || "")) ->
        {:error, "rule #{path}: the signature's signed_at is not a time"}

      true ->
        {:ok, signature}
    end
  end

  defp signer(path, %{"signer" => email, "user_id" => id}) do
    case Repo.get_by(User, email: email) do
      %User{id: ^id, reviewer: true} = user ->
        {:ok, user}

      %User{id: ^id} ->
        {:error, "rule #{path}: its signer #{email} does not hold the reviewer role"}

      %User{} ->
        {:error, "rule #{path}: #{email} is not the account the signature names (user #{id})"}

      nil ->
        {:error, "rule #{path}: no account #{email} signed it on this installation"}
    end
  end

  # The signing this installation recorded: the same digest, by the same
  # account, at the time the file says. A signature typed into the file has
  # no row, and a row written for another time or account does not match.
  defp attested(path, sha256, signature, user) do
    {:ok, signed_at, _offset} = DateTime.from_iso8601(signature["signed_at"])

    case Repo.get_by(ReviewRuleSignature, rule_sha256: sha256) do
      %ReviewRuleSignature{user_id: user_id, signed_at: recorded} when user_id == user.id ->
        if DateTime.compare(
             DateTime.truncate(recorded, :second),
             DateTime.truncate(signed_at, :second)
           ) ==
             :eq,
           do: :ok,
           else:
             {:error,
              "rule #{path}: its signature says #{signature["signed_at"]}, but this installation " <>
                "recorded #{user.email} signing #{sha256} at #{DateTime.to_iso8601(recorded)}"}

      %ReviewRuleSignature{user_id: user_id} ->
        {:error,
         "rule #{path}: this installation recorded user #{user_id} signing #{sha256}, not #{user.email}"}

      nil ->
        {:error,
         "rule #{path}: no signing of #{sha256} is recorded on this installation " <>
           "(review_rule_signatures): a signature written into the file is not a signing"}
    end
  end

  # ── signing ──────────────────────────────────────────────────────────────

  @doc """
  Signs the rule at `path` as the reviewer account `email`, after checking
  `password` against it: the owner's one act (#237). Refuses a rule that is
  already signed in the file or recorded on this installation, an unknown
  account, a wrong password and an account without the reviewer role.
  Records the signing in `review_rule_signatures` and writes the same
  signature into the file, in one transaction, and returns `{:ok, rule}`
  as `load/1` returns it; the content, and so the digest, is unchanged.
  """
  def sign(path, email, password) do
    with {:ok, rule} <- read(path),
         :ok <- unsigned(rule),
         :ok <- unrecorded(rule),
         {:ok, user} <- account(email, password) do
      signed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      method =
        "mix dd.routing.rule --sign: the account's password checked on #{database()}, " <>
          "the signing recorded in review_rule_signatures"

      attestation =
        "The holder of reviewer account #{user.email} signs this rule as the owner's standing " <>
          "decision for every record and page it decides (#237)."

      signature =
        Jason.OrderedObject.new([
          {"signer", user.email},
          {"user_id", user.id},
          {"rule_sha256", rule.sha256},
          {"signed_at", DateTime.to_iso8601(signed_at)},
          {"method", method},
          {"attestation", attestation}
        ])

      {:ok, ordered} = Jason.decode(File.read!(path), objects: :ordered_objects)
      bytes = [Jason.encode!(put_signature(ordered, signature), pretty: true), "\n"]

      # The row and the file together: a file write that fails rolls the
      # row back, and a row the database refuses leaves the file as it was.
      {:ok, _signature} =
        Repo.transaction(fn ->
          row =
            Repo.insert!(%ReviewRuleSignature{
              rule_sha256: rule.sha256,
              user_id: user.id,
              signed_at: signed_at,
              method: method,
              attestation: attestation
            })

          File.write!(path, bytes)
          row
        end)

      load(path)
    end
  end

  defp unsigned(%{signature: nil}), do: :ok

  defp unsigned(%{signature: signature, path: path}),
    do:
      {:error, "rule #{path} is already signed by #{signature["signer"]}; a rule is signed once"}

  defp unrecorded(%{sha256: sha256, path: path}) do
    case Repo.get_by(ReviewRuleSignature, rule_sha256: sha256) do
      nil ->
        :ok

      %ReviewRuleSignature{user_id: user_id, signed_at: at} ->
        {:error,
         "rule #{path}: #{sha256} was already signed on this installation by user #{user_id} " <>
           "at #{DateTime.to_iso8601(at)}; a rule is signed once"}
    end
  end

  defp account(email, password) when is_binary(email) and is_binary(password) do
    case Accounts.get_user_by_email_and_password(email, password) do
      %User{reviewer: true} = user -> {:ok, user}
      %User{} -> {:error, "#{email} does not hold the reviewer role"}
      nil -> {:error, "no reviewer account #{email} with that password"}
    end
  end

  defp account(_email, _password), do: {:error, "name the reviewer account and its password"}

  defp put_signature(%Jason.OrderedObject{values: values}, signature),
    do: %Jason.OrderedObject{
      values: List.keystore(values, "signature", 0, {"signature", signature})
    }

  defp database do
    config = Repo.config()
    "#{config[:database]} on #{config[:hostname] || "localhost"}:#{config[:port] || 5432}"
  end

  # ── deciding ─────────────────────────────────────────────────────────────

  @typedoc """
  One record as the rule sees it:

    * `object_id`, `label`, `role` (`:subject` or `:edition`);
    * `population` — the population's record (`disposition`,
      `address_status`, `candidate_path`, `proposed_path`, `family`,
      `status`) and `group`, the collision group's path it is in, or nil;
    * `entity` — the export's record, for the qualifier (`description`,
      `work_kind`);
    * `decision` — the current classification decision: `status`, `family`
      (strings), `origin`, `fingerprint`, and `rule_sha256` when a rule wrote
      it (`human?` is an override no rule wrote);
    * `canonical` — the canonical address its page holds, or nil;
    * `lifecycle` — its page's lifecycle (`"active"`, `"merged"`, `"split"`,
      `"retired"`), or nil without a page;
    * `earlier_review` — the latest human review of it in an earlier run
      (`"action"`, `"reason"`), or nil;
    * `stale` — nil, or why the evidence is no longer the export's.
  """
  @type state :: map()

  @doc """
  Decides every record in `states` (see `t:state/0`); `held` maps each
  address the ledger holds that a record might take to `%{holder:, kind:}`:
  the object whose page holds it and the path's kind (`:canonical`,
  `:alias` or `:tombstone`), or just the holder for a canonical. Returns
  `%{object_id => decision}`, each with `:action` (`:confirm`, `:defer`,
  `:not_addressed`, `:stale`), `:clause`, `:reason`, and for a confirmation
  `:family`, `:path`, `:fingerprint` and `:standing` (an address already
  held, which nothing writes).
  """
  def decide(states, held \\ %{}) do
    by_id = Map.new(states, &{&1.object_id, &1})
    candidates = MapSet.new(states, &nfc(&1.population["candidate_path"]))

    groups =
      states
      |> Enum.map(& &1.population["group"])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new(&nfc/1)

    proposals =
      for s <- states, p = s.population["proposed_path"], is_binary(p), into: %{} do
        {nfc(p), s.object_id}
      end

    held = Map.new(held, fn {path, entry} -> {nfc(path), held_entry(entry)} end)
    ctx = %{held: held, candidates: candidates, proposals: proposals, groups: groups}
    individual = Map.new(states, &{&1.object_id, individual(&1, ctx)})

    states
    |> Enum.filter(& &1.population["group"])
    |> Enum.group_by(& &1.population["group"], & &1.object_id)
    |> Enum.sort()
    |> Enum.reduce(individual, fn {group, ids}, acc ->
      group(group, Enum.sort(ids), by_id, acc, ctx)
    end)
    |> one_record_per_path(by_id)
  end

  defp held_entry(%{holder: _holder, kind: _kind} = entry), do: entry
  defp held_entry(holder), do: %{holder: holder, kind: :canonical}

  defp held(_ctx, nil), do: %{holder: nil, kind: nil}
  defp held(ctx, path), do: Map.get(ctx.held, nfc(path), %{holder: nil, kind: nil})

  defp individual(s, ctx) do
    d = s.decision
    population = s.population

    cond do
      s.stale ->
        %{action: :stale, clause: nil, reason: s.stale}

      population_kind(population["disposition"]) == :not_addressed ->
        not_addressed(population["disposition"])

      s[:lifecycle] not in [nil, "active", :active] ->
        defer(
          "standing_decision",
          "its page is #{s.lifecycle}: a human decided that, and the decision stands"
        )

      d && d.status == "mapped" && s.canonical && in_family?(s.canonical, d.family, s.role) ->
        confirm("standing_decision", d.family, s.canonical, d,
          reason: "its address is already allocated, under a #{decided_by(d)}",
          standing: true
        )

      d && human?(d) && d.status != "mapped" ->
        defer("standing_decision", "a reviewer's #{d.status} decision stands")

      s.earlier_review && s.earlier_review["action"] == "defer" ->
        defer("standing_decision", "a reviewer deferred it: #{s.earlier_review["reason"]}")

      is_nil(d) ->
        defer("classification_review", "no current decision")

      d.status == "identity_review" ->
        defer("identity_lifecycle_review", "identity review: #{Enum.join(d.reasons || [], ", ")}")

      d.status == "excluded_source_page" ->
        defer("excluded_source_page", "a source page, never a subject")

      d.status != "mapped" ->
        defer("classification_review", "#{d.status}: #{Enum.join(d.reasons || [], ", ")}")

      population_kind(population["disposition"]) == :duplicate_identity ->
        defer("duplicate_identity_review", population["disposition"])

      population_kind(population["disposition"]) == :classification_review ->
        defer("classification_review", population["disposition"])

      population["group"] ->
        %{action: :grouped, clause: nil, reason: nil}

      true ->
        uncontested(s, d, ctx)
    end
  end

  defp uncontested(s, d, ctx) do
    path = s.population["candidate_path"]
    expected = AuditSnapshot.candidate_path(%{status: "mapped", family: d.family, label: s.label})
    %{holder: holder, kind: kind} = held(ctx, path)
    proposer = Map.get(ctx.proposals, nfc(path))

    cond do
      s.population["address_status"] != "candidate" or not is_binary(path) ->
        defer("unqualified_collision", "the population proposes no candidate path")

      nfc(path) != nfc(expected) ->
        defer(
          "unqualified_collision",
          "#{path} is not the policy's proposal (#{inspect(expected)}) for #{inspect(s.label)} in #{d.family}"
        )

      s.role == :edition and d.family != "works" ->
        defer("unqualified_collision", "an edition's address is in /works, not /#{d.family}")

      MapSet.member?(ctx.groups, nfc(path)) ->
        defer("unqualified_collision", "#{path} is a collision group's shared path")

      not Qualifier.readable?(s.label) ->
        defer(
          "unqualified_collision",
          "#{path} is spelt from punctuation in #{inspect(s.label)}: not a readable address, " <>
            "and a human may name one"
        )

      kind == :tombstone ->
        defer(
          "standing_decision",
          "#{path} is a tombstone: a human retired the page that held it"
        )

      holder not in [nil, s.object_id] ->
        defer("unqualified_collision", "#{path} is held by object #{holder}'s page")

      proposer not in [nil, s.object_id] ->
        defer("unqualified_collision", "#{path} is object #{proposer}'s proposed qualifier")

      true ->
        confirm("uncontested_mapping", d.family, path, d, reason: "mapped, uncontested")
    end
  end

  # A collision group is decided together. Members a human already decided
  # with an address keep it; every other member must be qualified, or none
  # is. A member deferred for any reason — a review, a human's deferral, a
  # retired page — defers the group whole.
  defp group(group, ids, by_id, acc, ctx) do
    members = Enum.flat_map(ids, &List.wrap(by_id[&1]))
    {fixed, rest} = Enum.split_with(members, &match?(%{standing: true}, acc[&1.object_id]))

    case Enum.reject(rest, &(acc[&1.object_id].action == :grouped)) do
      [] when rest != [] ->
        qualify(group, members, fixed, rest, acc, ctx)

      [] ->
        acc

      blockers ->
        why =
          Enum.map_join(blockers, "; ", fn b ->
            "#{b.object_id} #{acc[b.object_id].clause || acc[b.object_id].action}"
          end)

        defer_grouped(rest, acc, "group #{group} cannot be qualified whole: #{why}")
    end
  end

  defp qualify(group, members, fixed, rest, acc, ctx) do
    proposals =
      members
      |> Enum.filter(&(&1.population["status"] == "mapped"))
      |> Enum.map(fn m ->
        %{
          object_id: m.object_id,
          label: m.label,
          family: m.population["family"],
          description: m.entity && m.entity["description"],
          work_kind: m.entity && m.entity["work_kind"]
        }
      end)
      |> Qualifier.proposals()

    taken = MapSet.new(fixed, &nfc(acc[&1.object_id].path))
    paths = Enum.map(rest, &nfc(proposals[&1.object_id]))

    problems =
      Enum.flat_map(rest, fn m ->
        path = proposals[m.object_id]
        %{holder: holder, kind: kind} = held(ctx, path)

        cond do
          is_nil(path) ->
            ["#{m.object_id}: the evidence gives no readable qualifier"]

          not String.starts_with?(
            m.population["disposition"] || "",
            "collision review: proposed readable qualifier"
          ) ->
            ["#{m.object_id}: #{m.population["disposition"]}"]

          nfc(path) != nfc(m.population["proposed_path"]) ->
            [
              "#{m.object_id}: generated #{path}, the population proposed #{inspect(m.population["proposed_path"])}"
            ]

          m.decision.family != m.population["family"] ->
            [
              "#{m.object_id}: now mapped to #{m.decision.family}, proposed in #{m.population["family"]}"
            ]

          Enum.count(paths, &(&1 == nfc(path))) > 1 or MapSet.member?(taken, nfc(path)) ->
            ["#{m.object_id}: #{path} is not distinct within the group"]

          MapSet.member?(ctx.candidates, nfc(path)) ->
            ["#{m.object_id}: #{path} is another record's candidate path"]

          kind == :tombstone ->
            ["#{m.object_id}: #{path} is a tombstone, a human retired the page that held it"]

          holder not in [nil, m.object_id] ->
            ["#{m.object_id}: #{path} is held by object #{holder}'s page"]

          true ->
            []
        end
      end)

    if problems == [] do
      Enum.reduce(rest, acc, fn m, acc ->
        Map.put(
          acc,
          m.object_id,
          confirm("qualified_collision", m.decision.family, proposals[m.object_id], m.decision,
            reason: "group #{group}: every member qualified by its evidence"
          )
        )
      end)
    else
      defer_grouped(
        rest,
        acc,
        "group #{group} cannot be qualified whole: " <> Enum.join(problems, "; ")
      )
    end
  end

  defp defer_grouped(rest, acc, reason) do
    Enum.reduce(rest, acc, fn m, acc ->
      if acc[m.object_id].action == :grouped,
        do: Map.put(acc, m.object_id, defer("unqualified_collision", reason)),
        else: acc
    end)
  end

  # Two confirmations of one address would leave its owner to the order of
  # writing: neither goes, nor does anything decided with them — the whole
  # collision group of each.
  defp one_record_per_path(decisions, by_id) do
    twice =
      decisions
      |> Enum.filter(fn {_id, d} -> d.action == :confirm end)
      |> Enum.group_by(fn {_id, d} -> nfc(d.path) end, fn {id, _d} -> id end)
      |> Enum.filter(fn {_path, ids} -> length(ids) > 1 end)

    Enum.reduce(twice, decisions, fn {path, ids}, acc ->
      ids = Enum.sort(ids)

      affected =
        ids
        |> Enum.reject(&acc[&1][:standing])
        |> Enum.flat_map(fn id ->
          case by_id[id].population["group"] do
            nil -> [id]
            group -> for {other, s} <- by_id, s.population["group"] == group, do: other
          end
        end)
        |> Enum.uniq()

      reason =
        "#{path} would be confirmed twice (objects #{Enum.join(ids, ", ")}): " <>
          "neither goes, nor does anything decided with them"

      Enum.reduce(affected, acc, fn id, acc ->
        if acc[id].action == :confirm and not acc[id][:standing],
          do: Map.put(acc, id, defer("unqualified_collision", reason)),
          else: acc
      end)
    end)
  end

  defp confirm(clause, family, path, d, opts) do
    %{
      action: :confirm,
      clause: clause,
      family: family,
      path: path,
      fingerprint: d.fingerprint,
      reason: opts[:reason],
      standing: Keyword.get(opts, :standing, false)
    }
  end

  defp defer(clause, reason), do: %{action: :defer, clause: clause, reason: reason}

  defp not_addressed(disposition) do
    clause =
      cond do
        String.starts_with?(disposition, "excluded") -> "excluded_source_page"
        String.starts_with?(disposition, "deferred: identity") -> "identity_lifecycle_review"
        true -> "classification_review"
      end

    %{action: :not_addressed, clause: clause, reason: disposition}
  end

  defp decided_by(d) do
    cond do
      d[:rule_sha256] -> "standing rule #{String.slice(d.rule_sha256, 0, 12)}…"
      d.origin == "override" -> "reviewer's override"
      true -> "#{d.origin} decision"
    end
  end

  @doc "Whether a decision is an override no rule wrote: a human's own."
  def human?(%{origin: origin} = d),
    do: to_string(origin) == "override" and is_nil(d[:rule_sha256])

  defp in_family?(path, family, role) do
    case String.split(path, "/", parts: 3) do
      ["", namespace, _slug] -> namespace == family and (role != :edition or family == "works")
      _ -> false
    end
  end

  @doc """
  What a population disposition asks for: `:not_addressed` (deferred or
  excluded), `:duplicate_identity`, `:classification_review`, or
  `:heading_for_address`.
  """
  def population_kind(disposition) when is_binary(disposition) do
    cond do
      String.starts_with?(disposition, ["deferred", "excluded"]) -> :not_addressed
      String.starts_with?(disposition, "duplicate-identity review") -> :duplicate_identity
      String.starts_with?(disposition, "classification review") -> :classification_review
      true -> :heading_for_address
    end
  end

  def population_kind(_disposition), do: :not_addressed

  defp nfc(nil), do: nil
  defp nfc(path), do: String.normalize(path, :nfc)

  @doc """
  The latest review of each object a human made in an earlier run: the
  `review` entry of its newest checkpoint row that a review file, not a
  rule, decided.
  """
  def earlier_reviews(object_ids) do
    from(i in BackfillItem,
      where: i.object_id in ^object_ids and not is_nil(i.review),
      where: fragment("NOT (? \\? 'rule_sha256')", i.review),
      order_by: [desc: i.id],
      select: {i.object_id, i.review}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {id, review}, acc -> Map.put_new(acc, id, review) end)
  end
end
