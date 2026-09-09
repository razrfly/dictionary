defmodule Mix.Tasks.Dd.Compare do
  @shortdoc "Compare the rebuilt corpus against a baseline database, semantically"

  @moduledoc """
  #74's milestone 1, the half a row count cannot answer: *"compare on normalised
  semantic content, not row counts"*.

      mix dd.compare                                   # against devils_dictionary_dev
      mix dd.compare --baseline devils_dictionary_dev
      mix dd.compare --only lexemes,senses
      mix dd.compare --examples 10

  ## What it compares, and why these eight

  The encyclopedia model does not keep the baseline's tables, so nothing can be
  diffed row for row: `entries`, `lexical_relations`, `concepts`,
  `concept_relations` and `concept_links` are all gone, and a sense is no longer
  identified by its position in a source payload. What *can* be compared is what
  each corpus **says** — so each dimension is reduced on both sides to the same
  normalised key and the two key sets are compared.

  | Dimension | The key |
  |---|---|
  | `lexemes` | language, lower lemma, part of speech |
  | `senses` | source, lemma, pos, normalised gloss |
  | `content` | source, lower headword, MD5 of the normalised body |
  | `relations` | source-native type, lower subject lemma, lower object lemma |
  | `entities` | the Wikidata QID |
  | `taxonomy` | type, subject QID, object QID |
  | `links` | lower lemma, QID, at or above the asserted floor |
  | `scope` | scope slug, lower lemma |

  Normalisation is the same expression on both sides — lowercased, every run of
  non-alphanumerics collapsed to one space, trimmed — so a gloss that gained a
  full stop is the same gloss, and a gloss that gained a *word* is not.

  `relations` unions `pending_relations` into the current side on purpose: the
  baseline kept an unresolved edge as a row with a `to_lemma` string, and the new
  model keeps it as a pending row. Comparing only assertions would score the new
  corpus down for edges it has not lost.

  ## How it runs

  The baseline's keys are streamed out of that database and `COPY`d into a temp
  table beside the current query, so the set operations happen in Postgres and
  neither side is ever held in memory. Nothing is written outside the temp
  table, and the baseline connection is read-only in practice — this task
  compares, it does not repair.
  """

  use Mix.Task

  import Mix.Tasks.Dd.Report

  @requirements ["app.start"]

  @baseline "devils_dictionary_dev"
  @examples 5

  # Lowercase, every run of non-alphanumerics to one space, trimmed. The same
  # expression on both sides, which is the only thing that makes the comparison
  # a comparison.
  defp norm(column) do
    "btrim(regexp_replace(lower(coalesce(#{column}, '')), '[^a-z0-9]+', ' ', 'g'))"
  end

  # Subject/object lemma for the new model: an endpoint is a lexeme or a sense,
  # and a sense's lemma is its lexeme's.
  defp endpoint_joins(prefix, column) do
    """
    left join lexemes #{prefix}l on #{prefix}l.object_id = #{column}
    left join senses #{prefix}s on #{prefix}s.object_id = #{column}
    left join lexemes #{prefix}sl on #{prefix}sl.object_id = #{prefix}s.lexeme_id
    """
  end

  defp endpoint_lemma(prefix), do: "lower(coalesce(#{prefix}l.lemma, #{prefix}sl.lemma))"

  defp dimensions do
    [
      %{
        key: "lexemes",
        title: "lemma, language and part of speech",
        baseline:
          "select lang || '|' || lower(lemma) || '|' || coalesce(pos, '') as k from lexemes",
        current:
          "select language_tag || '|' || lower(lemma) || '|' || coalesce(part_of_speech, '') as k from lexemes"
      },
      %{
        key: "senses",
        title: "what each source says a word means",
        baseline: """
        select so.slug || '|' || lower(l.lemma) || '|' || coalesce(l.pos, '') || '|' || #{norm("se.gloss")} as k
          from senses se
          join lexemes l on l.id = se.lexeme_id
          join sources so on so.id = se.source_id
        """,
        current: """
        select so.slug || '|' || lower(l.lemma) || '|' || coalesce(l.part_of_speech, '') || '|' || #{norm("r.gloss")} as k
          from senses se
          join sense_revisions r on r.sense_id = se.object_id and r.is_current
          join lexemes l on l.object_id = se.lexeme_id
          join sources so on so.id = se.source_id
        """
      },
      %{
        key: "content",
        title: "authored definitions and articles",
        baseline: """
        select so.slug || '|' || lower(coalesce(e.headword, '')) || '|' || md5(#{norm("e.body")}) as k
          from entries e
          join sources so on so.id = e.source_id
        """,
        current: """
        select so.slug || '|' || lower(coalesce(r.headword, '')) || '|' || md5(#{norm("r.body")}) as k
          from content_items c
          join content_revisions r on r.content_id = c.object_id and r.is_current
          join sources so on so.id = c.source_id
        """
      },
      %{
        key: "relations",
        title: "source-native lexical edges",
        baseline: """
        select lr.type || '|' || lower(coalesce(fl.lemma, fsl.lemma)) || '|' ||
               lower(coalesce(tl.lemma, tsl.lemma, lr.to_lemma)) as k
          from lexical_relations lr
          left join lexemes fl on fl.id = lr.from_lexeme_id
          left join senses fs on fs.id = lr.from_sense_id
          left join lexemes fsl on fsl.id = fs.lexeme_id
          left join lexemes tl on tl.id = lr.to_lexeme_id
          left join senses ts on ts.id = lr.to_sense_id
          left join lexemes tsl on tsl.id = ts.lexeme_id
         where coalesce(fl.lemma, fsl.lemma) is not null
           and coalesce(tl.lemma, tsl.lemma, lr.to_lemma) is not null
        """,
        current: """
        select p.key || '|' || #{endpoint_lemma("f")} || '|' || #{endpoint_lemma("t")} as k
          from assertion_revisions ar
          join predicates p on p.id = ar.predicate_id
          #{endpoint_joins("f", "ar.subject_object_id")}
          #{endpoint_joins("t", "ar.object_object_id")}
         where ar.is_current
           and p.source_native
           and p.key not in ('parent_taxon', 'subclass_of', 'instance_of', 'taxon_item')
           and #{endpoint_lemma("f")} is not null
           and #{endpoint_lemma("t")} is not null
        union all
        select p.key || '|' || #{endpoint_lemma("f")} || '|' || lower(pr.to_lemma) as k
          from pending_relations pr
          join predicates p on p.id = pr.predicate_id
          #{endpoint_joins("f", "pr.subject_object_id")}
         where #{endpoint_lemma("f")} is not null
        """
      },
      %{
        key: "entities",
        title: "the things, by QID",
        baseline: "select qid as k from concepts where qid is not null",
        current: "select external_id as k from external_identifiers where namespace = 'wikidata'"
      },
      %{
        key: "taxonomy",
        title: "the taxonomy, QID to QID",
        baseline: """
        select cr.type || '|' || f.qid || '|' || t.qid as k
          from concept_relations cr
          join concepts f on f.id = cr.from_concept_id
          join concepts t on t.id = cr.to_concept_id
         where f.qid is not null and t.qid is not null
        """,
        current: """
        select p.key || '|' || fx.external_id || '|' || tx.external_id as k
          from assertion_revisions ar
          join predicates p on p.id = ar.predicate_id
          join external_identifiers fx
            on fx.object_id = ar.subject_object_id and fx.namespace = 'wikidata'
          join external_identifiers tx
            on tx.object_id = ar.object_object_id and tx.namespace = 'wikidata'
         where ar.is_current and p.key in ('parent_taxon', 'subclass_of', 'instance_of')
        """
      },
      %{
        key: "links",
        title: "word to thing, at or above the asserted floor",
        baseline: """
        select lower(coalesce(l.lemma, sl.lemma)) || '|' || c.qid as k
          from concept_links cl
          join concepts c on c.id = cl.concept_id
          left join lexemes l on l.id = cl.lexeme_id
          left join senses s on s.id = cl.sense_id
          left join lexemes sl on sl.id = s.lexeme_id
         where cl.confidence >= 0.7
           and c.qid is not null
           and coalesce(l.lemma, sl.lemma) is not null
        """,
        current: """
        select #{endpoint_lemma("f")} || '|' || x.external_id as k
          from assertion_revisions ar
          join predicates p on p.id = ar.predicate_id
          #{endpoint_joins("f", "ar.subject_object_id")}
          join external_identifiers x
            on x.object_id = ar.object_object_id and x.namespace = 'wikidata'
         where ar.is_current
           and p.key in ('refers_to', 'lexeme_entity_candidate')
           and ar.confidence >= 0.7
           and #{endpoint_lemma("f")} is not null
        """
      },
      %{
        key: "scope",
        title: "scope membership",
        baseline: """
        select sc.slug || '|' || lower(l.lemma) as k
          from scope_lexemes sm
          join scopes sc on sc.id = sm.scope_id
          join lexemes l on l.id = sm.lexeme_id
        """,
        current: """
        select sc.slug || '|' || lower(l.lemma) as k
          from scope_lexeme_members sm
          join scopes sc on sc.id = sm.scope_id
          join lexemes l on l.object_id = sm.lexeme_id
        """
      }
    ]
  end

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [baseline: :string, only: :string, examples: :integer, quiet: :boolean]
      )

    baseline_db = opts[:baseline] || @baseline
    examples = opts[:examples] || @examples

    dimensions =
      case opts[:only] do
        nil -> dimensions()
        list -> Enum.filter(dimensions(), &(&1.key in String.split(list, ",", trim: true)))
      end

    baseline = connect!(baseline_db)
    current = connect!(current_database())

    say("semantic comparison · #{current_database()} against #{baseline_db}")
    say("")

    results = Enum.map(dimensions, &compare(&1, baseline, current, examples))

    say("── summary")
    row("dimensions", length(results))
    row("identical", Enum.count(results, &(&1.only_baseline == 0 and &1.only_current == 0)))

    row(
      "mean overlap",
      "#{results |> Enum.map(& &1.jaccard) |> mean() |> Float.round(3)}"
    )

    results
  end

  defp compare(dimension, baseline, current, examples) do
    say("── #{dimension.key} · #{dimension.title}")

    load(baseline, current, dimension.baseline)

    %{rows: [[b, c, both, only_b, only_c]]} =
      Postgrex.query!(
        current,
        """
        with baseline_keys as (select distinct k from cmp_baseline where k is not null),
             current_keys as (
               select distinct k from (#{dimension.current}) dimension where k is not null
             )
        select (select count(*) from baseline_keys),
               (select count(*) from current_keys),
               (select count(*)
                  from (select k from baseline_keys intersect select k from current_keys) shared),
               (select array_agg(k)
                  from (select k from baseline_keys except select k from current_keys limit $1) lost),
               (select array_agg(k)
                  from (select k from current_keys except select k from baseline_keys limit $1) gained)
        """,
        [examples],
        timeout: :infinity
      )

    union = b + c - both
    jaccard = if union == 0, do: 1.0, else: both / union

    row("baseline", b)
    row("current", c)
    row("in both", both)
    row("only baseline", b - both)
    row("only current", c - both)
    row("overlap", Float.round(jaccard, 4))

    for k <- only_b || [], do: row("  − baseline", k)
    for k <- only_c || [], do: row("  + current", k)

    say("")

    %{
      key: dimension.key,
      baseline: b,
      current: c,
      both: both,
      only_baseline: b - both,
      only_current: c - both,
      jaccard: jaccard,
      examples_baseline: only_b || [],
      examples_current: only_c || []
    }
  end

  # Streamed out of one database and `COPY`d into a temp table beside the other,
  # so a 1.5 M-row dimension costs one connection's buffer rather than a heap.
  defp load(baseline, current, sql) do
    Postgrex.query!(current, "create temp table if not exists cmp_baseline (k text)", [])
    Postgrex.query!(current, "truncate cmp_baseline", [])

    Postgrex.transaction(
      current,
      fn c ->
        copy = Postgrex.stream(c, "copy cmp_baseline from stdin", [])

        Postgrex.transaction(
          baseline,
          fn b ->
            Postgrex.stream(b, sql, [], max_rows: 10_000)
            |> Stream.flat_map(& &1.rows)
            |> Stream.map(fn [k] -> [escape(k), ?\n] end)
            |> Enum.into(copy)
          end,
          timeout: :infinity
        )
      end,
      timeout: :infinity
    )
  end

  defp escape(nil), do: "\\N"

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end

  defp connect!(database) do
    config = Application.get_env(:devils_dictionary, DevilsDictionary.Repo)

    {:ok, connection} =
      Postgrex.start_link(
        hostname: config[:hostname] || "localhost",
        username: config[:username],
        password: config[:password],
        port: config[:port] || 5432,
        database: database,
        pool_size: 1,
        timeout: :infinity
      )

    connection
  end

  defp current_database do
    Application.get_env(:devils_dictionary, DevilsDictionary.Repo)[:database]
  end

  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)
end
