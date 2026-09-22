defmodule DevilsDictionary.Discovery.Provider.Helpers do
  @moduledoc """
  The small things every provider needs, written once (#144 Phase 1).

  Nine providers, three generations deep, arrived at the same dozen private
  functions independently: eight copies of `presence/1`, nine of `headers/0`,
  seven of the config-overridable pacing read, three byte-identical copies of
  the **whole-word attestation gate** — two of whose moduledocs named
  PoetryDB's copy as the authority for the copy they held. A shared rule
  implemented eleven times is eleven rules that happen to agree today.

  Two of them had already drifted. `drop_hidden/1` existed twice with
  different quote classes, so the same hidden `<span style='display:none'>`
  was stripped by one provider and shown by the other; the superset is here
  and the narrower one is gone.

  ## How a provider takes it

      import DevilsDictionary.Discovery.Provider.Helpers

  An `import`, and not callbacks injected by `use DevilsDictionary.Discovery.Provider`.
  The choice is recorded because both were on the table:

    * Injection would make every helper a **public** function of every
      provider module — `defoverridable` needs `def` — so sharing private code
      would enlarge eleven public APIs.
    * An injected function has no definition a reader can find. `presence/1`
      called with nothing defining it, in a 700-line provider, is the kind of
      magic this codebase spends its comments avoiding; one `import` line at
      the top names where it comes from.
    * `import … only:` lets a provider take what it uses, and the compiler
      warns when it stops using it, so the list stays honest by itself.
    * No provider `use`s anything today. Adopting `use` is a second change,
      and it would be riding on a refactor whose whole claim is that nothing
      changed.

  ## What is deliberately *not* here

  A helper belongs here when providers do the same thing, not when they do
  similar things. Three that look shared and are not:

    * **`next_cursor/4`.** Openverse, Pexels and Unsplash have structurally
      identical page builders, and three genuinely different rules for when
      the pages have run out — `page_count`, `total_results`, `total_pages`.
      `page/5` here takes the cursor its caller computed.
    * **The year parsers.** There were five. Two of them are one shape —
      finding a year in free text (`year/1`) — and one more is another,
      reading the year off an ISO date (`iso_year/1`). The other two are not
      year-from-text at all: CineGraph takes the first four characters of
      whatever TMDb put in `releaseDate`, and Open Library coerces an integer
      *field* and returns an integer where every other parser returns a
      string. Folding those in would change what those two providers return,
      which is not what a refactor is for.
    * **The label clamps.** `entities.preferred_label` is `varchar(255)` and
      that number belongs in one place — `clamp_label/1` — but what a provider
      does *before* clamping is its own: Openverse trims, Pexels and Unsplash
      collapse runs of whitespace first, the rest pass the title through. The
      shared part is shared and the rest stays where it was.
  """

  @label_limit 255

  @doc """
  A trimmed string, or `nil` for anything empty or not a string.

  The most-copied function in the layer, at eight. Every provider needs it
  because an API's "no value here" is a field that is absent, `null`, `""` or
  three spaces, depending on the day.
  """
  def presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def presence(_value), do: nil

  @doc "True when `value` is a string with something in it. `presence/1`'s predicate."
  def present?(value), do: is_binary(value) and String.trim(value) != ""

  @doc """
  The request headers every provider sends: this project's shared user-agent.

  `Application.fetch_env!/2` and not `get_env/3` — a node with no user-agent
  configured is a node about to identify itself to nine APIs as `req/0.7`, and
  the Wikimedia and Met terms both ask for a real one. Failing at the first
  request is the cheaper failure.
  """
  def headers do
    [{"user-agent", Application.fetch_env!(:devils_dictionary, :user_agent)}]
  end

  @doc """
  A provider's own configuration stanza, as a keyword list.

  `get_env` with `[]` rather than `fetch_env!`: a provider whose stanza is
  absent falls back to its compiled-in defaults, which is what every
  `interval/3` and endpoint read below already assumed.
  """
  def config(key) when is_atom(key), do: Application.get_env(:devils_dictionary, key, [])

  @doc """
  One pacing key from a provider's config, or the provider's own default.

  The transport reads `request_interval_ms` and `min_retry_interval_ms` off
  `capabilities/0`, and a provider's measured pace is a default an operator may
  override without a deploy. Anything that is not non-negative milliseconds is
  the default, because a half-read override is a rate nobody chose.

  It takes the config list rather than the config **key**, which is the one
  arity this kit could not keep: the copies read a module-local `config/0` and
  the kit has no way to know which stanza is yours. `interval(config(:met),
  :request_interval_ms, 3_000)` is the shape.
  """
  def interval(config, key, default) when is_list(config) and is_atom(key) do
    case config[key] do
      ms when is_integer(ms) and ms >= 0 -> ms
      _other -> default
    end
  end

  @doc """
  A cursor read back as a non-negative offset, and `0` for anything else.

  Existed in two shapes differing only in whether `""` had its own clause —
  which it does not need, since `Integer.parse("")` is already `:error`.
  """
  def offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} when offset >= 0 -> offset
      _other -> 0
    end
  end

  def offset(_value), do: 0

  @doc """
  The page size a request asked for, the provider's default, and its ceiling.

  Both shapes the copies had: `limit(first, default)` for a provider with no
  ceiling of its own, and `limit(first, default, max)` for one whose API caps a
  page. The cap applies to what was **asked for** and not to the default,
  exactly as the copies did — a default above the ceiling would be the
  provider's own bug and hiding it here would not help.
  """
  def limit(first, default, max \\ :infinity)
  def limit(first, _default, :infinity) when is_integer(first) and first > 0, do: first

  def limit(first, _default, max) when is_integer(first) and first > 0 and is_integer(max),
    do: min(first, max)

  def limit(_first, default, _max), do: default

  @doc """
  An absolute `http(s)` URL with a host, trimmed — or `nil`.

  Every one of these reaches an `href` or an `src` in the renderer, which
  allows nothing else (`Culture.external_href/1`, #116 Phase 3). A relative
  path or a `javascript:` scheme an upstream record carried is `nil` here
  rather than a link that does something else on the page.
  """
  def media_url(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        String.trim(value)

      _uri ->
        nil
    end
  end

  def media_url(_value), do: nil

  @doc """
  A label clamped to `entities.preferred_label`'s `varchar(255)`.

  Postgres counts **characters** and `String.slice/3` counts graphemes, which
  is the pair that makes this safe for a title with an accent in it. The number
  was written out in seven places; it is written out here.
  """
  def clamp_label(value), do: String.slice(to_string(value), 0, @label_limit)

  @doc "The width `clamp_label/1` clamps to, so a test can say why."
  def label_limit, do: @label_limit

  @doc """
  A map with its `nil` values dropped.

  The sparse preview map five providers build by hand. A key whose value is
  `nil` is not "this field is empty" to the renderer — it is a key that exists,
  and `preview_metadata["year"]` returning `nil` from an absent key and from a
  present one are two different facts to anything that pattern-matches.
  """
  def sparse(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  A year found anywhere in free text — `1000`–`2099` — as a string, or `nil`.

  A museum's date field is prose: *ca. 1863*, *1914–18*, *19th century*. This
  finds the first four-digit year in it and refuses everything else, so a
  catalogue number never becomes a date.
  """
  def year(value) when is_binary(value) do
    case Regex.run(~r/\b(1\d{3}|20\d{2})\b/, value) do
      [_match, year] -> year
      _other -> nil
    end
  end

  def year(_value), do: nil

  @doc """
  The year of an ISO-8601 date — `2019` from `2019-06-07` — as a string, or `nil`.

  Anchored, and requiring the separator, so it reads a date and not the first
  four characters of whatever was in the field.
  """
  def iso_year(value) when is_binary(value) do
    case Regex.run(~r/\A(\d{4})-/, value) do
      [_match, year] -> year
      _other -> nil
    end
  end

  def iso_year(_value), do: nil

  # Both quote classes. Wikimedia's `extmetadata` HTML uses `"` and Openverse
  # passes through whatever its upstream held, which is sometimes `'` — the
  # two copies of this differed in exactly that, so one of them was showing a
  # credit line the other hid.
  @hidden ~r/<(\w+)\b[^>]*style=["'][^"']*display:\s*none[^"']*["'][^>]*>(?:(?!<\1\b).)*?<\/\1>/s

  @doc """
  HTML with its `display: none` elements removed, repeatedly until it settles.

  A credit line is read out of an upstream's HTML, and an element the upstream
  hid is one it did not mean to publish — a "this is a machine-readable
  duplicate" span, most often. Repeatedly, because the elements nest.
  """
  def drop_hidden(html) when is_binary(html) do
    case Regex.replace(@hidden, html, " ") do
      ^html -> html
      stripped -> drop_hidden(stripped)
    end
  end

  @doc """
  The whole-word pattern for a term: **the** attestation gate (#144 Phase 1).

  A lookaround on the Unicode letter and number classes — not `\\b` — matched
  case-insensitively with `u`. *war* is found in *the dogs of war* and in
  *WAR!*, and not in *warehouse*, *swarm* or *prewar*.

  It existed three times, byte-identical, in PoetryDB, Open Library and Bing
  News, and two of those moduledocs named PoetryDB's copy as their authority —
  a shared rule with no shared code, holding up promise 1 of the README. It is
  one function now, and `whole_word?/2` is the question most callers are
  actually asking.

  ### What this is not

  All three copies carried the same explanation: that `\\b` "treats an
  apostrophe as a boundary and would find *war* inside *war's*". Measured, on
  this pattern, that is not a difference — `war's` and `war-torn` **both
  match**, here and under `\\b`, because an apostrophe and a hyphen are
  outside `\\p{L}\\p{N}` just as they are outside `\\w`. And Elixir's `u`
  flag makes `\\b` Unicode-aware, so accented neighbours are not a difference
  either: *waré* matches neither.

  The one case the two rules disagree on is the **underscore**, which `\\w`
  includes and `\\p{L}\\p{N}` does not, so *war_zone* is an attestation here
  and is not under `\\b`. That is the whole of it, and the pattern is
  unchanged from the three copies — only the explanation was wrong, in all
  three places, which is its own argument for one copy.

  Compiled, so a caller scanning many lines compiles once and matches often.
  """
  def word_pattern(term) when is_binary(term) do
    escaped = term |> String.trim() |> Regex.escape()
    Regex.compile!("(?<![\\p{L}\\p{N}])#{escaped}(?![\\p{L}\\p{N}])", "iu")
  end

  @doc """
  True when `text` uses `term` as a whole word.

  Takes a term or a pattern from `word_pattern/1`, so a caller with one line to
  check reads naturally and a caller with three hundred compiles the pattern
  once.
  """
  def whole_word?(text, %Regex{} = pattern) when is_binary(text),
    do: Regex.match?(pattern, text)

  def whole_word?(text, term) when is_binary(text) and is_binary(term),
    do: Regex.match?(word_pattern(term), text)

  def whole_word?(_text, _term), do: false

  @doc """
  One offset-paged page, as the three image providers build it.

  `build` maps a raw row to an item or `nil`. What happens after is the part
  they shared to the line: drop what did not build, one item per external id,
  one per upload (`upload/1`), and position by final order — so a duplicate
  removed does not leave a hole in the numbering a shelf would read as a gap.

  `next_cursor` is passed in rather than computed. The three providers' page
  builders are identical and their end-of-results rules are not: Openverse
  counts `page_count`, Pexels `total_results`, Unsplash `total_pages`.

  The request parameters gain `offset`, `scanned` and `kept` — what was asked
  for, what came back and what survived — which is the per-page ledger a
  session reads when a shelf is emptier than the request that filled it.
  """
  def page(request, rows, offset, next_cursor, build)
      when is_map(request) and is_list(rows) and is_integer(offset) and is_function(build, 1) do
    items =
      rows
      |> Enum.map(build)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.external_id)
      |> Enum.uniq_by(&upload/1)
      |> Enum.with_index(&Map.put(&1, :position, &2))

    %{
      request_parameters:
        request
        |> Map.put("offset", Integer.to_string(offset))
        |> Map.put("scanned", length(rows))
        |> Map.put("kept", length(items)),
      items: items,
      next_cursor: next_cursor,
      completion_reason: if(items == [], do: :no_results, else: :results)
    }
  end

  @doc """
  The key one upload is folded on: its creator and title, or its external id.

  An aggregator serves the same photograph under several ids, and the pair the
  uploader typed is what survives that. Downcased, because the same pair
  arrives capitalised differently from different upstreams. An item missing
  either falls back to its own id, which folds nothing — the honest answer when
  there is nothing to compare.
  """
  def upload(item) do
    case {item.preview_metadata["creator"], item.preview_metadata["title"]} do
      {creator, title} when is_binary(creator) and is_binary(title) ->
        {String.downcase(creator), String.downcase(title)}

      _other ->
        item.external_id
    end
  end
end
