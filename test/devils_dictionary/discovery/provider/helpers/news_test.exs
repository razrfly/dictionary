defmodule DevilsDictionary.Discovery.Provider.Helpers.NewsTest do
  @moduledoc """
  One article, one identity — the rule that makes a `:news` shelf dedup (#144
  Phase 1).

  These cases were `BingNews`'s, and so was the code: `normalize/1` and
  `article_id/1` were public, `@doc`'d and called by nobody else, and #142's
  plan was for the Guardian to call them. A second provider depending on the
  first for a rule that belongs to the shelf is the shape Phase 1 removes, so
  the rule moved to the kit before the second caller arrived — and these cases
  moved with it.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Discovery.Provider.Helpers.News

  @wired_url "https://www.wired.com/story/the-fbi-doubles-down-on-easing-bestiality-hiring-standards/"

  describe "normalize/1 and article_id/1 — one article, one identity" do
    test "scheme and host are lowercased and the fragment is dropped" do
      assert News.normalize(URI.parse("HTTPS://WWW.Wired.COM/story/x/#comments")) ==
               "https://www.wired.com/story/x/"
    end

    test "tracking parameters are stripped and what is left is sorted" do
      assert News.normalize(
               URI.parse("https://www.theguardian.com/x?utm_source=t&b=2&fbclid=9&a=1&CMP=share")
             ) == "https://www.theguardian.com/x?a=1&b=2"
    end

    test "a URL whose only parameters were tracking loses its query entirely" do
      assert News.normalize(URI.parse("https://example.com/x?utm_medium=social&smid=tw")) ==
               "https://example.com/x"
    end

    test "the same article reached two ways is one id" do
      plain = News.article_id(News.normalize(URI.parse(@wired_url)))

      decorated =
        News.article_id(
          News.normalize(URI.parse(@wired_url <> "?utm_source=twitter&fbclid=IwAR9#top"))
        )

      assert plain == decorated

      # And the redirect is not the identity. Bing's `apiclick` link carries a
      # per-response `tid`, so hashing it would make the same article a new
      # item on every fetch.
      refute plain == News.article_id("http://www.bing.com/news/apiclick.aspx?tid=6ab14198")
    end

    test "different articles are different ids" do
      refute News.article_id("https://example.com/a") ==
               News.article_id("https://example.com/b")
    end
  end
end
