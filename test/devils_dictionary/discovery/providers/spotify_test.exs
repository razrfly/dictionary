defmodule DevilsDictionary.Discovery.Providers.SpotifyTest do
  @moduledoc """
  The readings the conformance fixture cannot cover.

  The fixture is a real capture, and a real capture is exactly what cannot
  test the shapes the API did not happen to send: over 253 tracks measured on
  2026-09-21 every single one carried an ISRC and all three cover-art rungs,
  and not one carried a `preview_url`. The branches for a track that has none
  of those are here, where a row can be built to lack them — alongside the two
  things that are not a row at all: the token the search rides on, and the
  credential that never leaves this module.

  `retrieve/4` takes its `request_fun`, so these drive the provider without a
  run, a database or a network.
  """

  use ExUnit.Case, async: false

  alias DevilsDictionary.Discovery.MatchReason
  alias DevilsDictionary.Discovery.Providers.Spotify
  alias DevilsDictionary.Discovery.Providers.Spotify.Token
  alias DevilsDictionaryWeb.Culture

  @operation "track_search"
  @mapping %{"term" => "war", "resolution_strategy" => "track_search_v1"}
  @request %{"after" => nil, "first" => 12}

  setup do
    :ok = Token.invalidate()
    on_exit(fn -> Token.invalidate() end)
  end

  describe "whole_word?/2 — the gate" do
    test "keeps a title that uses the word and refuses one that merely starts with it" do
      # Every one of these is a real title Spotify ranked in the first twelve
      # for `q=war` on 2026-09-21.
      assert Spotify.whole_word?("war", "War")
      assert Spotify.whole_word?("war", "War Pigs")
      assert Spotify.whole_word?("war", "War Pigs / Luke's Wall - 2012 - Remaster")
      assert Spotify.whole_word?("war", "War with Us")

      refute Spotify.whole_word?("war", "Warm Safe Place")
      refute Spotify.whole_word?("war", "Warmth")
      refute Spotify.whole_word?("war", "warning signs (interlude)")
      refute Spotify.whole_word?("war", "Warmpop")
      refute Spotify.whole_word?("war", "Work Song")
    end

    test "is case-insensitive and Unicode-aware at the boundary" do
      assert Spotify.whole_word?("logomachy", "LOGOMACHY (ロゴマキア)")
      assert Spotify.whole_word?("love", "LOVE. FEAT. ZACARI.")
      # `\b` would call the apostrophe a boundary and find *war* here.
      refute Spotify.whole_word?("war", "Warden's Song")
      # A word inside another word, with a letter on the left rather than the
      # right: the lookbehind is what refuses it.
      refute Spotify.whole_word?("war", "Prewar")
    end

    test "a term with regex metacharacters is a term and not a pattern" do
      assert Spotify.whole_word?("c++", "c++ (interlude)")
      refute Spotify.whole_word?("c++", "cxx")
      refute Spotify.whole_word?("(", "anything")
      refute Spotify.whole_word?("war", nil)
    end
  end

  describe "artists/1" do
    test "every credited artist, in Spotify's order" do
      assert Spotify.artists(%{
               "artists" => [%{"name" => "ESPRIT 空想"}, %{"name" => "George Clanton"}]
             }) == "ESPRIT 空想, George Clanton"
    end

    test "nothing when there is nobody to name" do
      assert Spotify.artists(%{"artists" => []}) == nil
      assert Spotify.artists(%{}) == nil
      assert Spotify.artists(nil) == nil
    end
  end

  describe "the rows the capture never sent" do
    test "a track with no ISRC carries its own identifier and no second one" do
      {:ok, page} = run([track("no-isrc") |> Map.put("external_ids", %{})])

      assert [item] = page.items
      assert Enum.map(item.identifiers, & &1.namespace) == ["spotify_track"]
    end

    test "an ISRC is upcased, so one recording is one identity whoever sent it" do
      {:ok, page} = run([track("i") |> put_in(["external_ids", "isrc"], "uszeg1500775")])

      assert [_track_id, isrc] = hd(page.items).identifiers
      assert isrc.namespace == "isrc"
      assert isrc.external_id == "USZEG1500775"
    end

    test "an album with no cover art is a card with no picture, not a dropped track" do
      {:ok, page} = run([track("bare") |> put_in(["album", "images"], [])])

      assert [item] = page.items
      refute Map.has_key?(item.preview_metadata, "image_url")
      refute Map.has_key?(item.preview_metadata, "thumbnail_url")
      assert item.preview_metadata["title"] == "War"
    end

    test "the art ladder takes the nearest rung at or above the one asked for" do
      only_large =
        track("large")
        |> put_in(["album", "images"], [
          %{"height" => 640, "url" => "https://i.scdn.co/image/large", "width" => 640}
        ])

      {:ok, page} = run([only_large])
      metadata = hd(page.items).preview_metadata

      # 300 and 64 both fall back to the only rung there is rather than to
      # nothing: a 640 px cover shown at 144 px is a large file, not a broken
      # card.
      assert metadata["image_url"] == "https://i.scdn.co/image/large"
      assert metadata["thumbnail_url"] == "https://i.scdn.co/image/large"
    end

    test "a track with no link back is not shown at all" do
      # The Developer Policy's second obligation is the link, so an item that
      # cannot carry one is not an item. A `javascript:` URL out of a response
      # is the same refusal.
      {:ok, page} = run([track("nolink") |> Map.put("external_urls", %{})])
      assert page.items == []
      assert page.completion_reason == :no_results

      {:ok, page} =
        run([track("js") |> put_in(["external_urls", "spotify"], "javascript:alert(1)")])

      assert page.items == []
    end

    test "a release date of any precision yields the year, and none yields no year" do
      for {release_date, year} <- [{"1970-09-18", "1970"}, {"2001-01", "2001"}, {"1969", "1969"}] do
        {:ok, page} = run([track("y") |> put_in(["album", "release_date"], release_date)])
        assert hd(page.items).preview_metadata["year"] == year
      end

      {:ok, page} = run([track("y") |> put_in(["album", "release_date"], "")])
      refute Map.has_key?(hd(page.items).preview_metadata, "year")
    end

    test "explicit is carried as a fact and gates nothing here" do
      {:ok, page} = run([track("e") |> Map.put("explicit", true)])
      assert hd(page.items).preview_metadata["explicit"] == true

      {:ok, page} = run([track("e") |> Map.put("explicit", false)])
      assert hd(page.items).preview_metadata["explicit"] == false
    end
  end

  describe "what a card is handed" do
    test "the credit is the artist and the mark is the attribution" do
      {:ok, page} = run([track("m")])
      metadata = hd(page.items).preview_metadata

      assert metadata["attribution"] == "Chief Keef"
      assert metadata["creator"] == "Chief Keef"
      assert metadata["creator_url"] == "https://open.spotify.com/artist/15iVAtD3s3FsQR4w1v6M0P"

      # The mark is not on the item any more (#144 followups): one obligation
      # written once on the provider, rather than on every row it ever
      # returns.
      refute Map.has_key?(metadata, "brand_mark")

      assert metadata["source_url"] == "https://open.spotify.com/track/m"
      assert metadata["content_type"] == "music"
    end

    test "the mark is the provider's to declare, whole, and says where it goes" do
      # The renderer matches on no provider's name (promise 9), so a bare
      # `"spotify"` anywhere in this would draw nothing. The Branding
      # Guidelines' own numbers are here and nowhere else: the full logo,
      # black on light and white on dark, at the 70 px minimum, and one of
      # the three link wordings they permit.
      assert Spotify.attribution_mark() == %{
               light: "/images/spotify-full-logo-black.svg",
               dark: "/images/spotify-full-logo-white.svg",
               alt: "Spotify",
               href: nil,
               link_text: "Listen on Spotify",
               width: 70,
               placement: :card
             }

      # #143's brief asked for *Open on Spotify*, which is not one of the
      # three the guidelines permit.
      assert Spotify.attribution_mark().link_text in [
               "Open Spotify",
               "Play on Spotify",
               "Listen on Spotify"
             ]

      # Both files are committed, and both are the SVGs Spotify publishes.
      for path <- ["spotify-full-logo-black.svg", "spotify-full-logo-white.svg"] do
        file = Path.join("priv/static/images", path)
        assert File.exists?(file), "#{path} is not committed"
        assert File.read!(file) =~ "<svg"
      end

      # And the reader reads it: a card mark, drawn under the credit with the
      # wording the licence dictates, on a shelf that knows no provider name.
      assert Culture.mark(Spotify.attribution_mark()) == Spotify.attribution_mark()
    end

    test "the reason is a labelled search result on a row that admits one" do
      {:ok, page} = run([track("r")])

      assert [reason] = MatchReason.from_result(hd(page.items).match_details, "war")
      assert MatchReason.evidence(reason) == :query

      assert MatchReason.describe(
               reason,
               DevilsDictionary.Discovery.ContentTypes.evidence(:music)
             ) ==
               "Search result for “war”, ranked by the provider and not matched on an identifier."
    end
  end

  describe "the token" do
    test "one token serves several searches, and is a request only once" do
      {:ok, _page} = run([track("a")])
      {:ok, _page} = run([track("b")], invalidate: false)

      assert stages() == ["token", @operation, @operation]
    end

    test "a 401 drops the cached token, mints another and retries the search once" do
      {:ok, agent} = Agent.start_link(fn -> %{stages: [], searches: 0} end)

      request_fun = fn
        "token", _payload ->
          Agent.update(agent, &%{&1 | stages: &1.stages ++ ["token"]})

          {:ok,
           %{"access_token" => "t#{length(Agent.get(agent, & &1.stages))}", "expires_in" => 3600}}

        @operation, _payload ->
          searches =
            Agent.get_and_update(
              agent,
              &{&1.searches + 1,
               %{&1 | searches: &1.searches + 1, stages: &1.stages ++ [@operation]}}
            )

          if searches == 1,
            do: {:error, "authentication_failed"},
            else: {:ok, %{"tracks" => %{"items" => [track("after-401")]}}}
      end

      assert {:ok, page} = Spotify.retrieve(@operation, @mapping, @request, request_fun)
      assert Enum.map(page.items, & &1.external_id) == ["after-401"]

      # Two tokens and two searches: the second token is the point, and there
      # is no third search, because a retry that could loop is not a retry.
      assert Agent.get(agent, & &1.stages) == ["token", @operation, "token", @operation]
    end

    test "a second 401 is a failure and not a second retry" do
      request_fun = fn
        "token", _payload -> {:ok, %{"access_token" => "t", "expires_in" => 3600}}
        @operation, _payload -> {:error, "authentication_failed"}
      end

      assert Spotify.retrieve(@operation, @mapping, @request, request_fun) ==
               {:error, "authentication_failed"}
    end

    test "a token response that is not the documented envelope is a malformed response" do
      for body <- [
            %{},
            %{"access_token" => ""},
            %{"access_token" => "t"},
            %{"expires_in" => 3600}
          ] do
        request_fun = fn "token", _payload -> {:ok, body} end

        assert Spotify.retrieve(@operation, @mapping, @request, request_fun) ==
                 {:error, "malformed_response"}
      end
    end

    test "a deferred token defers the run rather than searching without one" do
      request_fun = fn "token", _payload -> {:deferred, "request_budget", 42} end

      assert {:deferred, "request_budget", 42, @request} =
               Spotify.retrieve(@operation, @mapping, @request, request_fun)
    end

    test "a token inside the refresh window is not handed out" do
      :ok = Token.put("nearly-expired", Token.refresh_window_seconds() - 1)
      assert Token.peek() == nil

      :ok = Token.put("good-for-an-hour", 3600)
      assert Token.peek() == "good-for-an-hour"

      :ok = Token.invalidate()
      assert Token.peek() == nil
    end

    test "invalidating a stale token leaves a newer one alone" do
      # Two runs `401` on the same token. The first refreshes; the second's
      # invalidation names the token *it* used, and must not clear what the
      # first just stored — or the first's retry goes out with no bearer.
      :ok = Token.put("stale", 3600)
      :ok = Token.invalidate("stale")
      assert Token.peek() == nil

      :ok = Token.put("fresh", 3600)
      :ok = Token.invalidate("stale")
      assert Token.peek() == "fresh"

      :ok = Token.invalidate("fresh")
      assert Token.peek() == nil
    end
  end

  describe "the credential" do
    test "the token request carries it and the search never does" do
      original = Application.get_env(:devils_dictionary, :spotify, [])
      on_exit(fn -> Application.put_env(:devils_dictionary, :spotify, original) end)

      Application.put_env(
        :devils_dictionary,
        :spotify,
        Keyword.merge(Application.get_env(:devils_dictionary, :spotify, []),
          client_id: "an-id",
          client_secret: "a-secret"
        )
      )

      token_options = Spotify.request_options(%{"grant" => "client_credentials"})
      assert token_options[:method] == :post
      assert token_options[:form] == [grant_type: "client_credentials"]

      assert {"authorization", "Basic " <> encoded} =
               List.keyfind(token_options[:headers], "authorization", 0)

      assert Base.decode64!(encoded) == "an-id:a-secret"

      :ok = Token.put("a-token", 3600)

      search_options =
        Spotify.request_options(%{"term" => "war", "offset" => "0", "limit" => "50"})

      assert {"authorization", "Bearer a-token"} =
               List.keyfind(search_options[:headers], "authorization", 0)

      # Not in the URL, not in the parameters, not anywhere but that one header.
      refute inspect(search_options[:params]) =~ "a-secret"
      refute inspect(search_options[:url]) =~ "a-secret"
    end

    test "the run's own parameters record the shape of the request and none of the credential" do
      {:ok, page} = run([track("p"), track("q") |> Map.put("name", "Warmpop")])

      assert page.request_parameters["market"] == "US"
      assert page.request_parameters["scanned"] == 2
      assert page.request_parameters["kept"] == 1
      refute inspect(page.request_parameters) =~ "secret"
    end
  end

  describe "enabled?/0" do
    test "false without both halves of the credential, true with them" do
      original = Application.get_env(:devils_dictionary, :spotify, [])
      on_exit(fn -> Application.put_env(:devils_dictionary, :spotify, original) end)

      for missing <- [
            [client_id: nil, client_secret: "s"],
            [client_id: "i", client_secret: nil],
            [client_id: "", client_secret: "s"],
            [client_id: "i", client_secret: "  "],
            [client_id: "i", client_secret: "s", enabled: false],
            [client_id: "i", client_secret: "s", token_endpoint: nil]
          ] do
        Application.put_env(:devils_dictionary, :spotify, Keyword.merge(original, missing))
        refute Spotify.enabled?()
      end

      Application.put_env(
        :devils_dictionary,
        :spotify,
        Keyword.merge(original, client_id: "i", client_secret: "s")
      )

      assert Spotify.enabled?()
    end
  end

  # ---------------------------------------------------------------------------

  # One `retrieve/4` against a stubbed transport, recording the stages it asked
  # for so the token can be counted.
  defp run(rows, opts \\ []) do
    if Keyword.get(opts, :invalidate, true), do: Token.invalidate()
    Process.put(:stages, Process.get(:stages, []))

    request_fun = fn
      "token", _payload ->
        Process.put(:stages, Process.get(:stages, []) ++ ["token"])
        {:ok, %{"access_token" => "a-token", "token_type" => "Bearer", "expires_in" => 3600}}

      @operation, _payload ->
        Process.put(:stages, Process.get(:stages, []) ++ [@operation])
        {:ok, %{"tracks" => %{"items" => rows}}}
    end

    Spotify.retrieve(@operation, @mapping, @request, request_fun)
  end

  defp stages, do: Process.get(:stages, [])

  # The Chief Keef row as captured, with the id swapped so a test can hold
  # several of them.
  defp track(id) do
    %{
      "album" => %{
        "album_type" => "album",
        "external_urls" => %{
          "spotify" => "https://open.spotify.com/album/7dcvmDePKdSLOCnDqwU1PR"
        },
        "id" => "7dcvmDePKdSLOCnDqwU1PR",
        "images" => [
          %{
            "height" => 640,
            "url" => "https://i.scdn.co/image/ab67616d0000b2737c8dc388095e6fe23f93df50",
            "width" => 640
          },
          %{
            "height" => 300,
            "url" => "https://i.scdn.co/image/ab67616d00001e027c8dc388095e6fe23f93df50",
            "width" => 300
          },
          %{
            "height" => 64,
            "url" => "https://i.scdn.co/image/ab67616d000048517c8dc388095e6fe23f93df50",
            "width" => 64
          }
        ],
        "name" => "The Leek (Vol. 1)",
        "release_date" => "2015-06-16",
        "release_date_precision" => "day"
      },
      "artists" => [
        %{
          "external_urls" => %{
            "spotify" => "https://open.spotify.com/artist/15iVAtD3s3FsQR4w1v6M0P"
          },
          "id" => "15iVAtD3s3FsQR4w1v6M0P",
          "name" => "Chief Keef"
        }
      ],
      "explicit" => true,
      "external_ids" => %{"isrc" => "USZEG1500775"},
      "external_urls" => %{"spotify" => "https://open.spotify.com/track/#{id}"},
      "id" => id,
      "name" => "War",
      "popularity" => 62,
      "preview_url" => nil,
      "type" => "track"
    }
  end
end
