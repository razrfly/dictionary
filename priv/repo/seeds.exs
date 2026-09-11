# The source registry (issue #69 §2), the Animals test scope (§3), and the
# dead authors of the layers as people.
#
# The definitions live in DevilsDictionary.Sources.Catalog, not here, because
# seeds do not run in :test — tests upsert the same catalog themselves.
# Idempotent: re-running only refreshes the pinned config.
#
#     mix run priv/repo/seeds.exs

%{sources: sources, scopes: scopes, people: people} = DevilsDictionary.Sources.Catalog.seed!()

IO.puts(
  "seeded #{map_size(sources)} sources, #{map_size(scopes)} scope(s), " <>
    "#{map_size(people)} people"
)

# A development-only account for exercising the gated contribution flow. It
# has no published password: use the local mailbox's magic link. Registration
# never grants this capability, and production seeds never create the account.
if Mix.env() == :dev do
  alias DevilsDictionary.Accounts
  alias DevilsDictionary.Accounts.User
  alias DevilsDictionary.Repo

  user =
    Accounts.get_user_by_email("internal-contributor@example.test") ||
      case Accounts.register_user(%{"email" => "internal-contributor@example.test"}) do
        {:ok, %User{} = user} ->
          user

        {:error, changeset} ->
          raise "could not seed internal test account: #{inspect(changeset.errors)}"
      end

  user
  |> Ecto.Changeset.change(
    internal_contributor: true,
    confirmed_at: user.confirmed_at || DateTime.utc_now(:second)
  )
  |> Repo.update!()

  IO.puts("seeded the gated internal contribution-testing account (magic-link login)")
end
