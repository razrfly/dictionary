defmodule DevilsDictionary.Routing.ReviewRuleTest do
  @moduledoc """
  The standing review rule's file and signature (#237 Part A′):

    * the committed rule is exactly the clauses this code implements, and its
      digest names its content, whatever the formatting or the signature;
    * only the holder of a reviewer account can sign it: the password and
      the role are checked before anything is written, and a rule is signed
      once;
    * a signed rule is refused when its content changed after signing, when
      its signer no longer holds the reviewer role, or when its signature
      names another account;
    * a file that is not this code's rule — another format, a clause added,
      removed or reordered, a stray key such as `rehearsal` — is refused.

  What the rule decides is `ReviewRuleReproductionTest`'s and, in a run,
  `BackfillTest`'s.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.AccountsFixtures
  alias DevilsDictionary.Routing.{ReviewRule, ReviewRuleSignature}

  setup do
    dir = Path.join(System.tmp_dir!(), "review-rule-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    reviewer =
      AccountsFixtures.unconfirmed_user_fixture()
      |> Ecto.Changeset.change(reviewer: true)
      |> Repo.update!()
      |> AccountsFixtures.set_password()

    %{dir: dir, reviewer: reviewer, password: AccountsFixtures.valid_user_password()}
  end

  defp committed, do: ReviewRule.path() |> File.read!() |> Jason.decode!()

  defp write!(ctx, doc, name \\ "rule.json") do
    path = Path.join(ctx.dir, name)
    File.write!(path, Jason.encode!(doc, pretty: true))
    path
  end

  defp unsigned!(ctx), do: write!(ctx, Map.put(committed(), "signature", nil))

  test "the committed rule is the clauses this code implements, and its digest is its content" do
    {:ok, rule} = ReviewRule.read(ReviewRule.path())

    assert Enum.map(rule.doc["clauses"], &{&1["id"], &1["action"]}) == ReviewRule.clauses()
    assert rule.sha256 =~ ~r/\A[0-9a-f]{64}\z/

    # Signed or not, a signature can only name this content.
    assert is_nil(rule.signature) or rule.signature["rule_sha256"] == rule.sha256

    # Formatting and the signature are not content.
    doc = rule.doc
    assert ReviewRule.digest(doc) == rule.sha256
    assert ReviewRule.digest(Map.put(doc, "signature", %{"anything" => 1})) == rule.sha256

    compact = doc |> Jason.encode!() |> Jason.decode!()
    assert ReviewRule.digest(compact) == rule.sha256

    refute ReviewRule.digest(put_in(doc, ["clauses", Access.at(0), "text"], "Something else.")) ==
             rule.sha256
  end

  test "only the holder of a reviewer account signs it, once", ctx do
    path = unsigned!(ctx)
    {:ok, before} = ReviewRule.read(path)
    bytes = File.read!(path)

    assert {:error, message} = ReviewRule.sign(path, ctx.reviewer.email, "not the password")
    assert message =~ "no reviewer account"

    assert {:error, _} = ReviewRule.sign(path, "nobody@example.com", ctx.password)

    plain = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
    assert {:error, message} = ReviewRule.sign(path, plain.email, ctx.password)
    assert message =~ "does not hold the reviewer role"

    # Nothing was written by any refusal.
    assert File.read!(path) == bytes

    assert {:ok, rule} = ReviewRule.sign(path, ctx.reviewer.email, ctx.password)
    assert rule.sha256 == before.sha256
    assert rule.signer.id == ctx.reviewer.id

    assert %{
             "signer" => signer,
             "user_id" => user_id,
             "rule_sha256" => sha256,
             "signed_at" => _,
             "method" => _,
             "attestation" => _
           } = rule.signature

    assert {signer, user_id, sha256} == {ctx.reviewer.email, ctx.reviewer.id, before.sha256}
    assert {:ok, _} = ReviewRule.load(path)

    assert {:error, message} = ReviewRule.sign(path, ctx.reviewer.email, ctx.password)
    assert message =~ "already signed"
  end

  test "a signed rule is refused when it changed, its signer lost the role, or it names another account",
       ctx do
    path = unsigned!(ctx)
    assert {:error, message} = ReviewRule.load(path)
    assert message =~ "not signed"

    {:ok, rule} = ReviewRule.sign(path, ctx.reviewer.email, ctx.password)

    changed =
      write!(
        ctx,
        put_in(rule.doc, ["clauses", Access.at(6), "text"], "Confirm every collision."),
        "changed.json"
      )

    assert {:error, message} = ReviewRule.load(changed)
    assert message =~ "changed after it was signed"

    other = AccountsFixtures.user_fixture()

    impostor =
      write!(ctx, put_in(rule.doc, ["signature", "user_id"], other.id), "impostor.json")

    assert {:error, message} = ReviewRule.load(impostor)
    assert message =~ "not the account the signature names"

    ctx.reviewer |> Ecto.Changeset.change(reviewer: false) |> Repo.update!()
    assert {:error, message} = ReviewRule.load(path)
    assert message =~ "does not hold the reviewer role"
  end

  test "a file that is not this code's rule is refused", ctx do
    doc = Map.put(committed(), "signature", nil)
    [first, second | rest] = doc["clauses"]

    for {name, bad, expected} <- [
          {"format", Map.put(doc, "format", "dd.review-rule/2"), "format"},
          {"rehearsal", Map.put(doc, "rehearsal", true), "unknown keys rehearsal"},
          {"reordered", Map.put(doc, "clauses", [second, first | rest]), "must be exactly"},
          {"removed", Map.put(doc, "clauses", [first | rest]), "must be exactly"},
          {"added",
           Map.put(
             doc,
             "clauses",
             doc["clauses"] ++ [%{"id" => "confirm_all", "action" => "confirm", "text" => "All."}]
           ), "must be exactly"},
          {"extra key", Map.put(doc, "clauses", [Map.put(first, "scope", "all"), second | rest]),
           "nothing else"},
          {"empty text", Map.put(doc, "clauses", [Map.put(first, "text", " "), second | rest]),
           "nothing else"},
          {"no statement", Map.delete(doc, "statement"), "a name and a statement"},
          {"signature", Map.put(doc, "signature", "owner"), "a signature is an object"}
        ] do
      path = write!(ctx, bad, "#{name}.json")
      assert {:error, message} = ReviewRule.read(path), name
      assert message =~ expected, "#{name}: #{message}"
    end

    assert {:error, _} = ReviewRule.read(Path.join(ctx.dir, "missing.json"))
    File.write!(Path.join(ctx.dir, "not-json.json"), "{")
    assert {:error, _} = ReviewRule.read(Path.join(ctx.dir, "not-json.json"))

    # A key given twice would digest as its last value while a reader may
    # see the first.
    twice = Path.join(ctx.dir, "twice.json")
    File.write!(twice, ~s({"format": "x", "format": "dd.review-rule/1", "clauses": []}))
    assert {:error, message} = ReviewRule.read(twice)
    assert message =~ ~s(the key "format" is given twice)

    nested = Path.join(ctx.dir, "nested.json")

    File.write!(
      nested,
      String.replace(
        Jason.encode!(doc, pretty: true),
        ~s("id": "standing_decision"),
        ~s("id": "standing_decision", "id": "standing_decision")
      )
    )

    assert {:error, message} = ReviewRule.read(nested)
    assert message =~ ~s(the key "id" is given twice under clauses)

    # A clause that is not an object is refused, not crashed on.
    strings = write!(ctx, Map.put(doc, "clauses", ["standing_decision" | rest]), "strings.json")
    assert {:error, message} = ReviewRule.read(strings)
    assert message =~ "clauses is a list of objects"
  end

  test "the file names the implementation of decide/2 its clauses are signed for", ctx do
    doc = Map.put(committed(), "signature", nil)
    assert doc["implementation"] == ReviewRule.implementation()

    for {name, bad} <- [
          {"next", Map.put(doc, "implementation", ReviewRule.implementation() + 1)},
          {"text", Map.put(doc, "implementation", "1")},
          {"none", Map.delete(doc, "implementation")}
        ] do
      assert {:error, message} = ReviewRule.read(write!(ctx, bad, "#{name}.json")), name
      assert message =~ "implementation", name
    end

    # The implementation is content: changing it changes the digest.
    refute ReviewRule.digest(Map.put(doc, "implementation", 99)) == ReviewRule.digest(doc)
  end

  test "a signing is recorded on the installation, and a signature in the file alone does not load",
       ctx do
    path = unsigned!(ctx)
    {:ok, rule} = ReviewRule.sign(path, ctx.reviewer.email, ctx.password)

    # The row: the digest, the signer, the time the file says.
    assert %ReviewRuleSignature{user_id: user_id, signed_at: signed_at, method: method} =
             Repo.get_by(ReviewRuleSignature, rule_sha256: rule.sha256)

    assert user_id == ctx.reviewer.id
    assert DateTime.to_iso8601(signed_at) == rule.signature["signed_at"]
    assert method =~ "review_rule_signatures"

    # The same content, signed by hand into another file: the file says
    # the reviewer signed it, and the installation says no such signing.
    forged_doc = Map.put(committed(), "name", "Standing review rule, forged")

    forged =
      write!(
        ctx,
        Map.put(forged_doc, "signature", %{
          "signer" => ctx.reviewer.email,
          "user_id" => ctx.reviewer.id,
          "rule_sha256" => ReviewRule.digest(forged_doc),
          "signed_at" => "2026-10-09T12:00:00Z",
          "method" => "typed by hand",
          "attestation" => "not the owner"
        }),
        "forged.json"
      )

    assert {:error, message} = ReviewRule.load(forged)
    assert message =~ "no signing of"
    assert message =~ "a signature written into the file is not a signing"

    # The signed file with its time altered: the row does not match.
    later =
      write!(
        ctx,
        put_in(rule.doc, ["signature", "signed_at"], "2030-01-01T00:00:00Z"),
        "later.json"
      )

    assert {:error, message} = ReviewRule.load(later)
    assert message =~ "this installation recorded #{ctx.reviewer.email} signing"

    # The same content cannot be signed twice on one installation, even
    # into another file.
    again = unsigned!(ctx)
    assert {:error, message} = ReviewRule.sign(again, ctx.reviewer.email, ctx.password)
    assert message =~ "already signed on this installation"

    # The row is permanent, and only a reviewer's.
    assert_raise Postgrex.Error, ~r/permanent/, fn ->
      Repo.query!("DELETE FROM review_rule_signatures WHERE rule_sha256 = $1", [rule.sha256])
    end

    plain = AccountsFixtures.user_fixture()

    assert_raise Postgrex.Error, ~r/needs a reviewer account/, fn ->
      Repo.insert!(%ReviewRuleSignature{
        rule_sha256: String.duplicate("f", 64),
        user_id: plain.id,
        signed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        method: "test",
        attestation: "test"
      })
    end
  end
end
