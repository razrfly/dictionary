defmodule DevilsDictionary.Routing.SitemapsTest do
  @moduledoc """
  `Routing.Sitemaps` (#237 C5): the split at Google's limits, 50,000 URLs or
  50 MB uncompressed, whichever comes first, unit-tested at small limits;
  and `lastmod`, which is when the page's content last changed (an article
  about its subject, or its own revision), or when it was published, and
  never what an audit run writes.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.OnFixtures
  import DevilsDictionary.RoutingFixtures, only: [human!: 0, classify!: 3]
  import DevilsDictionary.WordFixtures, only: [entry!: 4]
  import Ecto.Query

  alias DevilsDictionary.{Fixtures, Registry}
  alias DevilsDictionary.Registry.Entity
  alias DevilsDictionary.Routing.{ClassificationDecision, PagePublication, Sitemaps}

  defp url(n) do
    xml = "  <url><loc>https://wordhoard.test/people/p#{n}</loc></url>\n"
    {%{path: "/people/p#{n}", lastmod: nil}, xml}
  end

  test "a sitemap is split at the URL count or the byte size, whichever comes first" do
    assert Sitemaps.limits() == %{urls: 50_000, bytes: 50 * 1024 * 1024}
    assert Sitemaps.chunk([]) == []

    urls = Enum.map(1..5, &url/1)
    size = byte_size(elem(hd(urls), 1))

    assert [five] = Sitemaps.chunk(urls)
    assert length(five) == 5

    assert Enum.map(Sitemaps.chunk(urls, urls: 2), &length/1) == [2, 2, 1]
    assert Enum.map(Sitemaps.chunk(urls, urls: 1), &length/1) == [1, 1, 1, 1, 1]

    # Exactly three fit with the envelope; a fourth would go over.
    assert Enum.map(Sitemaps.chunk(urls, bytes: Sitemaps.envelope() + 3 * size), &length/1) ==
             [3, 2]

    assert Enum.map(
             Sitemaps.chunk(urls, bytes: Sitemaps.envelope() + 3 * size + size - 1),
             &length/1
           ) ==
             [3, 2]

    # Whichever comes first: the count at 2 before the bytes at 3, and the
    # bytes at 3 before the count at 4.
    assert Enum.map(
             Sitemaps.chunk(urls, urls: 2, bytes: Sitemaps.envelope() + 3 * size),
             &length/1
           ) == [2, 2, 1]

    assert Enum.map(
             Sitemaps.chunk(urls, urls: 4, bytes: Sitemaps.envelope() + 3 * size),
             &length/1
           ) == [3, 2]

    # A URL too big for an empty sitemap still goes in one of its own.
    assert Enum.map(Sitemaps.chunk(urls, bytes: 1), &length/1) == [1, 1, 1, 1, 1]

    # Order is kept.
    assert urls |> Sitemaps.chunk(urls: 2) |> List.flatten() == urls
  end

  defp w3c(%NaiveDateTime{} = at),
    do: at |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601() |> Kernel.<>("Z")

  defp w3c(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  test "lastmod is the content's change or the publication; never an audit run's" do
    %{sources: sources} = Fixtures.seed_catalog!()
    ctx = %{sources: sources}
    human = human!()

    voltaire =
      subject!("Voltaire", "people",
        kind: :person,
        path: "/people/voltaire",
        published: true,
        actor: human
      )

    id = voltaire.entity.object_id

    # Nothing dates the content: when it was published.
    published_at =
      Repo.one!(
        from r in PagePublication,
          where: r.page_id == ^voltaire.page.id and r.action == :publish,
          select: r.committed_at
      )

    assert Sitemaps.lastmod(voltaire.page.id) == w3c(published_at)

    # An article about the subject: its current revision.
    content = entry!(ctx, voltaire.entity, "wikipedia", body: "Voltaire was a writer.")
    revision = Registry.current_content_revision(content.object_id)
    assert Sitemaps.lastmod(voltaire.page.id) == w3c(revision.inserted_at)

    # What an audit run writes, a decision and a touched entity row, is not
    # a content change.
    decisions = Repo.aggregate(ClassificationDecision, :count)
    classify!(id, "people", revision: 2)
    assert Repo.aggregate(ClassificationDecision, :count) == decisions + 1

    Repo.update_all(from(e in Entity, where: e.object_id == ^id),
      set: [updated_at: DateTime.add(DateTime.utc_now(), 3600, :second)]
    )

    assert Sitemaps.lastmod(voltaire.page.id) == w3c(revision.inserted_at)

    assert Sitemaps.lastmod(nil) == nil
    assert Sitemaps.lastmod(999_999_999) == nil
  end
end
