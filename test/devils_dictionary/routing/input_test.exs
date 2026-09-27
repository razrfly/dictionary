defmodule DevilsDictionary.Routing.InputTest do
  use ExUnit.Case, async: true

  import DevilsDictionary.Routing.Input

  test "an id is a positive integer that fits bigint" do
    assert is_id(1)
    assert is_id(9_223_372_036_854_775_807)
    refute is_id(9_223_372_036_854_775_808)
    refute is_id(0)
    refute is_id(-1)
    refute is_id(1.0)
    refute is_id("1")
    refute is_id(nil)
  end

  test "text is nil or valid UTF-8 without a NUL byte" do
    assert text?(nil)
    assert text?("On Mercury — planet, élément")
    assert text?("\\u0000")
    refute text?("a\0b")
    refute text?(<<0xFF>>)
    refute text?(:atom)
  end

  test "JSON is nil or an encodable map with no NUL byte in any key or string" do
    assert json?(nil)
    assert json?(%{"note" => "\\u0000", "n" => [1, %{"k" => true}]})
    refute json?(%{"note" => "a\0b"})
    refute json?(%{"a\0b" => 1})
    refute json?(%{"deep" => [%{"k" => "\0"}]})
    refute json?(%{"at" => {1, 2}})
    refute json?(%{"bad" => <<0xFF>>})
    refute json?([1, 2])
  end
end
