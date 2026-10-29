defmodule DevilsDictionary.Curation.DueDispatcher do
  @moduledoc """
  Bounded ten-page due checks for an explicitly enabled single-editor policy.
  One scheduled Oban job per configuration version; no model calls here.
  It schedules its successor before examining pages, so a failed page or
  exhausted worker retry cannot silently lose the due chain. Disabling or
  activating another version stops the chain; deliberate enable resumes it.
  Existing Refresh admission coalesces visits and dispatch and honors backoff.
  """
  use Oban.Worker,
    queue: :curation,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:configuration_version_id],
      states: [:available, :scheduled, :retryable]
    ]

  require Logger
  alias DevilsDictionary.Curation.{Configurations, Compositions, Pilot, Refresh}
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage

  @doc "Schedule one due scan; called transactionally when the editor is enabled."
  def schedule(version_id, delay \\ 0) do
    %{configuration_version_id: version_id} |> new(schedule_in: delay) |> Oban.insert!()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"configuration_version_id" => id}}) do
    case Configurations.editor_enabled(id) do
      {:ok, _} ->
        version = DevilsDictionary.Repo.get!(DevilsDictionary.Curation.ConfigurationVersion, id)

        if Configurations.autonomous?(version) do
          schedule(id, 300)
          dispatch(version)
        end

        :ok

      :off ->
        :ok
    end
  end

  @doc "Read the bounded pilot inventory and feed due work through existing admission."
  def dispatch(version, read_page \\ &page/1) do
    for slug <- Pilot.pages() do
      {slug, safely_dispatch(version, slug, read_page)}
    end
  end

  defp page(slug), do: slug |> Lexicon.lookup() |> WordPage.build(viewer: :public)

  defp safely_dispatch(version, slug, read_page) do
    try do
      page = read_page.(slug)
      lexemes = page.headword.lexemes

      case lexemes do
        [first | _] ->
          case Compositions.active(
                 version.configuration_id,
                 :lexical_page,
                 first.language,
                 Compositions.signature(Enum.map(lexemes, & &1.id))
               ) do
            %{mode: :open} = composition -> Refresh.admit(composition.id, slug: slug)
            _ -> :held_or_unprovisioned
          end

        _ ->
          :no_scope
      end
    rescue
      error ->
        # No provider payloads or exception messages in operator logs.
        Logger.warning("curation due scan failed for #{slug}: #{inspect(error.__struct__)}")
        {:error, :page_read_failed}
    end
  end
end
