defmodule Mix.Tasks.Dd.RebuildTest do
  @moduledoc """
  The two things about `mix dd.rebuild` that only a full run made obvious.

  Both were silent. Neither raised, neither was reported as a failure, and each
  cost a whole stage of a rebuild — which is the argument for testing them at
  all: a stage that does nothing and prints `0 ms` is worse than one that
  crashes.

  Both assert on the source text, because both are properties of the Mix runtime
  and of a callback's argument order rather than of a function this test could
  usefully call. Proving them any other way means running two real replays and a
  2.6 GB dump.
  """

  use ExUnit.Case, async: true

  @source File.read!("lib/mix/tasks/dd.rebuild.ex")

  test "the replay stages rerun the task rather than calling it once per session" do
    # `Mix.Task.run/2` runs a task **at most once per session** and returns
    # `:noop` thereafter. A rebuild replays twice — Wikidata, then Wikipedia — so
    # the second call did nothing, reported `replayed … 0 ms`, and left all
    # 85,044 Wikipedia records out of the corpus.
    assert @source =~ ~s|Mix.Task.rerun("dd.replay"|
    refute @source =~ ~s|Mix.Task.run("dd.replay"|
  end

  test "the scope's third rule gets a Wiktionary pass of its own" do
    # `wikidata_taxon` walks a taxonomy that does not exist until Wikidata has
    # been absorbed, so it adds lemmas — 8,724 of them on Animals — *after*
    # Wiktionary has already run. Without a second sweep those words sit in the
    # scope with no senses, which is how *pica*, *loris* and *calyptra* came to
    # be in the corpus and mean nothing.
    assert @source =~ ":\"wiktionary-taxon\""
    assert @source =~ ":\"resolve-taxon\""
    assert @source =~ ":\"link-taxon\""

    # And after the second scope build, not before it.
    taxon = :binary.match(@source, "{:\"scope-taxon\"") |> elem(0)
    sweep = :binary.match(@source, "{:\"wiktionary-taxon\"") |> elem(0)
    assert taxon < sweep
  end

  test "a source module is handed a scope, never its own source" do
    # `absorb/2`'s first argument is the scope; a source looks its own source up.
    # Passing a `%Source{}` was a `FunctionClauseError` in Wiktionary and
    # Wikipedia, the two that pattern-match it — and no error at all in the four
    # that ignore the argument, which is how it survived review.
    assert @source =~ "module.absorb(scope, stage_opts)"
    refute @source =~ "module.absorb(source, stage_opts)"
  end
end
