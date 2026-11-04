# The guard's dry run (#298 C6), from the serving checkout:
#
#   DD_NO_OBAN=1 mix run --no-start ops/curation/trial-stop/dry-run.exs \
#     --run-dir DIR --stop-script PATH
#
# It proves the environment it runs in (launchd's, when the guard runs it)
# can start mix and reach the target read-only, and it stops nothing, ever:
# it disables no editor, pauses no gateway and stops no service. It reads
# the editor switch and the service status, hashes the stop script the real
# guard would run (reading it, never running it), and writes DIR/DRY_RUN_OK.
# Same target rule as stop.exs (--expect-* only for a rehearsal).
{opts, _rest, invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      run_dir: :string,
      stop_script: :string,
      expect_database: :string,
      expect_port: :integer,
      expect_cluster: :string
    ]
  )

if invalid != [], do: raise("unknown options: #{inspect(invalid)}")
run_dir = opts[:run_dir] || raise("--run-dir is required")
unless File.dir?(run_dir), do: raise("run directory missing: #{run_dir}")
stop_script = opts[:stop_script] || raise("--stop-script is required")
stop_sha256 = :crypto.hash(:sha256, File.read!(stop_script)) |> Base.encode16(case: :lower)
database = opts[:expect_database] || "devils_dictionary_v2"
port = opts[:expect_port] || 5434
cluster = opts[:expect_cluster] || "7693849764459364596"

Mix.Task.run("app.config")
Logger.configure(level: :warning)
alias DevilsDictionary.Repo
cfg = Application.fetch_env!(:devils_dictionary, Repo)

unless cfg[:database] == database and cfg[:port] == port,
  do: raise("wrong target: #{inspect({cfg[:database], cfg[:port]})}")

# Read-only at the connection: nothing this script runs can write.
Application.put_env(
  :devils_dictionary,
  Repo,
  Keyword.put(
    cfg,
    :parameters,
    Keyword.put(Keyword.get(cfg, :parameters, []), :default_transaction_read_only, "on")
  )
)

Application.put_env(
  :devils_dictionary,
  Oban,
  Keyword.merge(Application.fetch_env!(:devils_dictionary, Oban),
    queues: false,
    plugins: false,
    peer: false,
    testing: :manual
  )
)

Application.put_env(
  :devils_dictionary,
  DevilsDictionaryWeb.Endpoint,
  Keyword.put(Application.fetch_env!(:devils_dictionary, DevilsDictionaryWeb.Endpoint), :server, false)
)

{:ok, _} = Application.ensure_all_started([:postgrex, :ecto_sql, :req])
{:ok, _} = Repo.start_link()

[[^cluster]] = Repo.query!("select system_identifier::text from pg_control_system()").rows

c = Repo.get_by!(DevilsDictionary.Curation.Configuration, slug: "global-default")
s = DevilsDictionary.Curation.Runtime.ServiceProcess.status()

line =
  "#{DateTime.to_iso8601(DateTime.utc_now())} DRY RUN OK: mix started; target #{database}:#{port} cluster #{cluster}; " <>
    "editor_enabled_version_id #{inspect(c.editor_enabled_version_id)}; " <>
    "service alive #{s.alive}, listening #{inspect(s.listening)}; " <>
    "stop script #{stop_script} sha256 #{stop_sha256} (read, not run); nothing stopped"

File.write!(Path.join(run_dir, "DRY_RUN_OK"), line <> "\n")
IO.puts(line)
