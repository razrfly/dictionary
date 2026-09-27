# Shared by the Stage 2A rehearsal scripts: refuse anything but an isolated
# rehearsal copy. Loaded with Code.require_file/2.
defmodule Stage2A.Guard do
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.Recovery

  @prefix "devils_dictionary_stage2a_"

  @doc """
  The configured database's identity, after refusing unless:
  DD_STAGE2A_REHEARSAL=1 is set; the database is named #{@prefix}*; it is not
  on the usual server's port 5432 (the rehearsal copies live in a scratch
  cluster); and Oban runs no queues or plugins (DD_NO_OBAN=1).
  """
  def check!(opts \\ []) do
    {_host, port, database} = identity = Recovery.identity(Repo.config())
    oban = Application.get_env(:devils_dictionary, Oban, [])

    refuse = fn reason -> raise "Stage 2A rehearsal refused on #{Recovery.describe(identity)}: #{reason}" end

    if System.get_env("DD_STAGE2A_REHEARSAL") != "1", do: refuse.("DD_STAGE2A_REHEARSAL=1 is not set")
    if not String.starts_with?(database, @prefix), do: refuse.("not a #{@prefix}* copy")
    if port == 5432, do: refuse.("the usual server holds the live corpus; use the scratch cluster")

    if Keyword.get(opts, :oban, true) and (oban[:queues] != false or oban[:plugins] != false),
      do: refuse.("background jobs are on; set DD_NO_OBAN=1")

    identity
  end
end
