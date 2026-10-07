# #172 final sweep, 2026-09-27: the screenshot server on port 4172 (no Oban); produced no runs (see README.md).
# This branch's app on port 4172 for screenshots, against the dev database,
# with Oban unable to run anything (the main checkout's node on 4007 owns the
# queues). Every page shot here has fresh runs from run_pages.exs, so a visit
# admits nothing.
oban = Application.fetch_env!(:devils_dictionary, Oban)
Application.put_env(:devils_dictionary, Oban, Keyword.merge(oban, testing: :manual, queues: false, plugins: false))
endpoint = Application.fetch_env!(:devils_dictionary, DevilsDictionaryWeb.Endpoint)
Application.put_env(:devils_dictionary, DevilsDictionaryWeb.Endpoint,
  Keyword.merge(endpoint, server: true, http: [ip: {127, 0, 0, 1}, port: 4172], watchers: [], live_reload: []))
{:ok, _} = Application.ensure_all_started(:devils_dictionary)
IO.puts("serving on 4172")
Process.sleep(:infinity)
