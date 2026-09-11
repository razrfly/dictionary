alias DevilsDictionary.{Lexicon, Repo}
alias DevilsDictionary.Lexicon.WordPage
alias DevilsDictionary.Encyclopedia.EntityPage

hub =
  Repo.query!(
    """
    WITH visible AS (
      SELECT revision.*
        FROM assertion_revisions revision
       WHERE revision.is_current
         AND revision.lifecycle_state = 'active'
         AND COALESCE(
           (SELECT review.decision
              FROM assertion_reviews review
             WHERE review.assertion_revision_id = revision.id
             ORDER BY review.inserted_at DESC, review.id DESC
             LIMIT 1),
           'needs_review'
         ) NOT IN ('rejected', 'withdrawn')
    ), degree AS (
      SELECT object_object_id id, count(*) n FROM visible GROUP BY 1
      UNION ALL
      SELECT subject_object_id id, count(*) n FROM visible GROUP BY 1
    )
    SELECT entity.object_id
      FROM entities entity
      JOIN degree ON degree.id = entity.object_id
     GROUP BY entity.object_id
     ORDER BY sum(degree.n) DESC
     LIMIT 1
    """,
    [],
    timeout: :infinity
  ).rows
  |> hd()
  |> hd()

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
