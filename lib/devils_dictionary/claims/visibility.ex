defmodule DevilsDictionary.Claims.Visibility do
  @moduledoc """
  The single public-display policy for claim projections and revisioned text.

  Public relationship reads exclude withdrawn/rejected claim revisions and
  attachments whose current content or sense revision is withdrawn. Pending
  and disputed claims remain visible with their actual state: hiding a dispute
  would make the correction process invisible. The one exception is a person
  nominated here (#105 rule 1): until a reviewer accepts it, it is not public
  at all (`Claims.visible/2`).

  Rights restrictions are a different axis. They redact bodies, excerpts and
  quoted evidence while retaining identity, source and revision provenance.
  A revision is metadata-only when any of these source-neutral declarations is
  present in `rights_metadata`:

    * `display` is `restricted`, `metadata_only`, `identity_only` or `none`
    * `allow_display` or `display_allowed` is false

  Internal readers may inspect retained text only through an explicitly
  authorized call site; callers never get internal visibility by adding a URL
  parameter.
  """

  @restricted_display ~w(restricted metadata_only identity_only none)

  @doc "Whether a content revision permits its body to be shown publicly."
  def body_displayable?(%{rights_metadata: metadata}) when is_map(metadata) do
    display = value(metadata, "display")
    allow = value(metadata, "allow_display")
    allowed = value(metadata, "display_allowed")

    display_allowed? =
      is_nil(display) or
        (is_binary(display) and display not in @restricted_display) or
        (is_atom(display) and to_string(display) not in @restricted_display)

    display_allowed? and allow != false and allowed != false
  end

  def body_displayable?(_), do: true

  @doc "Whether one content revision's lifecycle and rights permit public text."
  def content_displayable?(revision) do
    revision_displayable?(revision) and body_displayable?(revision)
  end

  @doc "Whether one sense revision's lifecycle permits its public gloss."
  def sense_displayable?(revision), do: revision_displayable?(revision)

  @doc "Redacts a public content projection without erasing its provenance."
  def restrict_content(view, visibility \\ :public)

  def restrict_content(view, :internal), do: Map.put(view, :display_restricted?, false)

  def restrict_content(view, :public) do
    if content_displayable?(view) do
      Map.put(view, :display_restricted?, false)
    else
      redact(view)
    end
  end

  @doc """
  Applies the effective public policy to an immutable cited content revision.

  A historical citation remains identifiable, but public text is permitted
  only when both the cited revision and the content item's current revision
  permit it. A later withdrawal or rights restriction therefore cannot be
  bypassed by retaining an old revision URL. Explicitly authorized internal
  inspection continues to show the immutable cited body.
  """
  def restrict_historical_content(view, current, visibility \\ :public)

  def restrict_historical_content(view, _current, :internal),
    do: Map.put(view, :display_restricted?, false)

  def restrict_historical_content(view, current, :public) do
    if content_displayable?(view) and content_displayable?(current) do
      Map.put(view, :display_restricted?, false)
    else
      redact(view)
    end
  end

  @doc "The equivalent effective policy for an immutable cited sense revision."
  def restrict_historical_sense(view, current, visibility \\ :public)

  def restrict_historical_sense(view, _current, :internal),
    do: Map.put(view, :display_restricted?, false)

  def restrict_historical_sense(view, current, :public) do
    if sense_displayable?(view) and sense_displayable?(current) do
      Map.put(view, :display_restricted?, false)
    else
      redact(view)
    end
  end

  @doc "A stable public label when restricted text cannot supply one."
  def content_label(headword, body, id, rights_metadata \\ %{}) do
    if body_displayable?(%{rights_metadata: rights_metadata}) do
      headword || truncate(body) || "Content ##{id}"
    else
      headword || "Restricted content ##{id}"
    end
  end

  defp truncate(nil), do: nil
  defp truncate(body), do: String.slice(body, 0, 80)

  defp revision_displayable?(nil), do: false

  defp revision_displayable?(%{lifecycle_state: state}),
    do: state not in [:withdrawn, "withdrawn"]

  defp revision_displayable?(_), do: true

  defp redact(view) do
    view
    |> Map.put(:body, nil)
    |> Map.put(:summary, nil)
    |> Map.put(:display_restricted?, true)
  end

  defp value(metadata, "display"), do: fetch_string_or_atom(metadata, "display", :display)

  defp value(metadata, "allow_display"),
    do: fetch_string_or_atom(metadata, "allow_display", :allow_display)

  defp value(metadata, "display_allowed"),
    do: fetch_string_or_atom(metadata, "display_allowed", :display_allowed)

  defp fetch_string_or_atom(metadata, string, atom) do
    case Map.fetch(metadata, string) do
      {:ok, value} -> value
      :error -> Map.get(metadata, atom)
    end
  end
end
