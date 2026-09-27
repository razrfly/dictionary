defmodule Mix.Tasks.Dd.Curation.SeedTest do
  @moduledoc """
  `mix dd.curation.seed` writes drafts and identities only. It activates,
  approves and publishes nothing, and a re-run changes nothing.
  """

  use DevilsDictionary.DataCase, async: false

  alias DevilsDictionary.Curation.{
    CompositionPublication,
    CompositionReview,
    Configuration,
    ConfigurationActivation,
    Configurations,
    Profile
  }

  alias Mix.Tasks.Dd.Curation.Seed

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "seeds a draft default and five proposed identities, twice to the same effect" do
    Seed.run([])
    Seed.run([])

    assert_received {:mix_shell, :info, ["global-default: draft, version 1 " <> _]}
    assert_received {:mix_shell, :info, ["profiles: bierce (proposed), voltaire (proposed)" <> _]}
    assert_received {:mix_shell, :info, ["resolution: {:unavailable, :no_active_version}"]}

    assert [%Configuration{state: :draft, current_version_id: nil}] = Repo.all(Configuration)
    assert Repo.aggregate(Profile, :count) == 5
    assert Repo.all(from p in Profile, where: p.state != :proposed) == []

    for schema <- [ConfigurationActivation, CompositionReview, CompositionPublication] do
      assert Repo.aggregate(schema, :count) == 0
    end

    assert Configurations.resolve_default() == {:unavailable, :no_active_version}
  end
end
