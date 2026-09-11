alias DevilsDictionary.Encyclopedia.EntityPage
walk = fn walk, cursor, ids, pages ->
  page = EntityPage.build(1, definitions_after: cursor)
  next_ids = Enum.map(page.definitions, & &1.object_id)
  if page.works == [], do: raise("work disappeared")
  case page.pagination.definitions.next do
    nil -> IO.inspect(%{rows: length(ids ++ next_ids), unique: length(Enum.uniq(ids ++ next_ids)), pages: pages + 1, displayed_count: page.pagination.definitions.count})
    next when pages < 100 -> walk.(walk, next, ids ++ next_ids, pages + 1)
  end
end
walk.(walk, nil, [], 0)
