defmodule DevilsDictionary.SynchronousCommitTest do
  @moduledoc """
  The suite's commits do not wait for the disk; the corpus's always do
  (#211, pre-authorisation 6).

  On the dictionary's own cluster every commit waits for an F_FULLFSYNC
  (`wal_sync_method = fsync_writethrough`, D3). Test databases are
  disposable, so `config/test.exs` turns `synchronous_commit` off for the
  suite's own connections. What keeps that from ever reaching
  `devils_dictionary_v2`:

    * it is a connection parameter, never a setting: no dictionary database,
      no role and no server configuration on the suite's server carries it.
      Where that server holds `devils_dictionary_v2` (the default since the
      move, #211 D11), this checks the corpus itself;
    * no configuration but `test.exs` mentions it, the development
      configuration's Repo has no connection parameters or `after_connect`,
      and the Repo defines no `init/2` that could add one in any environment.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Repo

  test "the suite's own connections commit without waiting for the disk" do
    assert Repo.query!("SHOW synchronous_commit").rows == [["off"]]
  end

  test "no dictionary database, no role and no server configuration carries the setting" do
    # A database or role setting. Other projects share a server, so only
    # settings for every database or for a dictionary database count.
    %{rows: rows} =
      Repo.query!("""
      SELECT coalesce(d.datname, '(every database)'), coalesce(r.rolname, '(every role)'), c
      FROM pg_db_role_setting s
      CROSS JOIN LATERAL unnest(s.setconfig) AS c
      LEFT JOIN pg_database d ON d.oid = s.setdatabase
      LEFT JOIN pg_roles r ON r.oid = s.setrole
      WHERE c ILIKE 'synchronous_commit=%'
        AND (s.setdatabase = 0 OR d.datname LIKE 'devils_dictionary%')
      """)

    assert rows == []

    # The server's own configuration (postgresql.conf, ALTER SYSTEM), which
    # this session's SHOW cannot see past its own parameter.
    %{rows: files} =
      Repo.query!(
        "SELECT sourcefile, setting FROM pg_file_settings WHERE name = 'synchronous_commit'"
      )

    assert Enum.all?(files, fn [_file, setting] -> setting == "on" end), inspect(files)
  end

  test "where the suite's server holds the corpus, the corpus is among what was checked" do
    %{rows: v2} =
      Repo.query!("SELECT oid FROM pg_database WHERE datname = 'devils_dictionary_v2'")

    case v2 do
      [[oid]] ->
        %{rows: [[count]]} =
          Repo.query!(
            """
            SELECT count(*) FROM pg_db_role_setting s, unnest(s.setconfig) c
            WHERE s.setdatabase = $1 AND c ILIKE 'synchronous_commit=%'
            """,
            [oid]
          )

        assert count == 0

      [] ->
        # This server does not hold the corpus; the previous test covers it.
        :ok
    end
  end

  test "only test.exs sets it, in any environment" do
    for file <- ~w(config.exs dev.exs prod.exs runtime.exs) do
      refute File.read!(Path.join("config", file)) =~ ~r/synchronous_commit/i,
             "config/#{file} mentions synchronous_commit"
    end

    # config.exs with dev.exs imported, as the development server reads them.
    dev = Config.Reader.read!("config/config.exs", env: :dev)[:devils_dictionary][Repo]
    refute Keyword.has_key?(dev, :parameters)
    refute Keyword.has_key?(dev, :after_connect)

    # A Repo.init/2 would apply in every environment.
    Code.ensure_loaded(Repo)
    refute function_exported?(Repo, :init, 2)
  end
end
