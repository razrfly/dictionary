defmodule Reader82AuditTest do
  use DevilsDictionaryWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias DevilsDictionary.{Claims, Registry}
  alias DevilsDictionary.Claims.Connection
  setup do
    DevilsDictionary.Fixtures.seed_catalog!()
    {:ok, author} = Registry.create_person(%{preferred_label: "Audit author"})
    {:ok, work} = Registry.create_work(%{preferred_label: "Audit book"})
    {:ok, edition} = Registry.create_edition(%{preferred_label: "Audit edition", work_id: work.object_id})
    {:ok, _} = Claims.assert(work.object_id, "authored_by", author.object_id)
    {:ok, _} = Claims.assert(edition.object_id, "edition_of", work.object_id)
    %{author: author, work: work, edition: edition}
  end
  test "work retains a navigable author after removing duplicated edges", ctx do
    {:ok, view, _} = live(ctx.conn, "/entities/#{ctx.work.object_id}/#{Connection.slugify(ctx.work.preferred_label)}")
    assert has_element?(view, "a[href='/entities/#{ctx.author.object_id}/audit-author']")
  end
  test "edition retains a navigable parent work", ctx do
    {:ok, view, _} = live(ctx.conn, "/entities/#{ctx.edition.object_id}/#{Connection.slugify(ctx.edition.preferred_label)}")
    assert has_element?(view, "a[href='/entities/#{ctx.work.object_id}/audit-book']")
  end
end
