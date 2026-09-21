defmodule DevilsDictionary.Discovery.Provider.HelpersTest do
  @moduledoc """
  The kit every provider imports (#144 Phase 1).

  The cases that matter most are the last two describes: the attestation gate
  existed three times, byte-identical, and two of its copies named the third as
  their authority. A shared rule with no shared code agrees until it does not,
  and nothing in the suite would have noticed when it stopped.
  """

  use ExUnit.Case, async: true

  import DevilsDictionary.Discovery.Provider.Helpers

  alias DevilsDictionary.Discovery.Provider.Helpers
  alias DevilsDictionary.Discovery.Providers.{BingNews, OpenLibrary, Poetrydb}

  describe "presence/1 and present?/1" do
    test "an empty value, whitespace and a non-string are all nothing" do
      assert presence("war") == "war"
      assert presence("  war  ") == "war"
      assert presence("   ") == nil
      assert presence("") == nil
      assert presence(nil) == nil
      assert presence(42) == nil

      assert present?("war")
      refute present?("   ")
      refute present?(nil)
    end
  end

  describe "headers/0" do
    test "is the shared user-agent and nothing else" do
      assert headers() == [
               {"user-agent", Application.fetch_env!(:devils_dictionary, :user_agent)}
             ]
    end
  end

  describe "interval/3" do
    test "reads a non-negative override and falls back to the provider's default" do
      assert interval([request_interval_ms: 500], :request_interval_ms, 3_000) == 500
      assert interval([request_interval_ms: 0], :request_interval_ms, 3_000) == 0

      # A half-read override is a rate nobody chose, so the measured default
      # wins over anything the transport could not use.
      assert interval([], :request_interval_ms, 3_000) == 3_000
      assert interval([request_interval_ms: "500"], :request_interval_ms, 3_000) == 3_000
      assert interval([request_interval_ms: -1], :request_interval_ms, 3_000) == 3_000
      assert interval([request_interval_ms: nil], :request_interval_ms, 3_000) == 3_000
    end
  end

  describe "offset/1" do
    test "a cursor is a non-negative offset, and anything else is the first page" do
      assert offset("24") == 24
      assert offset("0") == 0
      assert offset(nil) == 0
      # The clause two of the copies had and the other four did not need:
      # `Integer.parse("")` is already `:error`.
      assert offset("") == 0
      assert offset("-4") == 0
      assert offset("24 ") == 0
      assert offset("twenty") == 0
      assert offset(24) == 0
    end
  end

  describe "limit/2 and limit/3" do
    test "the asked-for size, the default, and the API's ceiling" do
      assert limit(5, 12) == 5
      assert limit(nil, 12) == 12
      assert limit(0, 12) == 12
      assert limit("5", 12) == 12

      assert limit(5, 12, 20) == 5
      assert limit(50, 12, 20) == 20

      # The cap applies to what was asked for and not to the default, exactly
      # as every copy did: a default above the ceiling is the provider's own
      # bug and hiding it here would not help anyone find it.
      assert limit(nil, 30, 20) == 30
    end
  end

  describe "media_url/1" do
    test "an absolute http(s) URL with a host, or nothing" do
      assert media_url("https://example.com/a.jpg") == "https://example.com/a.jpg"
      assert media_url("  http://example.com/a.jpg  ") == "http://example.com/a.jpg"

      # Every one of these reaches an href or a src in the renderer.
      assert media_url("/a.jpg") == nil
      assert media_url("javascript:alert(1)") == nil
      assert media_url("ftp://example.com/a.jpg") == nil
      assert media_url("https:///a.jpg") == nil
      assert media_url(nil) == nil
    end
  end

  describe "clamp_label/1" do
    test "clamps to the column's width, counting graphemes" do
      assert clamp_label("war") == "war"
      assert String.length(clamp_label(String.duplicate("é", 400))) == Helpers.label_limit()
      assert Helpers.label_limit() == 255
      assert clamp_label(nil) == ""
    end
  end

  describe "sparse/1" do
    test "drops nil values and keeps everything else" do
      assert sparse(%{"a" => 1, "b" => nil, "c" => "", "d" => false}) ==
               %{"a" => 1, "c" => "", "d" => false}
    end
  end

  describe "year/1 and iso_year/1" do
    test "a year in free text, bounded to the range a date can be in" do
      assert year("ca. 1863") == "1863"
      assert year("1914–18") == "1914"
      assert year("19th century") == nil
      # A catalogue number is not a date.
      assert year("accession 99231") == nil
      assert year("3099") == nil
      assert year(nil) == nil
    end

    test "the year of an ISO date, and nothing that only looks like one" do
      assert iso_year("2019-06-07") == "2019"
      assert iso_year("2019-06-07T12:00:00Z") == "2019"
      # Anchored and requiring the separator, so it reads a date rather than
      # the first four characters of whatever was in the field.
      assert iso_year("2019") == nil
      assert iso_year("June 2019") == nil
      assert iso_year(nil) == nil
    end
  end

  describe "drop_hidden/1" do
    test "removes display:none elements under either quote character" do
      # The two copies of this differed in exactly this: one accepted `"` only,
      # so the same hidden span was stripped by one provider and shown by the
      # other.
      assert drop_hidden(~s(<p>Real</p><span style="display:none">Hidden</span>)) =~ "Real"
      refute drop_hidden(~s(<p>Real</p><span style="display:none">Hidden</span>)) =~ "Hidden"
      refute drop_hidden(~s(<p>Real</p><span style='display: none'>Hidden</span>)) =~ "Hidden"
    end

    test "keeps going until it settles, because the elements nest" do
      html = ~s(<div style="display:none"><span style="display:none">a</span>b</div>Real)
      assert String.trim(drop_hidden(html)) == "Real"
    end
  end

  describe "word_pattern/1 and whole_word?/2 — the attestation gate" do
    test "a whole word, and never a word that merely contains it" do
      assert whole_word?("the dogs of war", "war")
      assert whole_word?("War is unhealthy", "war")
      assert whole_word?("the war.", "war")

      refute whole_word?("a warehouse", "war")
      refute whole_word?("swarm", "war")
      refute whole_word?("prewar", "war")
    end

    test "the one case where this differs from \\b is the underscore" do
      # All three copies of this carried the same explanation — that `\b`
      # "treats an apostrophe as a boundary and would find *war* inside
      # *war's*". Measured, that is not a difference: an apostrophe and a
      # hyphen are outside `\p{L}\p{N}` just as they are outside `\w`, so
      # both rules match both of these.
      assert whole_word?("war's end", "war")
      assert whole_word?("war-torn", "war")
      assert Regex.match?(~r/\bwar\b/iu, "war's end")

      # Elixir's `u` flag makes `\b` Unicode-aware too, so an accented
      # neighbour is not the difference either. Neither rule matches:
      refute whole_word?("waré", "war")
      refute Regex.match?(~r/\bwar\b/iu, "waré")

      # The underscore is. `\w` includes it and `\p{L}\p{N}` does not, so
      # this is an attestation here and is not under `\b` — the whole of the
      # difference the three copies were choosing, and none of them said so.
      assert whole_word?("war_zone", "war")
      refute Regex.match?(~r/\bwar\b/iu, "war_zone")
    end

    test "a pattern and a term are the same question, asked once or often" do
      pattern = word_pattern("war")

      assert whole_word?("the dogs of war", pattern)
      refute whole_word?("a warehouse", pattern)

      refute whole_word?(nil, "war")
      refute whole_word?("war", nil)
    end

    test "a term with regex syntax in it is a term, not a pattern" do
      assert whole_word?("what is a c++ program", "c++")
      refute whole_word?("what is a cxx program", "c++")
    end
  end

  describe "the three providers that attest agree, because there is one gate" do
    # The issue's own test (#144 Phase 1). Before this, PoetryDB, Open Library
    # and Bing News each held a byte-identical private copy, and two of their
    # moduledocs named PoetryDB's as the authority for the copy they held.
    @lines [
      "A warehouse of forgotten things",
      "and swarming men prewar,",
      "the dogs of war are loosed"
    ]

    test "the same lines give the same verdict, line for line, through three providers" do
      for {line, index} <- Enum.with_index(@lines, 1) do
        kit = whole_word?(line, "war")

        poetry =
          case Poetrydb.first_attestation("war", [line]) do
            {1, _text} -> true
            nil -> false
          end

        library = is_binary(OpenLibrary.first_attestation(word_pattern("war"), [line]))

        bing =
          case BingNews.matched_text("war", %{"title" => line}) do
            {"a headline", _text} -> true
            nil -> false
          end

        assert [poetry, library, bing] == [kit, kit, kit],
               "line #{index} (#{inspect(line)}): the kit says #{kit}, PoetryDB #{poetry}, " <>
                 "Open Library #{library}, Bing #{bing}"
      end

      # And the third line is the one that has to be true, or the test above
      # would pass on three providers that all match nothing.
      assert whole_word?(Enum.at(@lines, 2), "war")
    end

    test "Open Library strips its own match markers before asking the gate" do
      # `{{{…}}}` sits inside a longer word when OCR or a hyphenated line break
      # put it there, and the markers are removed before the test so the gate
      # judges the word it is actually part of rather than the source's say-so.
      refute OpenLibrary.first_attestation(word_pattern("war"), ["a {{{war}}}ehouse"])
      assert OpenLibrary.first_attestation(word_pattern("war"), ["the dogs of {{{war}}}"])
    end
  end
end
