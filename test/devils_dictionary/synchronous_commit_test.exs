defmodule DevilsDictionary.SynchronousCommitTest do
  @moduledoc """
  The suite's commits do not wait for the disk; the corpus's always do
  (#211, pre-authorisation 6).

  On the dictionary's own cluster every commit waits for an F_FULLFSYNC
  (`wal_sync_method = fsync_writethrough`, D3). Test databases are
  disposable, so `config/test.exs` turns `synchronous_commit` off for the
  suite's own connections. Three things keep that from ever reaching
  `devils_dictionary_v2`:

    * it is a connection parameter, not a database setting: no database or
      role on the server the suite runs on carries it, and that server is
      the corpus's own;
    * no configuration but `test.exs` mentions it;
    * the development configuration's Repo has no connection parameters.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Repo

  test "the suite's own connections commit without waiting for the disk" do
    assert Repo.query!("SHOW synchronous_commit").rows == [["off"]]
  end

  test "no database or role on the suite's server carries the setting" do
    %{rows: rows} =
      Repo.query!("""
      SELECT coalesce(d.datname, '(every database)'), coalesce(r.rolname, '(every role)'), c
      FROM pg_db_role_setting s
      CROSS JOIN LATERAL unnest(s.setconfig) AS c
      LEFT JOIN pg_database d ON d.oid = s.setdatabase
      LEFT JOIN pg_roles r ON r.oid = s.setrole
      WHERE c ILIKE 'synchronous_commit=%'
      """)

    assert rows == []
  end

  test "only test.exs sets it; the development Repo has no connection parameters" do
    for file <- ~w(config.exs dev.exs prod.exs runtime.exs) do
      refute File.read!(Path.join("config", file)) =~ ~r/synchronous_commit/i,
             "config/#{file} mentions synchronous_commit"
    end

    dev = Config.Reader.read!("config/dev.exs", env: :dev, imports: :disabled)
    refute Keyword.has_key?(dev[:devils_dictionary][DevilsDictionary.Repo], :parameters)
  end
end
