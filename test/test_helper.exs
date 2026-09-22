# 120 s per test, not the default 60. `deferred_constraints_test.exs` builds
# 6,000 words and resolves them; it takes 3.9 s alone and was killed at 60 s
# once in six full runs while other sessions' suites shared the machine. The
# ceiling is there to catch a hang, and a hang is still caught at 120 s.
ExUnit.start(timeout: 120_000)
Ecto.Adapters.SQL.Sandbox.mode(DevilsDictionary.Repo, :manual)
# One run per database, and an empty database to start it on — see the
# function's doc for the two failure modes it closes.
DevilsDictionary.DataCase.claim_database!()
