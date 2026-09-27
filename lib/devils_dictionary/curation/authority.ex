defmodule DevilsDictionary.Curation.Authority do
  @moduledoc """
  Who may act on curation, checked the way `Contributions.review/6` checks a
  claim review.

  The role is read from the account row under `FOR UPDATE`, so a revocation
  that commits first wins. The actor is the account's own `user` actor. A bot
  actor is never returned, and there is no bot approver (R1). The database
  checks the same rule again on every decision and receipt it stores.

    * `:reviewer`: reviews, activates, admits and publishes. The account's
      `reviewer` flag.
    * `:author`: provisions compositions, changes scopes, and writes manual
      versions. A reviewer or an internal contributor.

  Call inside a transaction.
  """

  import Ecto.Query

  alias DevilsDictionary.Accounts.User
  alias DevilsDictionary.Claims.Contributions
  alias DevilsDictionary.Repo

  @doc "The acting account's actor, or `{:error, :unauthorized}`."
  def actor(scope, role) when role in [:reviewer, :author] do
    with %{user: %{id: id}} <- scope,
         %User{} = user <- Repo.one(from u in User, where: u.id == ^id, lock: "FOR UPDATE"),
         true <- permitted?(user, role) do
      {:ok, Contributions.account_actor!(user)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp permitted?(%User{reviewer: true}, _role), do: true
  defp permitted?(%User{internal_contributor: true}, :author), do: true
  defp permitted?(_user, _role), do: false
end
