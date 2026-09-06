defmodule DevilsDictionaryWeb.PageController do
  use DevilsDictionaryWeb, :controller

  # A plain index of what exists. #71's U2 replaces this with HomeLive: search,
  # Surprise me, and the seed words.
  @surfaces [
    %{
      title: "Animals",
      path: "/s/animals",
      body: "The scope: every word in it, who attests it, and where it sits in the taxonomy."
    },
    %{
      title: "Health",
      path: "/health",
      body: "The scorecard from #69 §7, computed, plus coverage, links and parity underneath."
    },
    %{
      title: "Imports",
      path: "/admin/imports",
      body: "Per source: records fetched, absent markers, what still needs materializing."
    },
    %{
      title: "Sources",
      path: "/sources/bierce",
      body: "One page per source: tier, licence, snapshot pin, counts, coverage, samples."
    }
  ]

  def home(conn, _params) do
    # No page_title: `<.live_title>`'s default is the wordmark, and setting it
    # here would render "wordhoard · wordhoard".
    conn
    |> assign(:surfaces, @surfaces)
    |> render(:home)
  end
end
