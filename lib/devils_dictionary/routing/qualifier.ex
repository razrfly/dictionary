defmodule DevilsDictionary.Routing.Qualifier do
  @moduledoc """
  A readable qualifier for a collision (ADR 0004 §5): the policy's proposal
  rules, as `docs/routing/stage-2/candidates.py` applies them, in Elixir, so
  the standing review rule (`Routing.ReviewRule`) generates a collision's
  qualified paths itself rather than taking them on trust.

  By family, and only from the record's own description or typed details —
  never invented:

    * **works** — the year and the form (`2024 film`, `novel`), and the
      creator (`by …`) only where year and form still collide;
    * **people** — the last two words of the occupation, and the birth year
      (or the first word) only where those collide;
    * **places** — what follows `in` (`Afghanistan`, `Vestnes Municipality`);
    * every other family — the first and last words of the description.

  `proposals/1` decides a collision group together, as the population does:
  each member's base qualifier first, the extra only for a member whose base
  path another member shares. A member with no description, or no qualifier
  the rules can read, gets nil: it cannot be qualified, and nothing here
  chooses for it. Whether a proposal is free of every other address is the
  caller's question. `test/devils_dictionary/routing/qualifier_test.exs`
  holds both implementations to the 55 proposals of #224's population.

  **Readable means readable.** A path is made of words: a label or
  qualifier the slug would have to spell out — `#` as `sharp`, `.` as
  `dot`, `+` as `plus`, `&` as `and`, so `Inc.` or `ver. 1.0` or `#972` or
  `Simon & Garfunkel` — is not readable (`readable?/1`), and `path/2` gives
  nil for it. The owner named such addresses by hand in #224; the rule
  defers them for a human to name (`simon-and-garfunkel` reads well, but
  that is a human's spelling to approve, not the rule's to invent).

  **Where the port and `candidates.py` differ.** On the population's real
  text they agree on every proposal. On adversarial text they can differ:
  OTP's regex counts combining marks and connector punctuation as word
  characters where Python's `re` does not, `String.trim/1` keeps the
  information separators U+001C–U+001F that Python's `strip` removes (they
  are stripped here too), and the two runtimes carry different Unicode
  versions. Every such divergence makes a path the population did not
  propose, and the rule defers a member whose generated path is not the
  population's own proposal, so a divergence can only defer, never confirm
  another address.
  """

  alias DevilsDictionary.Routing.Policy

  # candidates.py's KINDS, in its order: the first form a description names.
  @kinds [
    "studio album",
    "album",
    "film",
    "documentary",
    "novel",
    "tv series",
    "series",
    "song",
    "poem",
    "painting",
    "anthology",
    "book",
    "play",
    "single",
    "video game",
    "dictionary"
  ]

  @doc """
  The base qualifier and the extra one, `{base, extra}`, for a record of
  `family` with this description and typed work kind. Either may be nil.
  """
  def qualifier(family, description, work_kind \\ nil)

  def qualifier(family, description, work_kind) when is_binary(description) do
    case String.replace(description, ~r/\A[\s\x{1C}-\x{1F}]+|[\s\x{1C}-\x{1F}]+\z/u, "") do
      "" -> {nil, nil}
      desc -> by_family(family, desc, work_kind)
    end
  end

  def qualifier(_family, _description, _work_kind), do: {nil, nil}

  @doc """
  Whether a label or a qualifier makes a readable address: it holds no
  character the slug would spell out as a word (`#` as `sharp`, `+` as
  `plus`, `.` as `dot`, `&` as `and`). Nil or anything else is not readable.
  """
  def readable?(text) when is_binary(text), do: not Regex.match?(~r/[#+.&]/u, text)
  def readable?(_text), do: false

  defp by_family("works", desc, work_kind) do
    low = String.downcase(desc)

    year =
      case Regex.run(~r/\b(1[0-9]{3}|20[0-9]{2})\b/u, desc) do
        [match | _] -> match
        nil -> nil
      end

    kind =
      case Enum.find(@kinds, &String.contains?(low, &1)) || work_kind do
        "studio album" -> "album"
        kind -> kind
      end

    creator =
      case Regex.run(~r/\bby ([^,;(]+)/u, desc) do
        [_, name] -> String.trim(name)
        nil -> nil
      end

    {join([year, kind]), creator}
  end

  defp by_family("people", desc, _work_kind) do
    years = Regex.run(~r/\((\d{4})[-–]/u, desc)
    occupation = desc |> String.replace(~r/\(.*?\)/u, "") |> String.trim()
    ws = Enum.reject(words(occupation), &(String.downcase(&1) in ["and", "of", "the"]))
    base = if ws == [], do: nil, else: ws |> Enum.take(-2) |> Enum.join(" ")

    extra =
      case years do
        [_, year] -> year
        nil -> join(Enum.take(ws, 1))
      end

    {base, extra}
  end

  defp by_family("places", desc, _work_kind) do
    case Regex.run(~r/\bin (?:the )?([^,]+)/u, desc) do
      [_, place] -> {join([String.trim(place)]), nil}
      nil -> {nil, nil}
    end
  end

  defp by_family(_family, desc, _work_kind) do
    case Enum.reject(words(desc), &(String.downcase(&1) in ["a", "an", "the", "of"])) do
      [] -> {nil, nil}
      [only] -> {only, nil}
      [first | rest] -> {first <> " " <> List.last(rest), nil}
    end
  end

  # candidates.py's `words/1`: runs of letters, numbers, combining marks,
  # underscores, apostrophes and hyphens.
  defp words(text), do: ~r/[\p{L}\p{N}\p{M}_'’-]+/u |> Regex.scan(text) |> List.flatten()

  defp join(parts) do
    case parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ") do
      "" -> nil
      text -> text
    end
  end

  @doc """
  The qualified path for a member, `%{label:, family:, description:,
  work_kind:}`, with or without its extra qualifier, or nil when the
  evidence gives no base qualifier, the text is not readable, or the text
  makes no slug.
  """
  def path(member, extra?) do
    {base, extra} = qualifier(member.family, member.description, member[:work_kind])

    with base when is_binary(base) <- base,
         text = join([member.label, base, if(extra?, do: extra)]),
         true <- readable?(text),
         slug when is_binary(slug) <- Policy.slug(text) do
      "/#{member.family}/#{slug}"
    else
      _ -> nil
    end
  end

  @doc """
  The proposed path for each member of one collision group, decided
  together: a member's base path where no other member shares it, otherwise
  its path with the extra qualifier, which may still collide or be nil.
  `members` are the group's mapped members, `%{object_id:, label:, family:,
  description:, work_kind:}`. Returns `%{object_id => path | nil}`.
  """
  def proposals(members) do
    first = Map.new(members, &{&1.object_id, path(&1, false)})
    counts = first |> Map.values() |> Enum.frequencies()

    Map.new(members, fn member ->
      base = first[member.object_id]

      if base && counts[base] == 1,
        do: {member.object_id, base},
        else: {member.object_id, path(member, true)}
    end)
  end
end
