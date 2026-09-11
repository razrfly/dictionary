alias DevilsDictionary.{Lexicon, Repo}
alias DevilsDictionary.Lexicon.WordPage
alias DevilsDictionary.Encyclopedia.EntityPage
hub = Repo.query!("WITH d AS (SELECT object_object_id id, count(*) n FROM assertion_revisions WHERE is_current GROUP BY 1 UNION ALL SELECT subject_object_id id,count(*) n FROM assertion_revisions WHERE is_current GROUP BY 1) SELECT e.object_id FROM entities e JOIN d ON d.id=e.object_id GROUP BY e.object_id ORDER BY sum(d.n) DESC LIMIT 1", [], timeout: :infinity).rows |> hd() |> hd()
probes = Enum.map(~w(cat run set), fn word -> {word, fn -> WordPage.build(Lexicon.lookup(word)) end} end) ++ [{"entity #{hub}", fn -> EntityPage.build(hub) end}]
for {label, build} <- probes do
  for _ <- 1..3, do: build.()
  times = for _ <- 1..20 do
    {microseconds, _} = :timer.tc(build)
    microseconds / 1000
  end
  ordered = Enum.sort(times)
  IO.inspect(%{page: label, p95_ms: Enum.at(ordered, 18), max_ms: List.last(ordered), budget_ms: 150})
end
