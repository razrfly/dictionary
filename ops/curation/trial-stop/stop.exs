# The stop a fixed-deadline guard runs (#298 C6), from the serving checkout:
#
#   DD_NO_OBAN=1 mix run --no-start ops/curation/trial-stop/stop.exs \
#     --run-dir DIR [--reason TEXT] [--dry-run]
#
# It refuses any target but devils_dictionary_v2 on 5434 in cluster
# 7693849764459364596 (override with --expect-database, --expect-port and
# --expect-cluster only for a rehearsal against another database).
#
# The stop: disable the editor (already disabled, as in a comparison batch,
# is fine), pause the gateway and stop the private model service, then prove
# the editor is off and the port closed, and write DIR/STOPPED.
#
# --dry-run connects read-only, reads the same state, writes DIR/DRY_RUN_OK
# with what it found and stops nothing.
{opts, _rest, invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      run_dir: :string,
      reason: :string,
      dry_run: :boolean,
      expect_database: :string,
      expect_port: :integer,
      expect_cluster: :string
    ]
  )

if invalid != [], do: raise("unknown options: #{inspect(invalid)}")
run_dir = opts[:run_dir] || raise("--run-dir is required")
unless File.dir?(run_dir), do: raise("run directory missing: #{run_dir}")
dry? = opts[:dry_run] == true
reason = opts[:reason] || "fixed stop guard deadline reached"
database = opts[:expect_database] || "devils_dictionary_v2"
port = opts[:expect_port] || 5434
cluster = opts[:expect_cluster] || "7693849764459364596"

Mix.Task.run("app.config")
Logger.configure(level: :warning)
alias DevilsDictionary.Repo
cfg = Application.fetch_env!(:devils_dictionary, Repo)

unless cfg[:database] == database and cfg[:port] == port,
  do: raise("wrong target: #{inspect({cfg[:database], cfg[:port]})}")

cfg =
  if dry?,
    do:
      Keyword.put(
        cfg,
        :parameters,
        Keyword.put(Keyword.get(cfg, :parameters, []), :default_transaction_read_only, "on")
      ),
    else: cfg

Application.put_env(:devils_dictionary, Repo, cfg)

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

alias DevilsDictionary.Curation.{Configuration, Configurations}
alias DevilsDictionary.Curation.Runtime.{Gateway, ServiceProcess}
c = Repo.get_by!(Configuration, slug: "global-default")
now = DateTime.to_iso8601(DateTime.utc_now())

if dry? do
  s = ServiceProcess.status()

  line =
    "#{now} DRY RUN OK: mix started; target #{database}:#{port} cluster #{cluster}; " <>
      "editor_enabled_version_id #{inspect(c.editor_enabled_version_id)}; " <>
      "service alive #{s.alive}, listening #{inspect(s.listening)}; nothing stopped"

  File.write!(Path.join(run_dir, "DRY_RUN_OK"), line <> "\n")
  IO.puts(line)
else
  alias DevilsDictionary.Accounts.{Scope, User}
  alias DevilsDictionary.Sources.Actor

  [[actor_id]] =
    Repo.query!(
      "select actor_id from curation_configuration_activations where configuration_id=$1 order by id desc limit 1",
      [c.id]
    ).rows

  user = Repo.get!(User, Repo.get!(Actor, actor_id).user_id)
  unless user.reviewer, do: raise("reviewer required")
  scope = Scope.for_user(user)

  try do
    case Configurations.disable_editor(scope, c.id, reason: reason) do
      {:ok, _} -> IO.puts("editor disabled")
      {:error, :editor_not_enabled} -> IO.puts("editor already disabled")
      other -> raise("editor not disabled: #{inspect(other)}")
    end
  after
    IO.inspect(Gateway.pause(reason), label: "gateway_pause")
    IO.inspect(ServiceProcess.stop(), label: "private_service_stop")
  end

  c = Repo.get!(Configuration, c.id)
  s = ServiceProcess.status()

  unless is_nil(c.editor_enabled_version_id) and s.listening == [] and not s.alive,
    do: raise("stop not proven")

  File.write!(Path.join(run_dir, "STOPPED"), DateTime.to_iso8601(DateTime.utc_now()) <> "\n")
  IO.puts("STOP VERIFIED: editor disabled; private port closed")
end
