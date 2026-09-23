defmodule DevilsDictionary.Discovery.Providers.Wikiquote.Parser do
  @moduledoc """
  Wikiquote's Parsoid HTML, read the way #158's probe read it (build 4a).

  `GET /api/rest_v1/page/html/<title>` returns semantic HTML where the
  structure *is* the data, which is why this route and not `action=parse`
  wikitext (136 kB of nested bullets and templates for *Voltaire*) or
  `list=search` (navboxes and lead paragraphs):

    * a **top-level `<li>`** under a section heading is a quotation;
    * a **nested `<li>`** beneath it is its citation;
    * the **`<h2>`/`<h3>` chain** above it is its section — on an author page
      the `<h3>` is usually the work, `Candide (1759)`;
    * `<sup class="reference">` and `<style>` are skipped;
    * items under *External links*, *See also* and *References* are dropped;
    * items shorter than 15 characters are dropped.

  Nothing is extracted that is not a substring of the page (#101's rule): the
  text, the citation, the work and the year are read, never composed.

  ## The register

  Rows under a *Misattributed*, *Disputed*, *Unsourced* or *Attributed*
  heading are the page's own provenance register (#158 Finding 1). They are
  parsed in the same pass and returned **apart** from the quotations, with
  their `register` kind, so a caller can never put one on a shelf by
  forgetting a filter.

  Pure: HTML in, maps out. No network, no database.
  """

  @dropped_sections ["external links", "see also", "references"]
  @registers [
    {"misattributed", :misattributed},
    {"disputed", :disputed},
    {"unsourced", :unsourced},
    {"attributed", :attributed}
  ]
  @min_length 15
  @years 1500..2029

  @doc """
  Parses one page. Returns

      %{title, revision_id, quotations: [quotation], register: [quotation]}

  where a quotation is `%{text, citation, citation_links, attributed_links, section,
  subsection, position, work, year, register, about_subject}`. `position` is
  the item's 1-based place within its section (h2 and h3 together), which with
  the title and section is the provider's stable id for it.
  """
  def parse(html) when is_binary(html) do
    {:ok, document} = Floki.parse_document(html)

    body = Floki.find(document, "body")

    items =
      body
      |> walk(%{h2: nil, h3: nil}, [])
      |> Enum.reverse()
      |> Enum.reject(&is_nil(&1.section))
      |> Enum.reject(&(String.downcase(&1.section) in @dropped_sections))
      |> Enum.reject(&(String.length(&1.text) < @min_length))
      |> number_within_sections()

    %{
      title: title(document),
      revision_id: revision_id(document),
      quotations: Enum.reject(items, & &1.register),
      register: Enum.filter(items, & &1.register)
    }
  end

  # ── the walk ────────────────────────────────────────────────────────────

  defp walk(nodes, ctx, acc) when is_list(nodes) do
    {_ctx, acc} =
      Enum.reduce(nodes, {ctx, acc}, fn node, {ctx, acc} -> step(node, ctx, acc) end)

    acc
  end

  defp step({heading, _attrs, children}, ctx, acc) when heading in ["h2", "h3"] do
    text = children |> Floki.text() |> squish()
    ctx = if heading == "h2", do: %{h2: text, h3: nil}, else: %{ctx | h3: text}
    {ctx, acc}
  end

  # Navboxes, stub notices and infoboxes are tables; a quotation is never one.
  defp step({tag, _attrs, _children}, ctx, acc) when tag in ["table", "style", "script"],
    do: {ctx, acc}

  defp step({list, _attrs, children}, ctx, acc) when list in ["ul", "ol"] do
    acc =
      Enum.reduce(children, acc, fn
        {"li", _attrs, li_children}, acc -> [quotation(li_children, ctx) | acc]
        _other, acc -> acc
      end)

    {ctx, acc}
  end

  # A `<section>` (Parsoid wraps every heading's content in one) or any other
  # container: carry the heading context through it and out again, because a
  # nested `<section>` for an `<h3>` must not reset the `<h2>` it sits under.
  defp step({_tag, _attrs, children}, ctx, acc) do
    {ctx, acc} =
      Enum.reduce(children, {ctx, acc}, fn node, {ctx, acc} -> step(node, ctx, acc) end)

    {ctx, acc}
  end

  defp step(_text_or_comment, ctx, acc), do: {ctx, acc}

  # ── one item ────────────────────────────────────────────────────────────

  defp quotation(children, ctx) do
    {nested, own} = Enum.split_with(children, &nested_list?/1)

    citations =
      nested
      |> Enum.flat_map(fn {_list, _attrs, items} -> items end)
      |> Enum.filter(&match?({"li", _, _}, &1))

    citation = citations |> Enum.map(&text/1) |> Enum.reject(&(&1 == "")) |> Enum.join(" / ")
    citation_links = Enum.flat_map(citations, &wiki_links/1)
    heading = ctx.h3
    year = earliest_year(citation) || earliest_year(heading || "")

    %{
      text: text({"li", [], own}),
      citation: blank_to_nil(citation),
      citation_links: citation_links,
      attributed_links: attributed_links(own ++ citations),
      section: ctx.h2,
      subsection: ctx.h3,
      position: nil,
      work: citation_work(citations) || heading_work(heading),
      year: year,
      register: register(ctx.h2) || register(ctx.h3),
      about_subject: about_subject?(ctx.h2)
    }
  end

  defp nested_list?({tag, _attrs, _children}) when tag in ["ul", "ol", "dl"], do: true
  defp nested_list?(_node), do: false

  # The words, with references, styles and page properties removed and every
  # `<br>` a space. Squished, because the HTML's own line breaks are layout.
  defp text(node) do
    node
    |> strip()
    |> Floki.text(sep: "")
    |> squish()
  end

  defp strip({tag, attrs, children}) do
    cond do
      tag in ["style", "script", "link", "meta"] -> ""
      tag == "sup" and has_class?(attrs, "reference") -> ""
      tag == "br" -> " "
      true -> {tag, attrs, Enum.map(children, &strip/1)}
    end
  end

  defp strip(other), do: other

  defp has_class?(attrs, class) do
    Enum.any?(attrs, fn
      {"class", value} -> class in String.split(value)
      _ -> false
    end)
  end

  # Main-namespace pages a citation links to, in order: `./Ambrose_Bierce` is
  # the page `Ambrose Bierce`. A link with a namespace (`./Category:…`,
  # `./File:…`) or to another wiki is not a page this could be credited to.
  defp wiki_links(node) do
    node
    |> Floki.find(~s(a[rel="mw:WikiLink"]))
    |> Enum.flat_map(fn link ->
      case Floki.attribute(link, "href") do
        ["./" <> path | _] ->
          title = path |> String.split("#") |> hd() |> URI.decode() |> String.replace("_", " ")
          if String.contains?(title, ":") or title == "", do: [], else: [title]

        _ ->
          []
      end
    end)
  end

  # The pages a register row says a line is *attributed to*: a main-namespace
  # link whose preceding words, in the row's own sentence, end with
  # "attributed to" — `Sometimes attributed to [[Bismarck]]`,
  # `misattributed to [[Voltaire]] by …`. This reads which *link* the
  # register's sentence points at; the identity is still the link's page, and
  # the page's QID is still Wikidata's sitelink. A row that names the person
  # without linking them yields nothing.
  @attributed ~r/attributed\s+to(\s+the)?\s*\z/iu

  defp attributed_links(nodes) do
    {links, _tail} =
      nodes
      |> events([])
      |> Enum.reduce({[], ""}, fn
        {:text, text}, {links, tail} ->
          {links, String.slice(tail <> text, -60, 60)}

        {:link, title}, {links, tail} ->
          links = if Regex.match?(@attributed, tail), do: [title | links], else: links
          {links, tail <> title}
      end)

    links |> Enum.reverse() |> Enum.uniq()
  end

  # The node list flattened to the text and the main-namespace page links in
  # it, in document order, with references and nested lists' own nesting kept.
  defp events(nodes, acc) when is_list(nodes), do: Enum.reduce(nodes, acc, &events/2)

  defp events({"a", _attrs, children} = node, acc) do
    case wiki_links(node) do
      [title] ->
        acc ++ [{:link, title}]

      [] ->
        events(children, acc)
    end
  end

  defp events({tag, attrs, children}, acc) do
    cond do
      tag in ["style", "script"] -> acc
      tag == "sup" and has_class?(attrs, "reference") -> acc
      true -> events(children, acc)
    end
  end

  defp events(text, acc) when is_binary(text), do: acc ++ [{:text, text}]
  defp events(_other, acc), do: acc

  # The work a citation names is the first italic run in it — Wikiquote's own
  # convention for titles (`<i>The Devil's Dictionary</i>`).
  defp citation_work(citations) do
    Enum.find_value(citations, fn citation ->
      case Floki.find(citation, "i") do
        [first | _] -> first |> text() |> blank_to_nil()
        [] -> nil
      end
    end)
  end

  # On an author page the `<h3>` is the work: `Candide (1759)` → `Candide`.
  defp heading_work(nil), do: nil

  defp heading_work(heading) do
    heading
    |> String.replace(~r/\s*\(([^)]*)\)\s*\z/u, "")
    |> String.trim()
    |> blank_to_nil()
  end

  @doc "The earliest plausible year (#{@years.first}–#{@years.last}) in a string, or nil."
  def earliest_year(text) when is_binary(text) do
    ~r/(?<!\d)(1[5-9]\d\d|20[0-2]\d)(?!\d)/u
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [year] -> String.to_integer(year) end)
    |> Enum.filter(&(&1 in @years))
    |> Enum.min(fn -> nil end)
  end

  def earliest_year(_text), do: nil

  defp register(nil), do: nil

  defp register(heading) do
    downcased = String.downcase(heading)

    Enum.find_value(@registers, fn {prefix, kind} ->
      if String.starts_with?(downcased, prefix), do: kind
    end)
  end

  # "Quotes about Voltaire" on Voltaire's page is other people's words about
  # him, so the page's subject is not their author.
  defp about_subject?(nil), do: false

  defp about_subject?(heading) do
    heading |> String.downcase() |> String.starts_with?(["quotes about", "about "])
  end

  defp number_within_sections(items) do
    {numbered, _counts} =
      Enum.map_reduce(items, %{}, fn item, counts ->
        key = {item.section, item.subsection}
        n = Map.get(counts, key, 0) + 1
        {%{item | position: n}, Map.put(counts, key, n)}
      end)

    numbered
  end

  # ── the page ────────────────────────────────────────────────────────────

  # `dc:isVersionOf` names the page the HTML is a version of — after a
  # redirect, the target (`Bank` answers as `Banking`).
  defp title(document) do
    case Floki.attribute(document, ~s(link[rel="dc:isVersionOf"]), "href") do
      [href | _] ->
        href |> String.split("/wiki/") |> List.last() |> URI.decode() |> String.replace("_", " ")

      [] ->
        document |> Floki.find("title") |> Floki.text() |> blank_to_nil()
    end
  end

  # `<html about="…/Special:Redirect/revision/3272777">`: the revision this
  # HTML renders, which is what a payload cites.
  defp revision_id(document) do
    with [about | _] <- Floki.attribute(document, "html", "about"),
         [_, id] <- Regex.run(~r{/revision/(\d+)}, about) do
      String.to_integer(id)
    else
      _ -> nil
    end
  end

  defp squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text
end
