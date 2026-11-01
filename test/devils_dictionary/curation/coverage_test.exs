defmodule DevilsDictionary.Curation.CoverageTest do
  use ExUnit.Case, async: true
  alias DevilsDictionary.Curation.Coverage
  alias DevilsDictionary.Curation.Runtime.Attempt

  test "historical pool, packet, omitted and selected counts have separate denominators" do
    attempt = %Attempt{
      id: 34,
      state: :completed,
      outcome: :accepted,
      packet_summary: %{
        "counts" => %{"offered" => 71},
        "candidates" => [
          %{"candidate_id" => "c1", "kind" => "sense_definition"},
          %{"candidate_id" => "c2", "kind" => "shelf", "shelf" => %{"shelf_kind" => "news"}}
        ],
        "omitted" => [%{"reason" => "over_quota"}, %{"reason" => "meaning_unavailable"}]
      },
      result: %{
        "lead" => %{"candidate_id" => "c1", "reason" => "PROVIDER_SECRET"},
        "highlights" => [%{"candidate_id" => "c2", "reason" => "PROVIDER_SECRET"}]
      }
    }

    report = Coverage.summarize(attempt)
    assert report.eligible_pool == 71
    assert report.packet_candidates == 2
    assert report.omitted == 2
    assert report.selected == 2
    assert report.packet_by_section == %{"definitions" => 1, "news" => 1}
    assert report.selected_candidate_ids == ["c1", "c2"]
    refute Jason.encode!(report) =~ "PROVIDER_SECRET"
  end

  test "missing historic counts are unknown; refusal is not a zero-choice assessment" do
    report = Coverage.summarize(%Attempt{outcome: :refused, packet_summary: %{}})
    assert is_nil(report.eligible_pool)
    assert is_nil(report.omitted)
    assert is_nil(report.selected)

    assert Coverage.summarize(%Attempt{
             outcome: :abstained,
             result: %{"lead" => nil, "highlights" => []}
           }).selected == 0
  end

  test "outside-pilot requests are refused before reading or preparing a page" do
    assert Coverage.read("not-a-pilot") == {:error, :outside_pilot}
    assert Coverage.read("love", limit: 101) == {:error, :invalid_bounds}
    assert Coverage.read("love", from: 35, to: 25) == {:error, :invalid_bounds}
  end

  test "a model call finish is not labelled as a successful editor assessment" do
    time = ~U[2026-10-29 21:00:00Z]
    report = Coverage.summarize(%Attempt{outcome: :refused, finished_at: time})
    assert report.attempt_finished_at == time
    refute Map.has_key?(report, :assessed_at)
  end

  test "report startup disables server and every Oban execution/peer path before connecting read-only" do
    {repo, oban, endpoint} =
      Mix.Tasks.Dd.Curation.Coverage.read_only_config(
        [database: "private_test", parameters: [application_name: "coverage"]],
        [queues: [curation: 1], plugins: [Oban.Plugins.Cron], peer: Oban.Peers.Database],
        server: true
      )

    assert repo[:database] == "private_test"
    assert repo[:parameters][:default_transaction_read_only] == "on"
    assert repo[:parameters][:application_name] == "coverage"
    assert oban[:queues] == false
    assert oban[:plugins] == false
    assert oban[:peer] == false
    assert oban[:testing] == :manual
    assert endpoint[:server] == false
  end
end
