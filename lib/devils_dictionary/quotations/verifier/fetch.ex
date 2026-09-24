defmodule DevilsDictionary.Quotations.Verifier.Fetch do
  @moduledoc """
  How the verifier spends a request and keeps what it bought (#158 build 5).

  **Spend.** Every request is claimed against its checker's own row in
  `source_policies` through `Discovery.Budget.claim_shared/4` and ledgered on
  the verification run (`discovery_request_attempts.verification_run_id`), so
  the operator's view counts the verifier with everything else. A refused
  claim, a `429` or a `5xx` is `{:deferred, seconds}` — the run stops and its
  refresh clock is set, never retried in a loop.

  **Keep.** Every answer is a source record under the checker's source, the
  way an absorb keeps a fetched record, and is reused while younger than the
  caller's `max_age`: an author's Wikiquote page, the Wikidata works list, a
  Gutenberg text. A Gutenberg text does not change, so it is effectively
  fetched once; that is what makes a line's marginal cost zero requests after
  its author's first pass.
  """

  import Ecto.Query

  alias DevilsDictionary.Discovery.Budget
  alias DevilsDictionary.Quotations.VerificationRun
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Sources.SourceRecord

  @doc """
  The payload of `source_slug`'s record `external_id` if it is younger than
  `max_age` seconds, and otherwise whatever `fetch` returns, stored first.

  `fetch` returns `{:ok, payload}` (a map), `{:deferred, seconds}` or
  `{:error, code}`. Returns `{:ok, payload, revision_id}` or the same failures.
  """
  def cached(source_slug, external_id, max_age, url, fetch) do
    source = Sources.get_source_by_slug!(source_slug)
    cutoff = DateTime.add(DateTime.utc_now(), -max_age, :second)

    held =
      Repo.one(
        from r in SourceRecord,
          join: rev in SourceRecordRevision,
          on: rev.source_record_id == r.id and rev.revision_key == r.content_hash,
          where:
            r.source_id == ^source.id and r.external_id == ^external_id and
              r.fetched_at > ^cutoff,
          select: {rev.payload, rev.id}
      )

    case held do
      {payload, revision_id} ->
        {:ok, payload, revision_id}

      nil ->
        case fetch.() do
          {:ok, payload} when is_map(payload) ->
            {:ok, record} =
              Sources.upsert_record(source, %{external_id: external_id, url: url, raw: payload})

            {:ok, payload, record.current_revision.id}

          other ->
            other
        end
    end
  end

  @doc """
  One budgeted GET. `{:ok, body}`, `{:ok, :absent}` for a `404`,
  `{:deferred, seconds}` or `{:error, code}`.
  """
  def get(%VerificationRun{} = run, source_slug, stage, request) do
    case Budget.claim_shared(source_slug, {:verification, run.id}, stage,
           request_interval_ms: interval()
         ) do
      {:ok, wait_ms} ->
        if wait_ms > 0, do: Process.sleep(wait_ms)

        Repo.update_all(from(r in VerificationRun, where: r.id == ^run.id),
          inc: [request_count: 1]
        )

        request
        |> Keyword.merge(
          method: :get,
          retry: false,
          receive_timeout: 30_000,
          headers: [
            {"user-agent", DevilsDictionary.Absorb.Clients.HTTP.user_agent()}
            | Keyword.get(request, :headers, [])
          ]
        )
        |> Keyword.merge(Application.get_env(:devils_dictionary, :verification_req_options, []))
        |> Req.request()
        |> answer()

      {:deferred, seconds} ->
        {:deferred, seconds}

      {:error, reason} ->
        {:error, "budget_#{reason}"}
    end
  end

  defp answer({:ok, %Req.Response{status: 200, body: body}}), do: {:ok, body}
  defp answer({:ok, %Req.Response{status: 404}}), do: {:ok, :absent}

  defp answer({:ok, %Req.Response{status: status} = response})
       when status == 429 or status >= 500 do
    seconds =
      case Req.Response.get_header(response, "retry-after") do
        [value | _] ->
          case Integer.parse(value) do
            {n, _} -> max(n, 1)
            :error -> 60
          end

        [] ->
          60
      end

    {:deferred, seconds}
  end

  defp answer({:ok, %Req.Response{status: status}}), do: {:error, "http_#{status}"}
  defp answer({:error, _exception}), do: {:deferred, 60}

  defp interval do
    :devils_dictionary
    |> Application.get_env(:verification, [])
    |> Keyword.get(:request_interval_ms, 200)
  end
end
