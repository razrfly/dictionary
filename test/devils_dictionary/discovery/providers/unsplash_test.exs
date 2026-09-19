defmodule DevilsDictionary.Discovery.Providers.UnsplashTest do
  @moduledoc """
  The three readings the conformance fixture cannot cover: the title an
  Unsplash photo does not have, the UTM parameters the licence requires on
  every link back, and the download trigger — the one call in this provider
  that is not made by the pipeline, and the only place an SSRF guard could
  matter.
  """

  use ExUnit.Case, async: true

  # The refusal path logs a warning per refused URL, on purpose.
  @moduletag :capture_log

  alias DevilsDictionary.Discovery.Providers.Unsplash

  describe "title/1 — the title Unsplash does not publish" do
    test "the photographer's own description wins" do
      assert Unsplash.title(%{
               "description" => "Ruined side-street in Shingal (Sinjar).",
               "alt_description" => "a narrow street lined with rubble"
             }) == "Ruined side-street in Shingal (Sinjar)."
    end

    test "the generated alt text is the fallback, and it is usually all there is" do
      assert Unsplash.title(%{
               "description" => nil,
               "alt_description" => "man in brown and black camouflage uniform holding rifle"
             }) == "man in brown and black camouflage uniform holding rifle"

      assert Unsplash.title(%{"description" => "   ", "alt_description" => "a soldier"}) ==
               "a soldier"
    end

    test "an item with neither has nothing a card could print" do
      assert Unsplash.title(%{"description" => nil, "alt_description" => nil}) == nil
      assert Unsplash.title(%{}) == nil
      assert Unsplash.title(nil) == nil
    end

    test "whitespace inside a description is collapsed, and the line is clamped" do
      # Real: two ids on one page of *soldier* share this description, trailing
      # tab included, which is what the provider's upload fold reads.
      assert Unsplash.title(%{"description" => "special forces soldier police\t"}) ==
               "special forces soldier police"

      assert Unsplash.title(%{"description" => String.duplicate("a", 400)})
             |> String.length() == 255
    end
  end

  describe "the licence's links" do
    test "the licence URL carries the referral parameters the guidelines require" do
      url = Unsplash.license_url()
      assert String.starts_with?(url, "https://unsplash.com/license?")
      assert url =~ "utm_source=devils_dictionary"
      assert url =~ "utm_medium=referral"
    end
  end

  describe "track_download/2 — the trigger, and the host it may never leave" do
    test "it refuses every URL outside https://api.unsplash.com/photos/" do
      for url <- [
            "https://api.unsplash.com.evil.test/photos/abc/download",
            "https://evil.test/api.unsplash.com/photos/abc/download",
            "http://api.unsplash.com/photos/abc/download",
            "https://api.unsplash.com/users/abc/download",
            "file:///etc/passwd",
            "//api.unsplash.com/photos/abc/download",
            "",
            nil
          ] do
        assert Unsplash.track_download(url) == {:error, :refused},
               "#{inspect(url)} was not refused"
      end

      assert Unsplash.track_download(%{preview_metadata: %{}}) == {:error, :refused}
    end

    test "it calls the endpoint an item persisted, and only that one" do
      test = self()

      plug = fn conn ->
        send(test, {:triggered, conn.request_path})
        Req.Test.json(conn, %{"url" => "https://images.unsplash.com/photo-1"})
      end

      item = %{
        preview_metadata: %{
          "download_location" => "https://api.unsplash.com/photos/LheHIV3XpGM/download?ixid=abc"
        }
      }

      assert Unsplash.track_download(item, plug: plug) == :ok
      assert_received {:triggered, "/photos/LheHIV3XpGM/download"}
    end

    test "a refusal from Unsplash is reported, not swallowed" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 403, "Rate Limit Exceeded") end

      assert Unsplash.track_download(
               "https://api.unsplash.com/photos/abc/download",
               plug: plug
             ) == {:error, 403}
    end
  end

  describe "the shelf's posture" do
    test "a search-only source is plebs-tier (D1) and declines nothing (M6)" do
      assert Unsplash.source_attrs().tier == :plebs
      assert Unsplash.covers?(%{object_id: 1, term: "war", language: "en", relevance: "term"})
    end

    test "it declares the image shelf and nothing else" do
      assert Unsplash.capabilities().content_types == [:image]
    end

    test "it proposes no encyclopedia identity" do
      refute function_exported?(Unsplash, :identity_record, 1)
    end
  end
end
