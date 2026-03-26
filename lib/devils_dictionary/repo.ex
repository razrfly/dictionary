defmodule DevilsDictionary.Repo do
  use Ecto.Repo,
    otp_app: :devils_dictionary,
    adapter: Ecto.Adapters.Postgres
end
