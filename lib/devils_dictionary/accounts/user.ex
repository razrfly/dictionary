defmodule DevilsDictionary.Accounts.User do
  @moduledoc """
  User schema for Clerk authentication integration.

  Users are synced from Clerk via webhooks. The `clerk_id` is the primary
  identifier from Clerk's system, and local user records are created/updated
  when Clerk webhooks fire.

  ## Roles

  - `:user` - Default role, can browse and vote
  - `:editor` - Can submit definitions and edit content
  - `:admin` - Full administrative access

  ## Clerk Integration

  The authentication flow:
  1. User signs in via Clerk (frontend SDK)
  2. Clerk issues a session JWT
  3. Backend verifies JWT on each request
  4. User record created/synced via Clerk webhooks
  """

  use Ecto.Schema
  import Ecto.Changeset

  @role_values [:user, :editor, :admin]

  schema "users" do
    # Clerk integration fields
    field :clerk_id, :string
    field :email, :string
    field :username, :string
    field :display_name, :string
    field :avatar_url, :string

    # App-specific fields
    field :role, Ecto.Enum, values: @role_values, default: :user
    field :bio, :string

    # Clerk sync metadata
    field :clerk_created_at, :utc_datetime
    field :clerk_updated_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a user from Clerk webhook data.
  """
  def create_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :clerk_id,
      :email,
      :username,
      :display_name,
      :avatar_url,
      :clerk_created_at,
      :clerk_updated_at
    ])
    |> validate_required([:clerk_id, :email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> unique_constraint(:clerk_id)
    |> unique_constraint(:email)
    |> unique_constraint(:username)
  end

  @doc """
  Changeset for updating user profile (app-controlled fields).
  """
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :display_name, :bio])
    |> validate_length(:username, min: 3, max: 30)
    |> validate_length(:display_name, max: 100)
    |> validate_length(:bio, max: 500)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]+$/,
      message: "can only contain letters, numbers, and underscores"
    )
    |> unique_constraint(:username)
  end

  @doc """
  Changeset for updating user from Clerk webhook sync.
  """
  def sync_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :email,
      :username,
      :display_name,
      :avatar_url,
      :clerk_updated_at
    ])
    |> validate_required([:email])
    |> unique_constraint(:email)
    |> unique_constraint(:username)
  end

  @doc """
  Admin changeset for role changes.
  """
  def admin_changeset(user, attrs) do
    user
    |> cast(attrs, [:role])
    |> validate_inclusion(:role, @role_values)
  end

  @doc """
  Returns true if user has editor or higher permissions.
  """
  def can_edit?(%__MODULE__{role: role}) when role in [:editor, :admin], do: true
  def can_edit?(_), do: false

  @doc """
  Returns true if user has admin permissions.
  """
  def admin?(%__MODULE__{role: :admin}), do: true
  def admin?(_), do: false
end
