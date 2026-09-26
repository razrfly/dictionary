defmodule DevilsDictionary.Routing.RecoverySchemaTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Routing.Recovery

  # Both sides of a real difference `RecoveryTest` met: the stored definition,
  # and what the server re-parses from pg_dump's text of it.
  @stored "CHECK (((status)::text = ANY ((ARRAY['mapped'::character varying, 'needs_review'::character varying])::text[])))"
  @restored "CHECK (((status)::text = ANY (ARRAY[('mapped'::character varying)::text, ('needs_review'::character varying)::text])))"

  test "a dumped IN-list and its restored re-parse compare equal" do
    assert Recovery.canonical(@stored) == @restored
    assert Recovery.canonical(@restored) == @restored
  end

  test "any other change to the definition is still a difference" do
    changed = String.replace(@stored, "'needs_review'", "'needs_reviews'")
    refute Recovery.canonical(changed) == @restored

    extra =
      String.replace(
        @stored,
        "'mapped'::character varying,",
        "'mapped'::character varying, 'x'::character varying,"
      )

    refute Recovery.canonical(extra) == @restored
    refute Recovery.canonical(String.replace(@stored, "::text[]", "::varchar[]")) == @restored
  end

  test "quoted commas and doubled quotes stay inside their element" do
    assert Recovery.canonical(
             "(ARRAY['a, b'::character varying, 'it''s'::character varying])::text[]"
           ) ==
             "ARRAY[('a, b'::character varying)::text, ('it''s'::character varying)::text]"
  end
end
