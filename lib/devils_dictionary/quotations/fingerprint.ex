defmodule DevilsDictionary.Quotations.Fingerprint do
  @moduledoc """
  A quotation's identifier, made from its own words — the one written
  exception to *association is identity, never text* (ADR 0003, #158 build 3).

  A film has an identifier that is not its title; a line someone said has none
  but its wording. So the wording, normalised by the rules below and hashed, is
  published as an identifier in the namespace `quotation_fingerprint`, beside
  the provider's own id. Two sources' copies of one line then share an
  identifier, the verified-unique index on `external_identifiers` resolves
  them to one `content_items` row, and `Shelf.dedup/2` folds their cards. It is
  an identifier a provider **publishes**, compared for equality; nothing
  searches on it.

  ## What is normalised

  Only differences of typography and transcription, never of wording:

    1. Unicode canonical composition (NFC): a precomposed `é` and `e` plus a
       combining accent are the same letter
    2. case, folded to lower
    3. curly quotes and primes straightened, and every dash (en, em, figure,
       horizontal bar, minus) straightened to a hyphen
    4. `...` written as `…`, and a leading or trailing ellipsis dropped — an
       ellipsis *inside* a line marks an elision and stays, as a word of its
       own however it was spaced
    5. apostrophes removed (`don't` and `dont` are one transcription), every
       other punctuation mark a word break
    6. whitespace collapsed to single spaces and trimmed

  ## What is never normalised

  No stemming, no synonyms, no spelling variants, no translation. "cultivate
  our garden" and "cultivate one's garden" are different claims and different
  fingerprints; a translation is a different line, a different fingerprint and
  a different subject. Digits, symbols (`£`, `+`) and the three marks that
  read as words — `%`, `&`, `#` — are kept: "50% of the time" is not "50 of
  the time".

  The raw normalised text is never stored: the identifier is its SHA-256, and
  `content_revisions.body` keeps the words as the source gave them.

  ## Stability

  The rules are version 1, recorded on the identifier's metadata. Changing any
  rule changes fingerprints, and every held one would have to be rewritten — so
  a change is a new version and a migration of identifiers, decided in an ADR,
  never an edit here.

  Build 1's renderer (the Wiktionary quotations on a word page) folds at
  display time by calling `fingerprint/1` on each line and writes nothing.
  """

  @namespace "quotation_fingerprint"
  @version 1

  @single ~r/[\x{2018}\x{2019}\x{201A}\x{201B}\x{2032}\x{02BC}]/u
  @double ~r/[\x{201C}\x{201D}\x{201E}\x{201F}\x{2033}\x{00AB}\x{00BB}]/u
  @dashes ~r/[\x{2010}\x{2011}\x{2012}\x{2013}\x{2014}\x{2015}\x{2212}]/u
  @edge_ellipsis ~r/\A[\s\p{P}]*…|…[\s\p{P}]*\z/u

  @doc "The namespace a fingerprint is published under."
  def namespace, do: @namespace

  @doc "The normalisation version recorded on every fingerprint identifier."
  def version, do: @version

  @doc """
  The normalised form of a line, by the rules in the moduledoc. One doctest per
  rule, in their order.

  Composition — two encodings of one letter are one letter:

      iex> normalise("caf\\u0065\\u0301") == normalise("caf\\u00e9")
      true

  Case:

      iex> normalise("We Must Cultivate Our Garden")
      "we must cultivate our garden"

  Curly quotes, straightened and then treated as the punctuation they are:

      iex> normalise("“We must cultivate our garden.”")
      "we must cultivate our garden"

  Dashes, straightened to one hyphen and then a word break:

      iex> normalise("war—peace") == normalise("war - peace")
      true

  A leading or trailing ellipsis is dropped; one inside the line stays:

      iex> normalise("…we must cultivate our garden...")
      "we must cultivate our garden"

      iex> normalise("I came … I conquered")
      "i came … i conquered"

  An interior ellipsis is one word break however it is spaced or typed:

      iex> normalise("I came...I conquered") == normalise("I came … I conquered")
      true

  Apostrophes go, every other mark is a word break:

      iex> normalise("Don’t tread on me!")
      "dont tread on me"

      iex> normalise("yes,no") == normalise("yes, no")
      true

  Whitespace:

      iex> normalise("  we   must\\ncultivate\\tour garden ")
      "we must cultivate our garden"

  And what is never normalised — the words themselves:

      iex> normalise("cultivate our garden") == normalise("cultivate one's garden")
      false

      iex> normalise("50% of the time")
      "50% of the time"
  """
  def normalise(text) when is_binary(text) do
    text
    |> :unicode.characters_to_nfc_binary()
    |> String.downcase()
    |> String.replace(@single, "'")
    |> String.replace(@double, "\"")
    |> String.replace(@dashes, "-")
    |> String.replace("...", "…")
    |> drop_edge_ellipses()
    |> String.replace("…", " … ")
    |> String.replace("'", "")
    |> String.replace(~r/(?![…%&#])\p{P}/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # Repeated because "... …" is still a leading ellipsis once the first goes.
  defp drop_edge_ellipses(text) do
    case String.replace(text, @edge_ellipsis, "") do
      ^text -> text
      shorter -> drop_edge_ellipses(shorter)
    end
  end

  @doc """
  The fingerprint: SHA-256 of the normalised line, lower-case hex, 64
  characters. `nil` for a line with no words left after normalising, which has
  nothing to be the identity of.

      iex> fingerprint("We must cultivate our garden.") ==
      ...>   fingerprint("we must cultivate our garden")
      true

  Pinned, because a fingerprint that changes is every held quotation losing
  its identity (see *Stability*):

      iex> fingerprint("We must cultivate our garden.")
      "f8e68626ace0acdef6bccbff96460aef764fa964f9f9380df059d850382fc789"

      iex> fingerprint("…")
      nil
  """
  def fingerprint(text) when is_binary(text) do
    case normalise(text) do
      "" -> nil
      normalised -> :crypto.hash(:sha256, normalised) |> Base.encode16(case: :lower)
    end
  end

  def fingerprint(_text), do: nil

  @doc """
  The identifier a quote provider puts in an entry's `identifiers`, beside its
  own id, or `nil` when the line has no words. Not the stable identifier: the
  provider's own id stays that, so a provider correcting a typo keeps its item.

      iex> %{namespace: "quotation_fingerprint", external_id: id} =
      ...>   identifier("We must cultivate our garden.")
      iex> byte_size(id)
      64
  """
  def identifier(text) do
    case fingerprint(text) do
      nil ->
        nil

      external_id ->
        %{
          namespace: @namespace,
          external_id: external_id,
          metadata: %{"normalisation_version" => @version}
        }
    end
  end
end
