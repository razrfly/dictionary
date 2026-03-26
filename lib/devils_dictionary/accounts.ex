defmodule DevilsDictionary.Accounts do
  @moduledoc """
  The Accounts context.

  Handles user authentication via Clerk and user profile management.
  Clerk provides:
  - Social logins (Google, GitHub, etc.)
  - Session management
  - JWT verification

  Implementation notes:
  - Clerk frontend SDK handles sign-in/sign-up UI
  - Backend verifies Clerk session JWTs
  - User records synced from Clerk via webhooks
  """

  import Ecto.Query, warn: false
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Accounts.User

  @doc """
  Gets a user by ID.
  """
  def get_user(id), do: Repo.get(User, id)

  @doc """
  Gets a user by ID, raises if not found.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a user by Clerk ID.
  """
  def get_user_by_clerk_id(clerk_id) do
    Repo.get_by(User, clerk_id: clerk_id)
  end

  @doc """
  Gets a user by email.
  """
  def get_user_by_email(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by username.
  """
  def get_user_by_username(username) do
    Repo.get_by(User, username: username)
  end

  @doc """
  Creates a user from Clerk webhook data.
  """
  def create_user(attrs \\ %{}) do
    %User{}
    |> User.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates or updates a user from Clerk webhook data.
  """
  def upsert_user_from_clerk(clerk_id, attrs) do
    case get_user_by_clerk_id(clerk_id) do
      nil ->
        create_user(Map.put(attrs, :clerk_id, clerk_id))

      user ->
        sync_user_from_clerk(user, attrs)
    end
  end

  @doc """
  Syncs user data from Clerk webhook.
  """
  def sync_user_from_clerk(%User{} = user, attrs) do
    user
    |> User.sync_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a user's profile.
  """
  def update_user_profile(%User{} = user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a user's role (admin only).
  """
  def update_user_role(%User{} = user, role) do
    user
    |> User.admin_changeset(%{role: role})
    |> Repo.update()
  end

  @doc """
  Deletes a user.
  """
  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  @doc """
  Lists all users.
  """
  def list_users do
    Repo.all(User)
  end

  @doc """
  Lists users by role.
  """
  def list_users_by_role(role) do
    from(u in User, where: u.role == ^role)
    |> Repo.all()
  end
end
