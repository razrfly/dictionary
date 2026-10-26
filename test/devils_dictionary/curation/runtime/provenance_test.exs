defmodule DevilsDictionary.Curation.Runtime.ProvenanceTest do
  @moduledoc """
  Registering a served model as a pinned config (`Runtime.Provenance`): the
  instruction it runs is chosen, never defaulted, and the same artifact under
  another instruction is another immutable row (#254 P7). This is how
  `qwen3.5-9b-v2` is made beside `qwen3.5-9b-v1`.
  """
  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.RuntimeFixtures

  alias DevilsDictionary.Curation.Runtime.{ModelConfig, Provenance}

  setup do
    actor = actor!(account([:reviewer]))
    # A served 4B whose manifest is on the fake external root.
    served = model_config!() |> ready!()
    stub_ollama!(served)
    %{actor: actor, served: served}
  end

  defp register(ctx, slug, opts),
    do: Provenance.register(ctx.served.model_name, slug, ctx.actor.id, opts)

  test "the instruction is chosen, never defaulted", ctx do
    assert {:error, {:unsupported_instruction_version, nil}} = register(ctx, "no-instruction", [])

    assert {:error, {:unsupported_instruction_version, "generic-editor-v9"}} =
             register(ctx, "unknown", instruction_version: "generic-editor-v9")

    refute Repo.get_by(ModelConfig, slug: "no-instruction")
    refute Repo.get_by(ModelConfig, slug: "unknown")
  end

  test "the same artifact under another instruction is another row; the same one is the same row",
       ctx do
    assert {:ok, v1} = register(ctx, "served-v1", instruction_version: "generic-editor-v1")
    assert {:ok, v2} = register(ctx, "served-v2", instruction_version: "generic-editor-v2")

    assert {v1.instruction_version, v2.instruction_version} ==
             {"generic-editor-v1", "generic-editor-v2"}

    assert v1.manifest_digest == v2.manifest_digest
    refute v1.config_hash == v2.config_hash

    # Registering v2 again finds its row, whatever slug is asked for.
    assert {:ok, again} =
             register(ctx, "served-v2-again", instruction_version: "generic-editor-v2")

    assert again.id == v2.id
  end
end
