defmodule DevilsDictionaryWeb.CuratorLiveTest do
  @moduledoc """
  The curator pages (#299 M7): the directory, a proposed profile, an
  admitted profile with two bindings, its immutable version pages, the bot
  source redirects and the receipt's chooser link, with one published
  choice that later expires.

  The world is `WholeEntryTest`'s: *love*, the sourced Voltaire dossier,
  a stubbed model (no model is reached) and an exact local observation as
  the published choice. Binding A (`voltaire-whole-entry-v6`) abstains once;
  binding B (`voltaire-whole-entry-v7`) publishes the observation.
  """
  use DevilsDictionaryWeb.ConnCase, async: false

  import Ecto.Query
  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.RefreshFixtures
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.RuntimeFixtures

  alias DevilsDictionary.{Registry, Repo, Sources}

  alias DevilsDictionary.Curation.{
    Configurations,
    CompositionPublication,
    CompositionVersion,
    Curators,
    Profile,
    Profiles,
    WholeEntry
  }

  alias DevilsDictionary.Curation.Agents.Persona
  alias DevilsDictionary.Curation.Runtime.{Attempt, Contract, Packet}

  @abstain_reason "Nothing supplied illuminates this fixture word today."
  @choice_reason "A synthetic fixture selection from supplied metadata."

  setup do
    w = love_world!()

    # Binding A: v6, admitted, bound, activated; one abstention.
    a = bind_persona!(w, "voltaire-whole-entry-v6", w.configuration_version.id)
    w = Map.merge(w, a) |> Map.put(:composition, provision!(Map.merge(w, a)))
    enable!(w)
    stub_answer!(w, abstention())
    assert {:ok, _} = run!(w)

    # Binding B: v7, a new dossier version, a new bot; one publication of an
    # exact observation.
    b = bind_persona!(w, "voltaire-whole-entry-v7", a.configuration_version.id)
    w = Map.merge(w, b)
    enable!(w)
    observation = DevilsDictionary.CitationFixtures.observation!(w)
    stub_answer!(w, shelf_answer(observation))
    assert {:ok, %{last_outcome_reason: "published_automatically"}} = run!(w)
    settle!()

    publication = Repo.one!(from p in CompositionPublication, where: p.action == :publish)
    version = Repo.get!(CompositionVersion, publication.published_version_id)

    Map.merge(w, %{a: a, b: b, observation: observation, published: version})
  end

  # Prepares, admits, binds and activates the Voltaire persona for a fresh
  # model config of `instruction`.
  defp bind_persona!(w, instruction, expected) do
    config =
      model_config!(%{
        instruction_version: instruction,
        output_contract_version: Contract.version(instruction),
        tag: "9b"
      })
      |> ready!()

    {:ok, seed} = Persona.prepare(w.reviewer, config, reason: "curator page test #{instruction}")

    {:ok, profile} =
      Profiles.admit(w.reviewer, seed.profile.id, seed.version.id,
        reason: "admitted for the curator page test",
        bot_actor_id: seed.bot_actor.id
      )

    {:ok, version} =
      Configurations.create_version(w.reviewer, w.configuration.id, %{
        reason: "curator page test binding #{instruction}",
        selection_scope: "whole_entry_v1",
        editor_publication: "single_editor_v1",
        refresh_window: 86_400,
        editor: %{
          profile_id: profile.id,
          profile_version_id: seed.version.id,
          model_config_id: config.id
        }
      })

    {:ok, _} =
      Configurations.activate(w.reviewer, w.configuration.id, version.id,
        reason: "curator page test activation",
        idempotency_key: key(),
        expected: expected
      )

    %{
      model_config: config,
      bot: seed.bot_actor,
      source: seed.source,
      profile: profile,
      profile_version: seed.version,
      configuration_version: version,
      editor_version: version,
      runtime: bind!(service_key: key(), actor_id: seed.bot_actor.id)
    }
  end

  defp empty_sections,
    do: Map.new(WholeEntry.sections(), &{&1, if(&1 in ["examples", "quotes"], do: [], else: nil)})

  defp abstention do
    %{
      "decision" => "abstain",
      "lead" => nil,
      "selections" => empty_sections(),
      "abstain_reason" => @abstain_reason
    }
  end

  defp shelf_answer(observation) do
    {:ok, packet} = Packet.for_page(page("love"), instruction_version: "voltaire-whole-entry-v7")
    {:ok, frozen} = Packet.freeze(packet)

    shelf =
      Enum.find(
        frozen.packet["candidates"],
        &(&1["kind"] == "shelf" and &1["shelf"]["result"] == observation.result.id)
      )

    lead =
      Enum.find(
        frozen.packet["candidates"],
        &(&1["candidate_id"] in frozen.packet["priority_candidates"])
      )

    choice = %{
      "candidate_id" => shelf["candidate_id"],
      "meaning_id" => shelf["required_meaning"],
      "reason" => @choice_reason,
      "quote" => nil
    }

    section = WholeEntry.section(shelf)
    value = if section in ["examples", "quotes"], do: [choice], else: choice

    %{
      "decision" => "select",
      "lead" => %{
        "candidate_id" => lead["candidate_id"],
        "meaning_id" => lead["required_meaning"],
        "reason" => "A supplied sourced definition."
      },
      "selections" => Map.put(empty_sections(), section, value),
      "abstain_reason" => nil
    }
  end

  defp expire!(provider \\ "guardian") do
    config = Application.fetch_env!(:devils_dictionary, :discovery)
    policies = Keyword.get(config, :source_policies, %{})
    policy = Keyword.put(Map.get(policies, provider, []), :retention_seconds, 0)

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(config, :source_policies, Map.put(policies, provider, policy))
    )

    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, config) end)
  end

  defp html(conn, path), do: conn |> get(path) |> html_response(200)

  describe "the directory" do
    test "shows the real roster with truthful states, and the footer lists no bot",
         %{conn: conn} = w do
      {:ok, view, html} = live(conn, ~p"/curators")
      assert has_element?(view, "#curator-card-voltaire")
      assert html =~ "Inspired by Voltaire"
      assert html =~ "version 2 · voltaire-whole-entry-v7"
      assert html =~ "1 page published · 2 model calls"
      assert html =~ "bound in the current configuration"

      # The four other identities are proposed: listed, never active.
      proposed = view |> element("#curators-proposed") |> render()

      for label <- ~w(Bierce Vonnegut Hitchens Le\ Guin),
          do: assert(proposed =~ label)

      refute has_element?(view, "#curators-admitted #curator-card-bierce")

      # A noindex surface (`Indexing`), like every page but the two exceptions.
      assert conn |> get(~p"/curators/voltaire") |> html_response(200) =~
               ~s(name="robots" content="noindex")

      # CD-2: a curator's bot principal is no provider.
      footer = html |> LazyHTML.from_document() |> LazyHTML.query("footer") |> LazyHTML.text()
      assert footer =~ "Curators"
      refute footer =~ "Inspired by Voltaire"
      refute w.source.slug in Enum.map(Sources.list_providers(), & &1.slug)
      assert w.source.slug in Enum.map(Sources.list_sources(), & &1.slug)
    end
  end

  describe "a proposed profile" do
    test "says it has not been used and invents no activity", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/curators/bierce")
      assert view |> element("#curator-state") |> render() =~ "PROPOSED"
      assert html =~ "Not yet used on any page"
      assert has_element?(view, "#curator-no-dossier")
      assert has_element?(view, "#curator-no-binding")
      refute has_element?(view, "#curator-activity")
      refute has_element?(view, "#curator-cost-total")
      refute html =~ "attempt "
    end

    test "links its subject's entry by Wikidata identity, never by name", %{conn: conn} do
      {:ok, impostor} = Registry.create_person(%{preferred_label: "Ambrose Bierce"})
      {:ok, view, _html} = live(conn, ~p"/curators/bierce")
      refute view |> element("#curator-subject") |> render() =~ "/entities/#{impostor.object_id}"

      # The fixtures' Bierce carries his verified identity.
      person =
        case Registry.by_external_id("wikidata", "Q191050") do
          nil ->
            {:ok, person} = Registry.create_person(%{preferred_label: "Ambrose Bierce"})
            {:ok, _} = Registry.add_external_id(person.object_id, "wikidata", "Q191050")
            person

          object ->
            object
        end

      {:ok, view, _html} = live(conn, ~p"/curators/bierce")
      subject = view |> element("#curator-subject") |> render()
      assert subject =~ "their entry on this site"
      assert subject =~ DevilsDictionary.Routing.Links.path(object_id(person), "Ambrose Bierce")
      refute subject =~ "no entry on this site yet"
    end

    test "a dossier passage whose rights do not permit it shows only its reference",
         %{conn: conn} = w do
      bierce = Repo.get_by!(Profile, slug: "bierce")

      {:ok, _version} =
        Profiles.add_version(w.reviewer, bierce.id, %{
          dossier: %{"selection" => "Prefer the exact satirical entry."},
          source_refs: [
            %{
              "work" => "A restricted fixture work",
              "rights" => "All rights reserved; cited by reference only.",
              "passages" => [
                %{
                  "locator" => "p. 1",
                  "speaker" => "the author",
                  "text" => "A restricted passage never shown."
                }
              ]
            }
          ],
          deceased_evidence_refs: [],
          template_version: "generic-editor-v2",
          reason: "rights test"
        })

      {:ok, view, html} = live(conn, ~p"/curators/bierce")
      source = view |> element("#curator-source-1") |> render()
      assert source =~ "A restricted fixture work"
      assert source =~ "All rights reserved"
      assert source =~ "its rights note does not permit showing it"
      refute html =~ "A restricted passage never shown."
      assert Curators.passages_permitted?("Public domain in the USA; two short passages.")
      refute Curators.passages_permitted?("All rights reserved")
    end
  end

  describe "an admitted profile with two bindings" do
    test "shows the four layers, both bindings and every recorded call", %{conn: conn} = w do
      {:ok, view, html} = live(conn, ~p"/curators/voltaire")
      text = text(html)

      labels =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query(".layer-label")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert labels == [
               "The recorded result",
               "The dossier we authored",
               "Inherited model knowledge",
               "The instruction and context supplied"
             ]

      assert view |> element("#curator-state") |> render() =~ "ADMITTED"
      assert text =~ "not a reconstruction of their beliefs"
      assert text =~ "A pretrained model's general knowledge"
      assert text =~ "No fine-tuning"

      # Both bindings, anchored by their bots.
      assert has_element?(view, "#binding-#{w.a.bot.id}")
      assert has_element?(view, "#binding-#{w.b.bot.id}")
      assert view |> element("#binding-#{w.a.bot.id}") |> render() =~ w.a.model_config.config_hash

      # Every call, newest first: B's publication, then A's abstention.
      [b_attempt, a_attempt] =
        Repo.all(from a in Attempt, order_by: [desc: a.id], select: a.id)

      published = view |> element("#curator-attempt-#{b_attempt}") |> render()
      assert published =~ "published version #{w.published.version}"
      assert published =~ ~s(href="/on/love/receipt/#{w.published.version}")
      assert published =~ "voltaire-whole-entry-v7"
      assert view |> element("#curator-attempt-#{a_attempt}") |> render() =~ "abstained"

      totals = part(view, "#curator-totals")
      assert totals =~ "2 model calls · 1 accepted · 1 abstained · 0 refused"
      assert totals =~ "1 page published"
      assert totals =~ "0 later withheld"

      # Cost per binding and in total; no money.
      assert has_element?(view, "#curator-cost-#{w.a.bot.id}")
      assert has_element?(view, "#curator-cost-#{w.b.bot.id}")
      total = view |> element("#curator-cost-total") |> render()
      assert total =~ "2 calls"
      assert total =~ "1,800 prompt and 240 output tokens"
      refute html =~ "$"

      # The dossier verbatim, its public-domain passages with their speakers.
      assert html =~ Persona.manifest()["dossier"]["disclosure"]
      assert html =~ "the nose has been formed to bear spectacles"
      assert html =~ "Pangloss (fictional character)"
      assert html =~ "catalogue.bnf.fr"
      assert view |> element("#curator-subject") |> render() =~ "no entry on this site yet"

      # The instruction by version and sha, summarized, never quoted.
      instruction = view |> element("#curator-instruction") |> render()

      sha =
        DevilsDictionary.Curation.Digest.sha256(Packet.instruction!("voltaire-whole-entry-v7"))

      assert instruction =~ sha
      assert instruction =~ "lead-first evidence policy"

      # Judgments, as developer judgments.
      assert html =~ "not independent review"
      assert part(view, "#curator-judged") =~ "NO-GO"

      # Versions, with the admission of the current one.
      assert has_element?(view, "#curator-version-1")
      assert view |> element("#curator-version-2") |> render() =~ "current"
      assert view |> element("#curator-version-2") |> render() =~ "Admitted"
      assert view |> element("#curator-version-2") |> render() =~ "a reviewer (actor "
    end

    test "an expired choice is counted as withheld, by reason", %{conn: conn} do
      expire!()
      {:ok, view, _html} = live(conn, ~p"/curators/voltaire")
      totals = part(view, "#curator-totals")
      assert totals =~ "2 choices placed · 1 later withheld because the cited observation expired"

      assert part(view, "#curator-withheld-now") =~
               "1 because the selected observation's retention window has expired"
    end

    test "an owner hold and a withdrawal appear as what they are", %{conn: conn} = w do
      {:ok, _} =
        DevilsDictionary.Curation.Compositions.set_mode(w.reviewer, w.composition.id, :mine, [])

      withdraw!(w, w.composition)
      {:ok, view, html} = live(conn, ~p"/curators/voltaire")
      assert part(view, "#curator-holds") =~ "love since"

      assert html =~
               "version #{w.published.version} withdrawn by a reviewer: #259 test withdrawal"

      assert part(view, "#curator-totals") =~ "1 withdrawal by a reviewer"
    end
  end

  describe "version pages" do
    test "each immutable version shows its own dossier, instruction and users",
         %{conn: conn} = w do
      {:ok, view, html} = live(conn, ~p"/curators/voltaire/v/1")
      assert part(view, "#curator-version-status") =~ "Version 1 of 2: superseded"
      assert html =~ "voltaire-whole-entry-v6"
      assert has_element?(view, "#binding-#{w.a.bot.id}")
      refute has_element?(view, "#binding-#{w.b.bot.id}")
      assert html =~ "No page was published under this version"

      {:ok, view, _html} = live(conn, ~p"/curators/voltaire/v/2")
      assert part(view, "#curator-version-status") =~ "the current version"
      used = view |> element("#curator-version-published") |> render()
      assert used =~ "published version #{w.published.version}"
      assert used =~ ~s(href="/on/love/receipt/#{w.published.version}")
      assert has_element?(view, ~s(a[href="/curators/voltaire/v/1"]))
    end

    test "an unknown curator or version is 404", %{conn: conn} do
      for path <-
            ~w(/curators/nobody /curators/voltaire/v/9 /curators/voltaire/v/0 /curators/voltaire/v/two) do
        assert_error_sent 404, fn -> get(conn, path) end
      end
    end
  end

  describe "links in" do
    test "a bot source page redirects to its binding on the curator page", %{conn: conn} = w do
      for binding <- [w.a, w.b] do
        conn = get(conn, "/sources/#{binding.source.slug}")
        assert redirected_to(conn, 302) == "/curators/voltaire#binding-#{binding.bot.id}"
      end

      # A provider's page is untouched.
      assert conn |> get("/sources/bierce") |> html_response(200) =~ "source-header"

      # The generic editor, once admitted, redirects to its own page.
      config = model_config!(%{instruction_version: "generic-editor-v2"})
      {:ok, seed} = Profiles.seed_generic_editor(w.reviewer, config, reason: "seed for redirect")
      assert redirected_to(get(conn, "/sources/generic-editor"), 302) == "/curators"

      {:ok, _} =
        Profiles.admit(w.reviewer, seed.profile.id, seed.version.id,
          reason: "admit for redirect",
          bot_actor_id: seed.bot_actor.id
        )

      assert redirected_to(get(conn, "/sources/generic-editor"), 302) ==
               "/curators/generic-editor#binding-#{seed.bot_actor.id}"
    end

    test "the receipt links its chooser to the exact curator version", %{conn: conn} = w do
      receipt = html(conn, "/on/love/receipt/#{w.published.version}")
      assert receipt =~ ~s(href="/curators/voltaire/v/2")
      assert receipt =~ w.b.bot.label

      # A newer version does not move what the old receipt cites.
      c = bind_persona!(w, "voltaire-whole-entry-v5", w.b.configuration_version.id)
      assert Repo.reload!(c.profile).current_version_id != w.b.profile_version.id

      assert html(conn, "/on/love/receipt/#{w.published.version}") =~
               ~s(href="/curators/voltaire/v/2")
    end
  end

  describe "privacy (#299 M5)" do
    test "no curator surface carries a payload, a prompt, a model's words or an email",
         %{conn: conn} = w do
      pages =
        Enum.map(
          ~w(/curators /curators/voltaire /curators/voltaire/v/1 /curators/voltaire/v/2 /curators/bierce),
          &html(conn, &1)
        )

      payload_strings =
        Repo.query!("SELECT payload FROM source_record_revisions").rows
        |> Enum.flat_map(fn [payload] -> strings(payload) end)
        |> Enum.filter(&(String.length(&1) >= 20))
        |> Enum.uniq()

      assert "A distinctive headline with five particular unusual words" in payload_strings

      dossier_lines =
        [Persona.manifest()["dossier"]["disclosure"], Persona.manifest()["dossier"]["selection"]]

      instruction_lines =
        Packet.instruction_versions()
        |> Enum.flat_map(&String.split(Packet.instruction!(&1), "\n"))
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(String.length(&1) >= 40))
        |> Enum.reject(fn line -> Enum.any?(dossier_lines, &String.contains?(&1, line)) end)
        |> Enum.uniq()

      for html <- pages do
        text = html |> LazyHTML.from_document() |> LazyHTML.text()

        for s <- payload_strings, do: refute(String.contains?(text, s), "payload text: #{s}")
        for l <- instruction_lines, do: refute(String.contains?(text, l), "prompt text: #{l}")
        refute text =~ @abstain_reason
        refute text =~ @choice_reason
        refute text =~ w.reviewer.user.email
      end
    end

    test "every pinned instruction has a reviewed summary that does not quote it" do
      assert Curators.summarized() == Packet.instruction_versions()

      for version <- Packet.instruction_versions() do
        summary = Curators.summary(version)
        assert summary =~ ~r/\A# /

        for line <- Packet.instruction!(version) |> String.split("\n") |> Enum.map(&String.trim/1),
            String.length(line) >= 40,
            not String.starts_with?(line, Persona.manifest()["dossier"]["disclosure"]),
            do: refute(String.contains?(summary, line), "#{version} quotes: #{line}")
      end
    end
  end

  defp object_id(%{object_id: id}), do: id
  defp object_id(id) when is_integer(id), do: id

  # An element's visible text, whitespace collapsed.
  defp part(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.replace(~r/\s+/u, " ")

  # A page's visible text, whitespace collapsed.
  defp text(html),
    do: html |> LazyHTML.from_document() |> LazyHTML.text() |> String.replace(~r/\s+/u, " ")

  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&strings/1)
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(_value), do: []
end
