defmodule DevilsDictionary.Curation.Standing do
  @moduledoc """
  Whether a composition version still stands: the checks shared by review,
  publication and reading.

  A version was made against one configuration version, one scope and one
  eligibility fingerprint. It stands while all three are still true:

    * `configuration/1`: its configuration is enabled and still on the
      version it was made under (`:configuration_changed`);
    * `scope/2`: its composition's scope is the one it was made for
      (`:scope_changed`);
    * `eligible/2`: its items and its lead rule evaluate `:ok`, to the same
      fingerprint it was made with (`:stale_eligibility`).

  Plus, for publication and reading, `latest_review/1`: the latest human
  decision on it.
  """

  import Ecto.Query

  alias DevilsDictionary.Curation.{
    Composition,
    CompositionReview,
    CompositionVersion,
    Compositions,
    Configurations,
    Eligibility
  }

  alias DevilsDictionary.Repo

  @doc """
  The version's items evaluated against its composition's current members,
  under the configuration version it was made with.
  """
  def evaluate(%CompositionVersion{} = version, %Composition{} = composition) do
    version.id
    |> Compositions.items()
    |> Eligibility.evaluate(
      Compositions.member_ids(composition.id),
      version.scope_signature,
      version.configuration_version_id
    )
  end

  @doc "`:ok` while the configuration is enabled, ready and on this version's configuration version."
  def configuration(%CompositionVersion{} = version) do
    case Configurations.current(version.curation_configuration_id) do
      {:ok, _configuration, %{id: id}} when id == version.configuration_version_id -> :ok
      _ -> {:error, :configuration_changed}
    end
  end

  @doc "`:ok` while the composition's scope is the version's."
  def scope(%CompositionVersion{scope_signature: s}, %Composition{scope_signature: s}), do: :ok
  def scope(_version, _composition), do: {:error, :scope_changed}

  @doc "`:ok` when an evaluation is clean and matches the version's fingerprint."
  def eligible(evaluation, %CompositionVersion{} = version) do
    cond do
      match?({:error, _}, evaluation.lead_rule) ->
        evaluation.lead_rule

      not evaluation.ok? ->
        {:error, {:ineligible, Enum.reject(evaluation.results, &(elem(&1, 2) == :ok))}}

      evaluation.fingerprint != version.eligibility_fingerprint ->
        {:error, :stale_eligibility}

      true ->
        :ok
    end
  end

  @doc "The latest review of a version, or `nil`."
  def latest_review(version_id) do
    Repo.one(
      from r in CompositionReview,
        where: r.composition_version_id == ^version_id,
        order_by: [desc: r.id],
        limit: 1
    )
  end

  @doc "The composition row, locked for the rest of the transaction."
  def lock_composition(id) do
    case Repo.one(from c in Composition, where: c.id == ^id, lock: "FOR UPDATE") do
      nil -> {:error, :not_found}
      composition -> {:ok, composition}
    end
  end
end
