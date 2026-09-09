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
    LEFT JOIN lexemes #{prefix}l ON #{prefix}l.object_id = #{column}
    LEFT JOIN senses #{prefix}s ON #{prefix}s.object_id = #{column}
    LEFT JOIN lexemes #{prefix}sl ON #{prefix}sl.object_id = #{prefix}s.lexeme_id
    """
  end

  defp endpoint_lemma(prefix), do: "lower(coalesce(#{prefix}l.lemma, #{prefix}sl.lemma))"

  defp dimensions do
    [
      %{
        key: "lexemes",
        title: "lemma, language and part of speech",
        baseline:
          "SELECT lang || '|' || lower(lemma) || '|' || coalesce(pos, '') AS k FROM lexemes",
        current:
          "SELECT language_tag || '|' || lower(lemma) || '|' || coalesce(part_of_speech, '') AS k FROM lexemes"
      },
      %{
        key: "senses",
        title: "what each source says a word means",
        baseline: """
        SELECT so.slug || '|' || lower(l.lemma) || '|' || coalesce(l.pos, '') || '|' || #{norm("se.gloss")} AS k
          FROM senses se
          JOIN lexemes l ON l.id = se.lexeme_id
          JOIN sources so ON so.id = se.source_id
        """,
        current: """
        SELECT so.slug || '|' || lower(l.lemma) || '|' || coalesce(l.part_of_speech, '') || '|' || #{norm("r.gloss")} AS k
          FROM senses se
          JOIN sense_revisions r ON r.sense_id = se.object_id AND r.is_current
          JOIN lexemes l ON l.object_id = se.lexeme_id
          JOIN sources so ON so.id = se.source_id
        """
      },
      %{
        key: "content",
        title: "authored definitions and articles",
        baseline: """
        SELECT so.slug || '|' || lower(coalesce(e.headword, '')) || '|' || md5(#{norm("e.body")}) AS k
          FROM entries e
          JOIN sources so ON so.id = e.source_id
        """,
        current: """
        SELECT so.slug || '|' || lower(coalesce(r.headword, '')) || '|' || md5(#{norm("r.body")}) AS k
          FROM content_items c
          JOIN content_revisions r ON r.content_id = c.object_id AND r.is_current
          JOIN sources so ON so.id = c.source_id
        """
      },
      %{
        key: "relations",
        title: "source-native lexical edges",
        baseline: """
        SELECT lr.type || '|' || lower(coalesce(fl.lemma, fsl.lemma)) || '|' ||
               lower(coalesce(tl.lemma, tsl.lemma, lr.to_lemma)) as k
          FROM lexical_relations lr
          LEFT JOIN lexemes fl ON fl.id = lr.from_lexeme_id
          LEFT JOIN senses fs ON fs.id = lr.from_sense_id
          LEFT JOIN lexemes fsl ON fsl.id = fs.lexeme_id
          LEFT JOIN lexemes tl ON tl.id = lr.to_lexeme_id
          LEFT JOIN senses ts ON ts.id = lr.to_sense_id
          LEFT JOIN lexemes tsl ON tsl.id = ts.lexeme_id
         WHERE coalesce(fl.lemma, fsl.lemma) IS NOT NULL
           AND coalesce(tl.lemma, tsl.lemma, lr.to_lemma) IS NOT NULL
        """,
        current: """
        SELECT p.key || '|' || #{endpoint_lemma("f")} || '|' || #{endpoint_lemma("t")} AS k
          FROM assertion_revisions ar
          JOIN predicates p ON p.id = ar.predicate_id
          #{endpoint_joins("f", "ar.subject_object_id")}
          #{endpoint_joins("t", "ar.object_object_id")}
         WHERE ar.is_current
           AND p.source_native
           AND p.key NOT IN ('parent_taxon', 'subclass_of', 'instance_of', 'taxon_item')
           AND #{endpoint_lemma("f")} IS NOT NULL
           AND #{endpoint_lemma("t")} IS NOT NULL
        UNION ALL
        SELECT p.key || '|' || #{endpoint_lemma("f")} || '|' || lower(pr.to_lemma) AS k
          FROM pending_relations pr
          JOIN predicates p ON p.id = pr.predicate_id
          #{endpoint_joins("f", "pr.subject_object_id")}
         WHERE #{endpoint_lemma("f")} IS NOT NULL
        """
      },
      %{
        key: "entities",
        title: "the things, by QID",
        baseline: "SELECT qid AS k FROM concepts WHERE qid IS NOT NULL",
        current: "SELECT external_id AS k FROM external_identifiers WHERE namespace = 'wikidata'"
      },
      %{
        key: "taxonomy",
        title: "the taxonomy, QID to QID",
        baseline: """
        SELECT cr.type || '|' || f.qid || '|' || t.qid AS k
          FROM concept_relations cr
          JOIN concepts f ON f.id = cr.from_concept_id
          JOIN concepts t ON t.id = cr.to_concept_id
         WHERE f.qid IS NOT NULL AND t.qid IS NOT NULL
        """,
        current: """
        SELECT p.key || '|' || fx.external_id || '|' || tx.external_id AS k
          FROM assertion_revisions ar
          JOIN predicates p ON p.id = ar.predicate_id
          JOIN external_identifiers fx
            ON fx.object_id = ar.subject_object_id AND fx.namespace = 'wikidata'
          JOIN external_identifiers tx
            ON tx.object_id = ar.object_object_id AND tx.namespace = 'wikidata'
         WHERE ar.is_current AND p.key IN ('parent_taxon', 'subclass_of', 'instance_of')
        """
      },
      %{
        key: "links",
        title: "word to thing, at or above the asserted floor",
        baseline: """
        SELECT lower(coalesce(l.lemma, sl.lemma)) || '|' || c.qid AS k
          FROM concept_links cl
          JOIN concepts c ON c.id = cl.concept_id
          LEFT JOIN lexemes l ON l.id = cl.lexeme_id
          LEFT JOIN senses s ON s.id = cl.sense_id
          LEFT JOIN lexemes sl ON sl.id = s.lexeme_id
         WHERE cl.confidence >= 0.7
           AND c.qid IS NOT NULL
           AND coalesce(l.lemma, sl.lemma) IS NOT NULL
        """,
        current: """
        SELECT #{endpoint_lemma("f")} || '|' || x.external_id AS k
          FROM assertion_revisions ar
          JOIN predicates p ON p.id = ar.predicate_id
          #{endpoint_joins("f", "ar.subject_object_id")}
          JOIN external_identifiers x
            ON x.object_id = ar.object_object_id AND x.namespace = 'wikidata'
         WHERE ar.is_current
           AND p.key in ('refers_to', 'lexeme_entity_candidate')
           AND ar.confidence >= 0.7
           AND #{endpoint_lemma("f")} IS NOT NULL
        """
      },
      %{
        key: "scope",
        title: "scope membership",
        baseline: """
        SELECT sc.slug || '|' || lower(l.lemma) AS k
          FROM scope_lexemes sm
          JOIN scopes sc ON sc.id = sm.scope_id
          JOIN lexemes l ON l.id = sm.lexeme_id
        """,
        current: """
        SELECT sc.slug || '|' || lower(l.lemma) AS k
          FROM scope_lexeme_members sm
          JOIN scopes sc ON sc.id = sm.scope_id
          JOIN lexemes l ON l.object_id = sm.lexeme_id
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
        WITH baseline_keys AS (SELECT DISTINCT k FROM cmp_baseline WHERE k IS NOT NULL),
             current_keys as (
               SELECT DISTINCT k FROM (#{dimension.current}) dimension WHERE k IS NOT NULL
             )
        SELECT (SELECT count(*) FROM baseline_keys),
               (SELECT count(*) FROM current_keys),
               (SELECT count(*)
                  FROM (SELECT k FROM baseline_keys INTERSECT SELECT k FROM current_keys) shared),
               (SELECT array_agg(k)
                  FROM (SELECT k FROM baseline_keys EXCEPT SELECT k FROM current_keys LIMIT $1) lost),
               (SELECT array_agg(k)
                  FROM (SELECT k FROM current_keys EXCEPT SELECT k FROM baseline_keys LIMIT $1) gained)
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
    Postgrex.query!(current, "CREATE TEMP TABLE IF NOT EXISTS cmp_baseline (k text)", [])
    Postgrex.query!(current, "TRUNCATE cmp_baseline", [])

    Postgrex.transaction(
      current,
      fn c ->
        copy = Postgrex.stream(c, "COPY cmp_baseline FROM STDIN", [])

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
