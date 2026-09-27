defmodule DevilsDictionary.Curation.Profiles do
  @moduledoc """
  Curator profile identities, their dossier versions, and admission (#196).

  The five inspired-by identities are seeded as `proposed`, with no version,
  bot actor or subject entity: names, and nothing asserted about the people
  they are named for. A profile is admitted only by a reviewer, from a
  version that cites its sources and deceased-status evidence (C6). Admission
  is what a later panel slice will require of every roster seat. No seat
  exists yet, because no dossier has been reviewed.
  """

  import Ecto.Query

  alias DevilsDictionary.Curation.{Authority, Digest, Profile, ProfileVersion, Transaction}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Actor

  @proposed [
    %{slug: "bierce", subject_label: "Ambrose Bierce"},
    %{slug: "voltaire", subject_label: "Voltaire"},
    %{slug: "vonnegut", subject_label: "Kurt Vonnegut"},
    %{slug: "hitchens", subject_label: "Christopher Hitchens"},
    %{slug: "le-guin", subject_label: "Ursula K. Le Guin"}
  ]

  @doc "The slugs of the five proposed identities, in roster order."
  def proposed_slugs, do: Enum.map(@proposed, & &1.slug)

  @doc """
  Inserts the five proposed identities that are missing and returns all five.
  Idempotent: an existing profile, whatever its state, is left as it is.
  """
  def seed_proposed! do
    now = DateTime.utc_now()

    rows =
      for p <- @proposed do
        %{
          slug: p.slug,
          label: "Inspired by #{p.subject_label}",
          subject_label: p.subject_label,
          state: :proposed,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Profile, rows, on_conflict: :nothing, conflict_target: :slug)

    slugs = proposed_slugs()
    by_slug = Repo.all(from p in Profile, where: p.slug in ^slugs) |> Map.new(&{&1.slug, &1})
    Enum.map(slugs, &Map.fetch!(by_slug, &1))
  end

  @doc """
  Adds a dossier version to a profile, as a human author. A proposed
  profile's pointer follows its newest version. An admitted profile keeps
  its admitted version until it is admitted again.

  `attrs`: `:dossier` (map), `:source_refs` and `:deceased_evidence_refs`
  (lists of references), `:template_version`, `:reason`.
  """
  def add_version(scope, profile_id, attrs) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :author),
           {:ok, profile} <- lock(profile_id),
           {:ok, reason} <- Transaction.required(Map.to_list(attrs), :reason) do
        body = %{
          "dossier" => Map.get(attrs, :dossier, %{}),
          "source_refs" => Map.get(attrs, :source_refs, []),
          "deceased_evidence_refs" => Map.get(attrs, :deceased_evidence_refs, []),
          "template_version" => Map.fetch!(attrs, :template_version)
        }

        hash = Digest.term(body)

        case Repo.get_by(ProfileVersion, profile_id: profile.id, manifest_hash: hash) do
          %ProfileVersion{id: id} ->
            {:error, {:duplicate_version, id}}

          nil ->
            version =
              Repo.insert!(%ProfileVersion{
                profile_id: profile.id,
                version: next_version(profile.id),
                manifest_hash: hash,
                dossier: body["dossier"],
                source_refs: body["source_refs"],
                deceased_evidence_refs: body["deceased_evidence_refs"],
                template_version: body["template_version"],
                created_by_actor_id: actor.id,
                change_reason: reason
              })

            if profile.state == :proposed do
              profile
              |> Ecto.Changeset.change(current_version_id: version.id)
              |> Repo.update!()
            end

            {:ok, version}
        end
      end
    end)
  end

  @doc """
  Admits one version of a profile, as a reviewer, acting through `bot_actor_id`
  (a `bot` actor no other profile uses). The version must cite at least one
  source and at least one piece of deceased-status evidence. Nothing is
  judged here about whether the evidence is true: a reviewer did that, and
  this records who.
  """
  def admit(scope, profile_id, version_id, opts) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :reviewer),
           {:ok, reason} <- Transaction.required(opts, :reason),
           {:ok, profile} <- lock(profile_id),
           {:ok, version} <-
             Transaction.need(
               Repo.get_by(ProfileVersion, id: version_id, profile_id: profile.id),
               :version_not_found
             ),
           :ok <- Transaction.check(cited?(version.source_refs), :sources_missing),
           :ok <-
             Transaction.check(
               cited?(version.deceased_evidence_refs),
               :deceased_evidence_missing
             ),
           {:ok, bot} <- bot(Keyword.get(opts, :bot_actor_id), profile.id) do
        profile
        |> Ecto.Changeset.change(
          state: :admitted,
          current_version_id: version.id,
          bot_actor_id: bot.id,
          admitted_by_actor_id: actor.id,
          admitted_at: DateTime.utc_now(),
          admission_reason: reason
        )
        |> Repo.update()
      end
    end)
  end

  defp cited?(refs), do: is_list(refs) and refs != []

  defp bot(nil, _profile_id), do: {:error, :bot_actor_missing}

  defp bot(id, profile_id) do
    with {:ok, actor} <-
           Transaction.need(
             Repo.get_by(Actor, id: id, actor_kind: :bot),
             :bot_actor_missing
           ),
         :ok <-
           Transaction.check(
             not Repo.exists?(
               from p in Profile, where: p.bot_actor_id == ^id and p.id != ^profile_id
             ),
             :bot_actor_in_use
           ) do
      {:ok, actor}
    end
  end

  defp lock(id) do
    Transaction.need(
      Repo.one(from p in Profile, where: p.id == ^id, lock: "FOR UPDATE"),
      :not_found
    )
  end

  defp next_version(profile_id) do
    (Repo.one(
       from v in ProfileVersion, where: v.profile_id == ^profile_id, select: max(v.version)
     ) ||
       0) + 1
  end
end
