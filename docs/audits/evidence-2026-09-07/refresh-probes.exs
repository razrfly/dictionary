import Ecto.Query
alias DevilsDictionary.{Repo, Sources}
alias DevilsDictionary.Absorb.{Materializer, Linker}
alias DevilsDictionary.Absorb.Sources.Wiktionary
alias DevilsDictionary.Lexicon.{Lexeme, Sense, LexicalRelation}
alias DevilsDictionary.Encyclopedia.{Concept, ConceptLink}
Ecto.Adapters.SQL.Sandbox.checkout(Repo)
DevilsDictionary.Fixtures.seed_catalog!()
source = Sources.get_source_by_slug!("wiktionary")
raw = %{"word" => "auditword", "pos" => "noun", "lang_code" => "en", "forms" => [%{"form" => "oldform"}], "senses" => [%{"glosses" => ["first meaning"], "wikidata" => ["Q999999991"]}, %{"glosses" => ["second meaning"]}], "hypernyms" => [%{"word" => "oldparent"}]}
{:ok, record} = Sources.upsert_record(source, %{external_id: Wiktionary.external_id(raw), raw: raw})
{:ok, _} = Materializer.run(%{record | raw: raw}, Wiktionary)
l = Repo.get_by!(Lexeme, lemma: "auditword")
c = Repo.insert!(%Concept{qid: "Q999999991", label: "First thing"})
Linker.wiktionary_qid(nil)
old = Repo.get_by!(Sense, external_id: "auditword/noun/0#0")
raw2 = %{raw | "forms" => [%{"form" => "newform"}], "senses" => [%{"glosses" => ["second meaning"]}], "hypernyms" => []}
{:ok, record2} = Sources.upsert_record(source, %{external_id: record.external_id, raw: raw2})
{:ok, _} = Materializer.run(%{record2 | raw: raw2}, Wiktionary)
Linker.wiktionary_qid(nil)
IO.inspect(%{forms_after_refresh: Repo.get!(Lexeme,l.id).forms, senses_after_removal: Repo.all(from s in Sense, where: s.lexeme_id == ^l.id, select: {s.id,s.gloss}), old_sense_id: old.id, stale_relations: Repo.aggregate(from(r in LexicalRelation, where: r.from_lexeme_id == ^l.id), :count), stale_links: Repo.aggregate(from(x in ConceptLink, where: x.concept_id == ^c.id), :count), parity: DevilsDictionary.Health.Parity.check("wiktionary")}, label: "REFRESH_PROBE", limit: :infinity)
Repo.update_all(from(s in Sense, where: s.lexeme_id == ^l.id), set: [gloss: "CORRUPTED"])
IO.inspect(DevilsDictionary.Health.Parity.check("wiktionary"), label: "CORRUPTED_PARITY", limit: :infinity)
IO.inspect(Enum.map(["C", "C++", "C#", "!!!", "?"], &{&1, Lexeme.slug(&1)}), label: "SLUG_PROBE")
link = Repo.one!(from x in ConceptLink, where: x.concept_id == ^c.id)
Repo.update_all(from(s in Sense, where: s.id == ^old.id), set: [metadata: %{"wikidata" => [c.qid]}])
Repo.update_all(from(x in ConceptLink, where: x.id == ^link.id), set: [status: :rejected])
Linker.wiktionary_qid(nil)
IO.inspect(Repo.get!(ConceptLink, link.id).status, label: "REJECTED_AFTER_RELINK")
Ecto.Adapters.SQL.Sandbox.checkin(Repo)
