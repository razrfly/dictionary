defmodule DevilsDictionary.Discovery.Conformance.OpenLibraryFixture do
  @moduledoc """
  Conformance for `DevilsDictionary.Discovery.Providers.OpenLibrary`.

  The responses here are real ones, trimmed: the candidate pages are the first
  two pages of what `search/inside.json?q=war` answered on 2026-09-18, cut to
  the fields the provider reads and one snippet each, and the work tables are
  the `ia:` crosswalk's own answers for those pages' English identifiers the
  same day.

  Three candidates are kept deliberately, one for each way this provider throws
  a result away:

    * **`resorttowardatag0000sark`** is Open Library's *first* result for *war*
      and it crosses to no work at all. `ia:` finds nothing for it even though
      the Internet Archive's own metadata names `OL16946778W`. It is here so
      that a provider which started inventing an OLID — or which fell back to
      the Internet Archive identifier as an identity — would fail here rather
      than on a word page. `directionofwarco0000stra` is the second such case.

    * **`dielangenreisen00baue`** is `undetermined`, and **`derzweitemordrom0000turs`**
      and its neighbours are German. German *war* is the past tense of *sein*,
      and half of Open Library's first page for *war* is German prose using it
      that way. They are here so that a provider which dropped the language
      gate would fail here rather than putting ten German novels on
      `/define/war`.

    * **`jovana0000utta`** is the case the language gate **cannot** catch: the
      Internet Archive files it as English and the text is plainly German. It
      is in the expected ids, because that is what the code does and a fixture
      that quietly excluded it would be hiding the limitation instead of
      recording it. `docs/integrations/open-library.md` says so too.

  The external ids are written as literals rather than computed from the
  provider, so that changing how a book is identified breaks this suite instead
  of quietly agreeing with itself.

  One trim is not a cut: `worshippingmyths0000wood` is removed from page two.
  It is genuinely in **both** live pages — Open Library's offsets overlap,
  measured at two of twenty — and the pagination case asserts that the second
  page *appends* to the first, which is a statement about this provider's
  cursor rather than about the source's stability.

  Page two is stubbed and, at `result_limit: 3`, never reached: three attested
  candidates come out of the first twenty long before the offset crosses a
  source page. It is here because the provider will ask for it on a real page
  with a real limit, and a stub that answered page two with page one would let
  that go wrong silently.
  """

  use DevilsDictionary.Discovery.Conformance.Fixture

  alias DevilsDictionary.Discovery.Providers.OpenLibrary

  # What the first run yields, in the order Open Library returned the candidates
  # it drew them from. Two items for three attested candidates, because the
  # first attested candidate — Open Library's own first result for *war* —
  # crosses to no work.
  @page1_ids ~w(OL2621838W OL5342545W)

  # What the second run appends. It comes from the **same** source page at a
  # later offset: `config/test.exs` sets `result_limit: 3` and Open Library's
  # page is twenty, so a page of this pipeline is three attested candidates and
  # the cursor is an offset into the candidate stream rather than a page
  # number. That is the whole point of the cursor being an offset, and it is
  # what the live provider does on `/define/war` too.
  @page2_ids ~w(OL35377772W OL6035468W)

  # A short page: four candidates, which is fewer documents than Open Library's
  # own page size, so pagination ends rather than promising a page that is not
  # there.
  @short_ids ~w(OL2621838W OL5342545W)

  @short_take 4

  @impl true
  def provider, do: OpenLibrary

  @impl true
  def covered_target(context) do
    word = word!(context, "war", ~w(wordnet))

    %{
      object_id: word.object_id,
      term: word.lemma,
      language: word.language_tag,
      relevance: "term"
    }
  end

  @impl true
  def stub(:empty, _context) do
    # A word no scanned book uses: `200` with an empty hit list. A negative
    # cache, not a failure — and it costs one request, because the crosswalk is
    # never reached when nothing survives the gates.
    respond(%{"hits" => %{"hits" => []}}, [])
    %{pages: [[]]}
  end

  def stub(:results, _context) do
    respond(page(Enum.take(page1(), @short_take)), works())
    %{pages: [@short_ids]}
  end

  def stub(:paged, _context) do
    respond_paged()
    %{pages: [@page1_ids, @page2_ids]}
  end

  # Two routes on one stub, told apart the way the real API tells them apart —
  # by the path. `/search/inside.json` is the attestation search;
  # `/search.json` with an `ia:` group is the crosswalk to the work OLID.
  defp respond(inside_body, work_rows) do
    Req.Test.stub(OpenLibrary, fn conn ->
      case conn.request_path do
        "/search/inside.json" -> Req.Test.json(conn, inside_body)
        "/search.json" -> Req.Test.json(conn, crosswalk(conn, work_rows))
        _other -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not found"})
      end
    end)
  end

  defp respond_paged do
    Req.Test.stub(OpenLibrary, fn conn ->
      case {conn.request_path, page_param(conn)} do
        {"/search/inside.json", "2"} -> Req.Test.json(conn, page(page2()))
        {"/search/inside.json", _first} -> Req.Test.json(conn, page(page1()))
        {"/search.json", _any} -> Req.Test.json(conn, crosswalk(conn, works()))
        _other -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not found"})
      end
    end)
  end

  defp page_param(conn) do
    conn |> Plug.Conn.fetch_query_params() |> Map.get(:query_params) |> Map.get("page")
  end

  # The crosswalk answers only for the identifiers it was actually asked about,
  # the way the real one does. A stub that answered with every work it knows
  # would let a provider pass while sending the wrong group.
  defp crosswalk(conn, work_rows) do
    asked =
      conn
      |> Plug.Conn.fetch_query_params()
      |> Map.get(:query_params)
      |> Map.get("q", "")
      |> then(&Regex.scan(~r/[A-Za-z0-9._-]+/, &1))
      |> List.flatten()
      |> MapSet.new()

    docs =
      Enum.filter(work_rows, fn row ->
        Enum.any?(row["ia"], &MapSet.member?(asked, &1))
      end)

    %{"numFound" => length(docs), "docs" => docs}
  end

  defp page(docs), do: %{"hits" => %{"hits" => Enum.map(docs, &document/1)}}

  # The Elasticsearch envelope Open Library passes through: every `fields`
  # value is a one-element list, and the snippet lives under `highlight`.
  defp document({id, title, year, creator, language, snippet}) do
    %{
      "fields" =>
        %{
          "identifier" => [id],
          "meta_title" => [title],
          "meta_creator" => [creator],
          "meta_languageSorter" => [language]
        }
        |> put_year(year),
      "highlight" => %{"text" => [snippet]}
    }
  end

  defp put_year(fields, nil), do: fields
  defp put_year(fields, year), do: Map.put(fields, "meta_year", [year])

  defp work(key, title, year, cover, author, ia) do
    %{
      "key" => key,
      "title" => title,
      "first_publish_year" => year,
      "cover_i" => cover,
      "author_name" => (author && [author]) || [],
      "ia" => ia
    }
  end

  defp doc(id, title, year, creator, language, snippet),
    do: {id, title, year, creator, language, snippet}

  defp page1 do
    [
      doc(
        "resorttowardatag0000sark",
        "Resort to war : a data guide to inter-state, extra-state, intra-state, and non-state wars, 1816-2007",
        2010,
        "Sarkees, Meredith Reid, 1950-",
        "English",
        "Inter-state {{{War}}} 61 Describing Extra-state {{{War}}} 63 Describing Intra-state {{{War}}} 64 Describing Non-state {{{War}}} 70 3:"
      ),
      doc(
        "dielangenreisen00baue",
        "Die langen Reisen",
        1956,
        "Bauer, Walter",
        "undetermined",
        "Grenzen. Nansen {{{war}}} einundzwanzig, dies {{{war}}} seine erste grofie Schiffsreise. Er {{{war}}} Student der"
      ),
      doc(
        "postmodernwarnew0000gray_f5e2",
        "Postmodern war : the new politics of conflict",
        1997,
        "Gray, Chris Hables",
        "English",
        "Modern {{{War}}} The Emergence of Postmodern {{{War}}}: World {{{War}}} II Postmodern Wars Imaginary and Real: World {{{War}}} III"
      ),
      doc(
        "jovana0000utta",
        "Jovana",
        2003,
        "Utta Danella",
        "English",
        "gesprochen? Er {{{war}}} es, der ihr nachgegangen {{{war}}}? Aber ein Irrtum {{{war}}} nicht mdglich, er {{{war}}} es wirklich."
      ),
      doc(
        "directionofwarco0000stra",
        "The direction of war : contemporary strategy in historical perspective",
        2014,
        "Strachan, Hew",
        "English",
        "we wage {{{war}}}. If {{{war}}} is to fulfil the aims of policy, then we need first to under- stand {{{war}}}. Hew Strachan"
      ),
      doc(
        "wolfskinder0000john",
        "Wolfskinder",
        2011,
        "John Ajvide Lindqvist",
        "English",
        "Auto und {{{war}}} auf dem Weg nach Hause. Aus- nahmsweise {{{war}}} er nicht unzufrieden. Normalerweise {{{war}}} er eigentlich"
      ),
      doc(
        "undeswarsommerro0000wigg",
        "Und es war Sommer... Roman",
        2009,
        "Wiggs, Susan Verfasser",
        "German",
        "schneller, als es hier erlaubt {{{war}}}, doch es {{{war}}} ihr egal. Um 40 diese Zeit {{{war}}} weit und breit keine Menschenseele"
      ),
      doc(
        "fightingdifferen0000wats",
        "Fighting different wars : experience, memory, and the First World War in Britain",
        2004,
        "Watson, Janet S. K",
        "English",
        "auxiliary {{{war}}} workers 105 4 A family at {{{war}}}: the Beales of Standen 146 Part II Memory and the {{{war}}} 5 The soldier’s"
      ),
      doc(
        "werwindsatkrimin0000neuh",
        "Wer Wind sät : Kriminalroman",
        2013,
        "Neuhaus, Nele, 1967-",
        "German",
        "gereist {{{war}}}. Sie hatte ihre Sachen gepackt und {{{war}}} ausgezogen. Bezeichnenderweise {{{war}}} es ihm"
      ),
      doc(
        "vimytraporhowwel0000mcka",
        "The Vimy trap, or, How we learned to stop worrying and love the Great War",
        2016,
        "McKay, Ian, 1953- author",
        "English",
        "commemoration of the {{{war}}} with the message ‘No More {{{War}}}.’ The experi- ence of the horror of {{{war}}} was transformed"
      ),
      doc(
        "narrenweisheitod0000feuc",
        "Narrenweisheit oder Tod und Verklärung des Jean-Jacques Rousseau Roman",
        1995,
        "Feuchtwanger, Lion 1884-1958 Verfasser",
        "German",
        "Käfern und Ameisen, er {{{war}}} ein Stück dieses Waldes, in ihm {{{war}}} nichts als Gefühl. Er {{{war}}} frei von der Last"
      ),
      doc(
        "dietuchvillaroma0000jaco",
        "Die Tuchvilla Roman",
        2014,
        "Jacobs, Anne Verfasser",
        "German",
        "in die Fabrik gegangen {{{war}}}. Dabei {{{war}}} diese Sorge vollkommen unnötig — Alicia {{{war}}} entschlossen, die nächtlichen"
      ),
      doc(
        "1947bis1951derzu0000boll",
        "1947 bis 1951 : Der Zug war pünktlich, Wo warst du, Adam? und sechsundzwanzig Erzühlungen",
        1964,
        "Böll, Heinrich, 1917-",
        "German",
        "geschrieben; das {{{war}}} töricht, ich {{{war}}} noch jung, aber ich habe gewußt, daß es schlecht {{{war}}} und blöde"
      ),
      doc(
        "witnessestowarhi0000ande",
        "Witnesses to war : the history of Australian conflict reporting",
        2011,
        "Anderson, Fay",
        "English",
        "and index. {{{War}}} correspondents—Australia News photographers—Australia. {{{War}}}—Press coverage. {{{War}}} in mass media"
      ),
      doc(
        "genderingglobalc0000sjob",
        "Gendering global conflict : toward a feminist theory of war",
        2013,
        "Sjoberg, Laura, 1979-",
        "English",
        "approaches to defining {{{war}}}, explaining {{{war}}}, and understanding {{{war}}}-fighting. Defining {{{War}}} Levy and Thompson"
      ),
      doc(
        "worshippingmyths0000wood",
        "Worshipping the myths of World War II : reflections on America's dedication to war",
        2006,
        "Wood, Edward W., Jr",
        "English",
        "of World {{{War}}} II Reflections on America's Dedication to {{{War}}} Is any {{{war}}} a “good {{{war}}}”? In Worshipping"
      ),
      doc(
        "stadtauslichtrom0000ekma",
        "Stadt aus Licht Roman",
        1998,
        "Ekman, Kerstin 1933- Verfasser",
        "German",
        "passierte, {{{war}}} ich fast vierzig. Es {{{war}}} im November 1973, fünf Monate vor der Revolution. Ich {{{war}}} nach Hause"
      ),
      doc(
        "isbn_4026411114705",
        "Christine",
        2005,
        "King, Stephen",
        "German",
        "ist. Vielleicht {{{war}}} es eine Vision — aber dafür {{{war}}} sie nicht spektakulär genug. Es {{{war}}} nur, dass einen"
      ),
      doc(
        "feuerthriller0000rose",
        "Feuer Thriller",
        2011,
        "Rose, Karen 1964- Verfasser",
        "German",
        "Tracey. Sie {{{war}}} hinter ihm gewesen, als er aus dem Haus gerannt {{{war}}}. Doch draußen {{{war}}} sie plötzlich"
      ),
      doc(
        "derfragebogen0000erns",
        "Der Fragebogen",
        1985,
        "Salomon, Ernst von, 1902-1972",
        "German",
        "standen {{{war}}}, Mutter {{{war}}} ja evangelisch, und Tante Therese {{{war}}} strenge Katholikin. Außerdem {{{war}}} Mutter"
      )
    ]
  end

  defp page2 do
    [
      doc(
        "diefrauenderwolk0000elke",
        "Die Frauen Der Wolkenraths (German Edition)",
        2009,
        "Elke Vesper",
        "English",
        "Meinung {{{war}}} wie die Sozialdemo- kraten. Er {{{war}}} beunruhigt. Alexander langweilte ihn, das {{{war}}} deutlich"
      ),
      doc(
        "stadtauslichtrom0000ekma",
        "Stadt aus Licht Roman",
        1998,
        "Ekman, Kerstin 1933- Verfasser",
        "German",
        "passierte, {{{war}}} ich fast vierzig. Es {{{war}}} im November 1973, fünf Monate vor der Revolution. Ich {{{war}}} nach Hause"
      ),
      doc(
        "geheimakteelvisd0000park",
        "Geheimakte Elvis die Mafia und das Rätsel um den Tod eines Idols",
        1994,
        "Parker, John Verfasser",
        "German",
        "Elvis Presley angeregt worden {{{war}}}. Für Hoover {{{war}}} Wissen Macht. Er {{{war}}} kein großer Mann, weder in seiner"
      ),
      doc(
        "dasriffderrotenh0000kons",
        "Das Riff der roten Haie : [Roman]",
        1993,
        "Konsalik, Heinz G., 1921-1999",
        "German",
        "attackieren. Die Bucht {{{war}}} zur Falle geworden! In Rons Ohren {{{war}}} ein feines, helles Singen. Es {{{war}}} nicht der Druck"
      ),
      doc(
        "leisemusikhinter0000toka",
        "Leise Musik hinter der Wand Roman",
        2013,
        "Tokareva, Viktorija Samojlovna 1937- Verfasser",
        "German",
        "Augen {{{war}}} Tante Gruscha erstaun- lich unschön: Sie {{{war}}} klein, hatte keinerlei Figur, alles {{{war}}} an einem"
      ),
      doc(
        "alegriaseptem1de0000klug",
        "Alegria Septem 1. Der Bund der Sieben",
        2007,
        "Klugmann, Norbert 1951- Verfasser",
        "German",
        "ungeschickt gewesen {{{war}}}. Dann schämte sie sich, dann {{{war}}} sie ein hilfloses kleines Mädchen. Dabei {{{war}}} sie schon"
      ),
      doc(
        "derkeltischering0000lars_h3h3",
        "Der keltische Ring Roman",
        2005,
        "Larsson, Björn 1953- Verfasser",
        "German",
        "men- schenleer {{{war}}}. Es {{{war}}} noch nie vorgekommen, daß ich der ein- zige Passagier {{{war}}}, aber bei meinen"
      ),
      doc(
        "dieintrigegrodru0000mich",
        "Die Intrige. Großdruck.",
        1997,
        "Michael Crichton",
        "English",
        "hatte. Es {{{war}}} eine hektische, ziemlich schreckliche Ar- beitsweise. Doch im nachhinein {{{war}}} ich immer"
      ),
      doc(
        "dieerbin0000john",
        "Die Erbin",
        2014,
        "John Grisham",
        "English",
        "Seils {{{war}}} eindeutig tot. Jetzt erkannte Calvin auch, wer es {{{war}}}. Und als er die Stehleiter sah, {{{war}}} ihm"
      ),
      doc(
        "furchtewasdusieh0000thom",
        "Fürchte, was du siehst Kriminalroman",
        2007,
        "Thompson, Carlene 1952- Verfasser",
        "German",
        "als Trey starb, aber das {{{war}}} etwas an- deres. Ich {{{war}}} sauer, weil er so dumm {{{war}}}, ein Motorrad zu fahren"
      ),
      doc(
        "dertanzdestigers0000kurt",
        "Der Tanz des Tigers Roman d. Eiszeit",
        1980,
        "Kurtén, Björn Verfasser",
        "German",
        "entsetzliche Ding hinter ihnen {{{war}}}, aber es {{{war}}} nichts zu sehen. «Das {{{war}}} ein Troll», sagte Tiger. «Er"
      ),
      doc(
        "saintaugustineth0000matt",
        "Saint Augustine and the theory of just war",
        2006,
        "Mattox, John Mark",
        "English",
        "just {{{war}}}, but its pursuit cannot constitute the motivation for going to {{{war}}}. Indeed, when a {{{war}}} is fought"
      ),
      doc(
        "aufdemfalschenda0000dorm",
        "Auf dem falschen Dampfer : Fragmente einer Autobiographie",
        1988,
        "Dor, Milo, 1923-2005",
        "German",
        "der Ver- nichtung {{{war}}} mir unerträglich. Ich {{{war}}} damit nicht ein- verstanden, ich {{{war}}} einfach dagegen,"
      ),
      doc(
        "derspionderausde0000john",
        "Der Spion Der Aus Der Kalte Kam",
        1964,
        "John Le Carre",
        "German",
        "bis er außer Sicht {{{war}}}. Als der Wagen fort {{{war}}}, schaute er auf seine Uhr. Es {{{war}}} vier. Er nahm an, daß"
      ),
      doc(
        "josephkerkhovens0000wass",
        "Joseph Kerkhovens dritte existenz : roman",
        1934,
        "Wassermann, Jakob, 1873-1934",
        "English",
        "Folge {{{war}}} Niederlage aui Niederlage. Die ganze Schmach {{{war}}} nun offenbar. Jetzt {{{war}}} er als"
      ),
      doc(
        "einemtagwiejeder0000haye_r1i8",
        "An einem Tag wie jeder andere Roman",
        nil,
        "Hayes, Joseph, Verfasser",
        "German",
        "Juniorpartner {{{war}}} —, Chuck hatte es leicht gehabt, ihm {{{war}}} alles zugeflogen. Er hatte Glück. Aber er {{{war}}} auch"
      ),
      doc(
        "gnadenlosroman0000clan",
        "Gnadenlos : Roman",
        2003,
        "Clancy, Tom, 1947-2013",
        "German",
        "ihr bewußt, was jetzt ihre Realität {{{war}}}. Helen {{{war}}} schlecht. Helen {{{war}}} ausgerissen, und das konnten sie"
      ),
      doc(
        "wennwirunswieder0000clar",
        "Wenn wir uns wiedersehen Roman",
        2007,
        "Clark, Mary Higgins, 1929-",
        "German",
        "ins Arbeitszimmer. Ich {{{war}}} sicher, daß Gary dort {{{war}}}. Die Tür {{{war}}} zu, ich machte sie auf"
      ),
      doc(
        "verheieneerderom0000jame",
        "Verheißene Erde. Roman.",
        1984,
        "James A. Michener",
        "English",
        "Siidafrikas gewesen {{{war}}}. Seit fast einem Jahrzehnt hatte es nur wenig geregnet ; der Boden {{{war}}} ausgedérrt, der"
      )
    ]
  end

  defp works do
    [
      work("/works/OL2621838W", "Postmodern war", 1997, 821_717, "Chris Hables Gray", [
        "postmodernwarnew0000gray_f5e2",
        "postmodernwarnew0000gray"
      ]),
      work("/works/OL5342545W", "Jovana. Roman", 1969, 3_197_744, "Utta Danella", [
        "jovana0000utta",
        "jovanaroman0000dane"
      ]),
      work("/works/OL25190788W", "The Vimy Trap", 2016, 11_980_127, "Ian McKay", [
        "vimytraporhowwel0000mcka"
      ]),
      work("/works/OL6035468W", "Fighting different wars", 2004, 358_228, "Janet S. K. Watson", [
        "fightingdifferen0000wats"
      ]),
      work(
        "/works/OL12088057W",
        "Worshipping the myths of World War II",
        2006,
        8_248_324,
        "Wood, Edward W. Jr",
        ["worshippingmyths0000wood"]
      ),
      work("/works/OL35377772W", "Wolfskinder", 2011, nil, "John Ajvide Lindqvist", [
        "wolfskinder0000john"
      ]),
      work("/works/OL15940974W", "Witnesses to war", 2011, 13_072_953, "Fay Anderson", [
        "witnessestowarhi0000ande"
      ]),
      work(
        "/works/OL17469623W",
        "Gendering Global Conflict Toward A Feminist Theory Of War",
        2013,
        7_641_439,
        "Laura Sjoberg",
        ["genderingglobalc0000sjob"]
      ),
      work("/works/OL2385346W", "L' alliance", 1980, 11_003_335, "James A. Michener", [
        "covenant2volumes0000jame",
        "lallianceroman0000mich",
        "lallianceroman0000mich_e8c0",
        "verheieneerderom0000jame",
        "lalliance0000mich",
        "bwb_P8-BLT-282_vol.1",
        "covenantthe02mich",
        "covenant02mich",
        "covena1200mich"
      ]),
      work(
        "/works/OL8585319W",
        "Saint Augustine and the theory of just war",
        2006,
        13_018_024,
        "John Mark Mattox",
        ["saintaugustineth0000matt"]
      ),
      work(
        "/works/OL12088057W",
        "Worshipping the myths of World War II",
        2006,
        8_248_324,
        "Wood, Edward W. Jr",
        ["worshippingmyths0000wood"]
      ),
      work(
        "/works/OL35370243W",
        "Die Frauen Der Wolkenraths (German Edition)",
        2009,
        nil,
        "Elke Vesper",
        ["diefrauenderwolk0000elke"]
      ),
      work("/works/OL35407040W", "Die Intrige. Großdruck.", 1997, nil, "Michael Crichton", [
        "dieintrigegrodru0000mich"
      ]),
      work("/works/OL35578817W", "Die Erbin", 2014, nil, "John Grisham", ["dieerbin0000john"])
    ]
  end
end
