# Shared by the Stage 2 rehearsal scripts: refuse anything but an isolated
# rehearsal copy. Loaded with Code.require_file/2.
defmodule Stage2.Guard do
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.Recovery

  # devils_dictionary_stage2a_* (the Stage 2A rehearsal) and
  # devils_dictionary_stage2r_* (the recovery repair's) are both copies.
  @copy ~r/^devils_dictionary_stage2[a-z]?_/

  @doc """
  The configured database's identity, after refusing unless:
  DD_STAGE2_REHEARSAL=1 (or Stage 2A's DD_STAGE2A_REHEARSAL=1) is set; the
  database is named devils_dictionary_stage2*_*; it is not on the usual
  server's port 5432 (the rehearsal copies live in a scratch cluster); and
  Oban runs no queues or plugins (DD_NO_OBAN=1).
  """
  def check!(opts \\ []) do
    {_host, port, database} = identity = Recovery.identity(Repo.config())
    oban = Application.get_env(:devils_dictionary, Oban, [])

    refuse = fn reason -> raise "Stage 2 rehearsal refused on #{Recovery.describe(identity)}: #{reason}" end

    if "1" not in [System.get_env("DD_STAGE2_REHEARSAL"), System.get_env("DD_STAGE2A_REHEARSAL")],
      do: refuse.("DD_STAGE2_REHEARSAL=1 is not set")

    if not Regex.match?(@copy, database), do: refuse.("not a devils_dictionary_stage2*_* copy")
    if port == 5432, do: refuse.("the usual server holds the live corpus; use the scratch cluster")

    if Keyword.get(opts, :oban, true) and (oban[:queues] != false or oban[:plugins] != false),
      do: refuse.("background jobs are on; set DD_NO_OBAN=1")

    identity
  end
end
