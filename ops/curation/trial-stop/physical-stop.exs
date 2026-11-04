# The guard's fallback when stop.exs fails (#298 C6): stop the private model
# service only, and prove it stopped.
Mix.Task.run("app.config")
IO.inspect(DevilsDictionary.Curation.Runtime.ServiceProcess.stop(), label: "fallback_private_stop")
s = DevilsDictionary.Curation.Runtime.ServiceProcess.status()
unless s.listening == [] and not s.alive, do: raise("private stop unproven")
