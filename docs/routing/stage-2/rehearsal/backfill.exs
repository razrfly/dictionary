# Stage 2 rehearsal of the routing backfill (#194), on isolated copies only.
#
#   DD_STAGE2_REHEARSAL=1 DD_NO_OBAN=1 DD_DATABASE=devils_dictionary_stage2r_… DD_DATABASE_PORT=5433 \
#     mix run docs/routing/stage-2/rehearsal/backfill.exs COMMAND ARGS
#
# Commands:
#
#   reviewer EMAIL
#       A marked rehearsal account with the reviewer role, on this copy.
#   reviews POPULATION MANIFEST EMAIL OUT
#       **Rehearsal reviews, not approvals.** A rule applied to the
#       population so that allocation can be exercised at corpus scale:
#       confirm each allocation candidate's family; confirm each proposed
#       qualifier as proposed; defer everything else. Each confirmation names
#       the decision fingerprint a run without reviews reported in MANIFEST,
#       as a reviewer's would. The file is marked `"rehearsal": true`, which
#       the backfill refuses anywhere but a rehearsal copy.
#   state RUN_KEY OUT
#       `Routing.Backfill.state/1`: what the run left for each object, by
#       identity, for comparing an interrupted run with an uninterrupted one.
#   ids OUT
#       Every page, path, decision, ledger and checkpoint id, for proving a
#       repeat run wrote nothing.
Code.require_file("guard.exs", __DIR__)

import Ecto.Query

alias DevilsDictionary.Repo
alias DevilsDictionary.Routing.{Backfill, BackfillItem, ClassificationDecision, Page, PublicPath, RouteChange}

{_host, _port, database} = Stage2.Guard.check!()
write = fn path, value -> File.write!(path, Jason.encode_to_iodata!(value, pretty: true)) end

case System.argv() do
  ["reviewer", email] ->
    {:ok, user} = DevilsDictionary.Accounts.register_user(%{email: email})
    user |> Ecto.Changeset.change(reviewer: true) |> Repo.update!()
    IO.puts("rehearsal reviewer #{email} (user #{user.id}) on #{database}")

  ["reviews", population, manifest, email, out] ->
    records = population |> File.read!() |> Jason.decode!() |> Map.fetch!("records")

    fingerprints =
      manifest
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("records")
      |> Map.new(&{&1["object_id"], &1["evidence_fingerprint"]})
    reason = "Stage 2 rehearsal on an isolated copy: a rule, not an approval"

    review = fn r ->
      cond do
        String.starts_with?(r["disposition"], "allocation candidate") ->
          %{
            "action" => "confirm",
            "family" => r["family"],
            "evidence_fingerprint" => fingerprints[r["object_id"]]
          }

        String.starts_with?(r["disposition"], "collision review: proposed") ->
          %{
            "action" => "confirm",
            "family" => r["family"],
            "path" => r["proposed_path"],
            "evidence_fingerprint" => fingerprints[r["object_id"]]
          }

        String.starts_with?(r["disposition"], ["deferred", "excluded"]) ->
          nil

        true ->
          %{"action" => "defer"}
      end
    end

    reviews =
      for r <- records, entry = review.(r), entry != nil do
        Map.merge(entry, %{"object_id" => r["object_id"], "reviewer" => email, "reason" => reason})
      end

    population_sha256 = :crypto.hash(:sha256, File.read!(population)) |> Base.encode16(case: :lower)
    write.(out, %{"rehearsal" => true, "population_sha256" => population_sha256, "reviews" => reviews})
    IO.puts("#{length(reviews)} rehearsal reviews: #{inspect(Enum.frequencies_by(reviews, & &1["action"]))}")

  ["state", run_key, out] ->
    # Tuples as lists and atoms as strings, all the way down, for JSON.
    plain = fn
      plain, value when is_tuple(value) -> value |> Tuple.to_list() |> Enum.map(&plain.(plain, &1))
      plain, value when is_list(value) -> Enum.map(value, &plain.(plain, &1))
      plain, %{} = value -> Map.new(value, fn {k, v} -> {to_string(k), plain.(plain, v)} end)
      _plain, value when is_atom(value) and not is_nil(value) and not is_boolean(value) -> Atom.to_string(value)
      _plain, value -> value
    end

    state = run_key |> Backfill.state() |> then(&plain.(plain, &1))
    write.(out, state)
    IO.puts("state of #{map_size(state)} objects")

  ["ids", out] ->
    ids =
      for {name, schema} <- [
            pages: Page,
            public_paths: PublicPath,
            classification_decisions: ClassificationDecision,
            route_changes: RouteChange,
            routing_backfill_items: BackfillItem
          ],
          into: %{} do
        {name, Repo.all(from r in schema, order_by: r.id, select: r.id)}
      end

    write.(out, ids)
    IO.puts(Enum.map_join(ids, ", ", fn {k, v} -> "#{k} #{length(v)}" end))
end
