defmodule DevilsDictionary.Discovery.Conformance.SpotifyFixture do
  @moduledoc """
  Conformance for `DevilsDictionary.Discovery.Providers.Spotify`.

  The rows here are **real**, captured on 2026-09-21 from
  `GET https://api.spotify.com/v1/search?q=war&type=track&market=US&limit=12`
  and carried in the envelope Spotify sent them in — every id, name, artist,
  album, album type, release date, ISRC, cover-art hash and
  `open.spotify.com` link is that response's own. The only sanitisation is the
  access token, which is a literal rather than the one the probe was issued.

  Two endpoints on one `.test` host, because that is what this provider needs
  and what `config/test.exs` points it at: the stub answers the token request
  at `/api/token` and the search at `/v1/search` from the same plug, so the
  pair is captured, stubbed and asserted together.

  ## The six rows that are not in the expected ids

  Half of what Spotify ranked first for *war* does not contain the word:
  *Warm Safe Place*, *Warmth*, *warning signs (interlude)*, *Warmpop*, *warm*
  and — ranked seventh — *Work Song*, which has neither the word nor a prefix
  of it. They are in these responses for the same reason the Telegraph's 2023
  article is in Bing's: the gate is the product, and a fixture holding only
  rows the gate keeps would assert nothing about it. A provider that stopped
  gating would fail here rather than shipping *Warmpop* under a heading that
  says the word.

  `:empty` is that measurement taken to its end — those six noise rows and
  nothing else. It is the honest empty for this provider and the shape the
  real API produces: Spotify does not answer *nothing*, it answers something
  that is not the word, and the run is `no_results` because the gate refused
  all of it rather than because the catalogue was silent.

  ## Two things the capture settles rather than assumes

  Over 253 tracks captured across twelve searches on 2026-09-21: **every one**
  carried an `external_ids.isrc` and all three cover-art rungs, and **not one**
  carried a `preview_url`. So the ISRC identifier is written on every row here
  and `preview_url` is `nil` on every row here, and the branches for a track
  that has neither are exercised in
  `test/devils_dictionary/discovery/providers/spotify_test.exs`, where a row
  can be constructed to lack them.

  The external ids are Spotify's own, written as literals, so that changing
  what identifies a track fails this suite instead of agreeing with itself.
  """

  use DevilsDictionary.Discovery.Conformance.Fixture

  alias DevilsDictionary.Discovery.Providers.Spotify
  alias DevilsDictionary.Discovery.Providers.Spotify.Token

  @chief_keef "2xnXIv68ECjDeDpaZloULO"
  @edwin_starr "4BpPvEi38kvfLKA1qBBX5J"
  @war_pigs "0HVQuuXGAcQ2P5mBN521ae"
  @war_with_us "627Ue4WpTs3P9DumoK3BVx"
  @lukes_wall "2rd9ETlulTbz6BYZcdvIE1"
  @warm_safe_place "7hLNrNAh3TsLW31yJ81bPk"
  @warmth "5tcpY8RPLxJ9X7O5AFFZLQ"
  @warning_signs "0cJRr7kw5FkV5e8ejEB2j6"
  @warmpop "0Ubp7kMZ6MWZIL8qkloYub"
  @warm "0BeR2fJmYnKNn7IORw3GR9"
  @work_song "5TgEJ62DOzBpGxZ7WRsrqb"

  # Not a real token. The probe's is 140 characters of base64, it is not in
  # this repository, and the provider only ever compares one to `nil`.
  @access_token "conformance-access-token"

  @impl true
  def provider, do: Spotify

  @impl true
  def covered_target(context) do
    word = word!(context, "war", ~w(wordnet))

    %{
      object_id: word.object_id,
      term: word.lemma,
      language: word.language_tag,
      relevance: "term"
    }
  end

  @impl true
  def stub(:empty, _context) do
    respond(noise())
    %{pages: [[]]}
  end

  def stub(:results, _context) do
    # Five rows against a `result_limit` of three, of which two survive the
    # gate: a short page, so pagination ends rather than promising a page
    # with nothing behind it.
    respond([chief_keef(), warm_safe_place(), edwin_starr(), warmth(), work_song()])

    %{pages: [[@chief_keef, @edwin_starr]]}
  end

  def stub(:paged, _context) do
    # Eight rows, of which five survive: a first page of three that hands
    # back a cursor, and a second of two that does not.
    respond([
      chief_keef(),
      warm_safe_place(),
      edwin_starr(),
      warmth(),
      war_pigs(),
      warmpop(),
      war_with_us(),
      lukes_wall()
    ])

    %{pages: [[@chief_keef, @edwin_starr, @war_pigs], [@war_with_us, @lukes_wall]]}
  end

  # The token cache outlives one test — it is a supervised process, not a
  # sandboxed connection — so every scenario starts it cold. Each case then
  # spends its own `stage: "token"` request and the ledger it asserts against
  # is its own.
  defp respond(rows) do
    :ok = Token.invalidate()

    Req.Test.stub(Spotify, fn conn ->
      case conn.request_path do
        "/api/token" ->
          Req.Test.json(conn, %{
            "access_token" => @access_token,
            "token_type" => "Bearer",
            "expires_in" => 3600
          })

        _search ->
          conn = Plug.Conn.fetch_query_params(conn)
          limit = String.to_integer(conn.params["limit"] || "50")
          offset = String.to_integer(conn.params["offset"] || "0")

          Req.Test.json(
            conn,
            search(Enum.slice(rows, offset, limit), offset, limit, length(rows))
          )
      end
    end)
  end

  # The search envelope, as captured: the page sits under `tracks`, beside the
  # window it was asked for and a `total` that is the catalogue's and not the
  # page's.
  defp search(rows, offset, limit, total) do
    %{
      "tracks" => %{
        "href" => "https://api.spotify.com/v1/search?query=war&type=track&market=US",
        "items" => rows,
        "limit" => limit,
        "next" => nil,
        "offset" => offset,
        "previous" => nil,
        "total" => total
      }
    }
  end

  # ---------------------------------------------------------------------------
  # The real rows the gate keeps
  # ---------------------------------------------------------------------------

  defp chief_keef do
    track(
      @chief_keef,
      "War",
      [{"Chief Keef", "15iVAtD3s3FsQR4w1v6M0P"}],
      album(
        "The Leek (Vol. 1)",
        "7dcvmDePKdSLOCnDqwU1PR",
        "album",
        "2015-06-16",
        "7c8dc388095e6fe23f93df50"
      ),
      "USZEG1500775",
      true
    )
  end

  defp edwin_starr do
    track(
      @edwin_starr,
      "War",
      [{"Edwin Starr", "1B8AXU6gIIafpyLEpbcv1u"}],
      album(
        "20th Century Masters: The Millennium Collection: Best of Edwin Starr",
        "55cjUGXiql30OISk54Y3Z1",
        "compilation",
        "2001-01-01",
        "4f1dc87f3fafc7d3ff962903"
      ),
      "USMO10111226",
      false
    )
  end

  defp war_pigs do
    track(
      @war_pigs,
      "War Pigs",
      [{"Black Sabbath", "5M52tdBnJaKSvOpJGz8mfZ"}],
      album(
        "The Ultimate Collection",
        "6TcPqftScGmR0aEgIb43Vv",
        "compilation",
        "2017-02-03",
        "012d727b175d4a91c792fb4c"
      ),
      "GBAJE7000063",
      false
    )
  end

  defp war_with_us do
    track(
      @war_with_us,
      "War with Us",
      [{"YoungBoy Never Broke Again", "7wlFDEWiM5OoIAt8RSli8b"}],
      album(
        "Ain't Too Long",
        "6x8UUVU226h0RB4ewfdqWQ",
        "album",
        "2017-07-31",
        "fd8c54e9a74ec08c5e0e2e1d"
      ),
      "USAT21705365",
      true
    )
  end

  defp lukes_wall do
    track(
      @lukes_wall,
      "War Pigs / Luke's Wall - 2012 - Remaster",
      [{"Black Sabbath", "5M52tdBnJaKSvOpJGz8mfZ"}],
      album(
        "Paranoid (Remaster)",
        "6r7LZXAVueS5DqdrvXJJK7",
        "album",
        "1970-09-18",
        "d5fccf9ce08b6a1e7d12a222"
      ),
      "USWB11304627",
      false
    )
  end

  # ---------------------------------------------------------------------------
  # The real rows the gate refuses — all six, ranked among the ones above
  # ---------------------------------------------------------------------------

  defp noise, do: [warm_safe_place(), warmth(), warning_signs(), warmpop(), warm(), work_song()]

  defp warm_safe_place do
    track(
      @warm_safe_place,
      "Warm Safe Place",
      [{"Staind", "5KDIH2gF0VpelTqyQS7udb"}],
      album(
        "Break the Cycle",
        "0OwSOrPWyP9batKOhOnaPt",
        "album",
        "2001-08-20",
        "8d148a015881b0f52cb9f99b"
      ),
      "USEE10100307",
      false
    )
  end

  defp warmth do
    track(
      @warmth,
      "Warmth",
      [{"C418", "4uFZsG1vXrPcvnZ4iSQyrx"}],
      album(
        "Minecraft - Volume Beta",
        "0cJydohrKIIwzRLJqZUfxK",
        "album",
        "2013-11-09",
        "c918a500a7d16e0cc57bc068"
      ),
      "TCABR1368234",
      false
    )
  end

  defp warning_signs do
    track(
      @warning_signs,
      "warning signs (interlude)",
      [{"Ariana Grande", "66CXWjxzNUsdJxJ2JdwvnR"}],
      album("petal", "2k4FmEtXR0WiDW0Ac2QArT", "album", "2026-07-31", "8baf677ee2d8dda6cc9fcbd7"),
      "USUM72602118",
      false
    )
  end

  defp warmpop do
    track(
      @warmpop,
      "Warmpop",
      [{"ESPRIT 空想", "6eDKMXn3OBIkI8jcY7JtlI"}, {"George Clanton", "1G5v3lpMz7TeoW0yGpRQHr"}],
      album(
        "200% Electronica",
        "6WgSCcRfaXuBVfM2TpV0Kl",
        "album",
        "2017-11-17",
        "9bf7d13db51dfd26eb1e49b0"
      ),
      "FRIDO1710384",
      false
    )
  end

  defp warm do
    track(
      @warm,
      "warm",
      [{"Ariana Grande", "66CXWjxzNUsdJxJ2JdwvnR"}],
      album(
        "eternal sunshine deluxe: brighter days ahead",
        "6cbwstHlsAIIWurIIXXBPd",
        "album",
        "2025-03-28",
        "5ab3c842fde848df7a4ee6d9"
      ),
      "USUM72501916",
      false
    )
  end

  defp work_song do
    track(
      @work_song,
      "Work Song",
      [{"Hozier", "2FXC3k01G6Gw61bmprjgqS"}],
      album(
        "Hozier (Expanded Edition)",
        "4Pv7m8D82A1Xun7xNCKZjJ",
        "album",
        "2014-09-19",
        "bd5c6f1a9461fc68c5dc1623"
      ),
      "USSM11401475",
      false
    )
  end

  # One track in the envelope Spotify sends it in, down to `preview_url`.
  defp track(id, name, artists, album, isrc, explicit?) do
    %{
      "album" => album,
      "artists" => Enum.map(artists, &artist/1),
      "disc_number" => 1,
      "duration_ms" => 198_844,
      "explicit" => explicit?,
      "external_ids" => %{"isrc" => isrc},
      "external_urls" => %{"spotify" => "https://open.spotify.com/track/#{id}"},
      "href" => "https://api.spotify.com/v1/tracks/#{id}",
      "id" => id,
      "is_local" => false,
      "is_playable" => true,
      "name" => name,
      "popularity" => 62,
      "preview_url" => nil,
      "track_number" => 1,
      "type" => "track",
      "uri" => "spotify:track:#{id}"
    }
  end

  # The three cover-art rungs share one 24-character hash and differ only in
  # the size prefix — measured on all 253 captured tracks, none of which was
  # missing a rung.
  defp album(name, id, type, release_date, art) do
    %{
      "album_type" => type,
      "external_urls" => %{"spotify" => "https://open.spotify.com/album/#{id}"},
      "href" => "https://api.spotify.com/v1/albums/#{id}",
      "id" => id,
      "images" => [
        %{
          "height" => 640,
          "url" => "https://i.scdn.co/image/ab67616d0000b273#{art}",
          "width" => 640
        },
        %{
          "height" => 300,
          "url" => "https://i.scdn.co/image/ab67616d00001e02#{art}",
          "width" => 300
        },
        %{
          "height" => 64,
          "url" => "https://i.scdn.co/image/ab67616d00004851#{art}",
          "width" => 64
        }
      ],
      "is_playable" => true,
      "name" => name,
      "release_date" => release_date,
      "release_date_precision" => "day",
      "type" => "album",
      "uri" => "spotify:album:#{id}"
    }
  end

  defp artist({name, id}) do
    %{
      "external_urls" => %{"spotify" => "https://open.spotify.com/artist/#{id}"},
      "href" => "https://api.spotify.com/v1/artists/#{id}",
      "id" => id,
      "name" => name,
      "type" => "artist",
      "uri" => "spotify:artist:#{id}"
    }
  end
end
