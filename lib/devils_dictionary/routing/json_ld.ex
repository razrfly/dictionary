defmodule DevilsDictionary.Routing.JsonLd do
  @moduledoc """
  The structured data a reader page carries (#237 D4, ADR 0004 §7): a
  `WebPage` node, and for a subject page a separate subject node the page is
  `about`, each with a stable identifier under the page's canonical URL
  (`…#page`, `…#subject`).

  The subject is typed **only by its evidenced family mapping**, the family
  of the address the ledger allocated on a `mapped` decision: People are
  `Person`, Organizations `Organization`, Places `Place`, Events `Event`,
  Works `CreativeWork`. Concepts, Nature and Subjects are `Thing`, with an
  `additionalType` naming the Wikidata class the classification matched
  where the record says which: the entity's own recorded classes
  (`metadata.wikidata_instance_of`) that are anchors of a rule its current
  decision names, or the sole anchor of such a rule. Never `schema:Nature`,
  never `DefinedTerm`. `sameAs` names only **verified** external
  identifiers; a candidate match is not an identity.

  Nothing here reads a body: the description is the page's own (the first
  displayable sentence, `Routing.PageMetadata`), so no licensing-restricted
  text reaches the markup.
  """

  import Ecto.Query

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Registry.{Entity, ExternalIdentifier}
  alias DevilsDictionary.Routing.{Classifications, Policy}

  @context "https://schema.org"
  @language "en"

  @types %{
    "people" => "Person",
    "organizations" => "Organization",
    "places" => "Place",
    "events" => "Event",
    "works" => "CreativeWork",
    "concepts" => "Thing",
    "nature" => "Thing",
    "subjects" => "Thing"
  }

  @external %{"wikidata" => "https://www.wikidata.org/wiki/"}

  @anchors Policy.root()
           |> Path.join("classification-rules.json")
           |> File.read!()
           |> Jason.decode!()
           |> Map.fetch!("instance_rules")
           |> Map.new(&{&1["id"], &1["instance_anchors"]})

  @doc "The schema.org type a family's subject is typed as."
  def type(family), do: Map.get(@types, family)

  @doc """
  The graph of a subject page: `%{page:, subject:}` are the page's facts
  (`title`, `description`, `modified`, a W3C date or nil) and the subject's
  (`object_id`, `label`, `description`, `family`); `canonical` is the
  absolute canonical URL. Returns the document, ready to encode.
  """
  def subject_graph(canonical, page, subject) when is_binary(canonical) do
    subject_id = canonical <> "#subject"

    page_node =
      canonical
      |> web_page(page)
      |> Map.put("about", %{"@id" => subject_id})

    subject_node =
      %{
        "@type" => type(subject.family) || "Thing",
        "@id" => subject_id,
        "name" => subject.label,
        "url" => canonical
      }
      |> put_present("description", subject[:description])
      |> put_list("sameAs", same_as(subject.object_id))
      |> put_list("additionalType", additional_type(subject.object_id, subject.family))

    %{"@context" => @context, "@graph" => [page_node, subject_node]}
  end

  @doc "The graph of a page that is about no subject: the `WebPage` node alone."
  def page_graph(canonical, page) when is_binary(canonical) do
    %{"@context" => @context, "@graph" => [web_page(canonical, page)]}
  end

  defp web_page(canonical, page) do
    %{
      "@type" => "WebPage",
      "@id" => canonical <> "#page",
      "url" => canonical,
      "inLanguage" => @language
    }
    |> put_present("name", page[:title])
    |> put_present("description", page[:description])
    |> put_present("dateModified", page[:modified])
  end

  @doc """
  The document as the `<script type="application/ld+json">` carries it: HTML
  characters escaped, so no text in it can close the element.
  """
  def encode(graph), do: Jason.encode!(graph, escape: :html_safe)

  @doc "The verified external identifiers of an object, as URLs, sorted."
  def same_as(object_id) when is_integer(object_id) do
    from(x in ExternalIdentifier,
      where: x.object_id == ^object_id and x.status == :verified,
      select: {x.namespace, x.external_id}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {namespace, id} ->
      case Map.get(@external, namespace) do
        nil -> []
        prefix -> [prefix <> id]
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def same_as(_object_id), do: []

  @doc """
  The externally identified additional types of a `Thing` (Concepts, Nature
  and Subjects): the Wikidata classes the current decision's rules anchor on
  that the entity records as its own classes, or a rule's sole anchor. None
  for a typed family, or where the record does not say which class matched.
  """
  def additional_type(object_id, family) when family in ~w(concepts nature subjects) do
    with %{status: :mapped, rule_ids: rule_ids} <- Classifications.current(object_id) do
      recorded =
        Repo.one(
          from e in Entity,
            where: e.object_id == ^object_id,
            select: e.metadata["wikidata_instance_of"]
        )

      recorded = if is_list(recorded), do: Enum.filter(recorded, &is_binary/1), else: []

      rule_ids
      |> Enum.flat_map(fn rule_id ->
        case Map.get(@anchors, rule_id) do
          nil -> []
          [anchor] -> [anchor | Enum.filter(recorded, &(&1 in [anchor]))]
          anchors -> Enum.filter(recorded, &(&1 in anchors))
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&(@external["wikidata"] <> &1))
    else
      _ -> []
    end
  end

  def additional_type(_object_id, _family), do: []

  defp put_present(node, _key, nil), do: node
  defp put_present(node, key, value) when is_binary(value), do: Map.put(node, key, value)

  defp put_list(node, _key, []), do: node
  defp put_list(node, key, [one]), do: Map.put(node, key, one)
  defp put_list(node, key, list), do: Map.put(node, key, list)
end
