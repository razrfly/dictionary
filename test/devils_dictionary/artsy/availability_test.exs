defmodule DevilsDictionary.Artsy.AvailabilityTest do
  # `async: true` keeps this test's sandbox unshared, which is what lets the
  # task below reach the `DBConnection.OwnershipError` path on purpose.
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Artsy.{Availability, RequestCoordinator}

  setup do
    {:ok, coordinator} = RequestCoordinator.start_link(name: nil)
    %{coordinator: coordinator}
  end

  test "a live but disabled coordinator withdraws the provider", ctx do
    assert Availability.status_with_credentials("id", "secret", ctx.coordinator) == :ok

    {:ok, _generation} = RequestCoordinator.disable(ctx.coordinator)

    assert Availability.status_with_credentials("id", "secret", ctx.coordinator) ==
             {:error, :source_withdrawn}
  end

  test "withdrawal still wins when the database is unreachable", ctx do
    {:ok, _generation} = RequestCoordinator.disable(ctx.coordinator)

    # No sandbox ownership in this process, so reading source lifecycle raises
    # DBConnection.OwnershipError and the rescue clause decides. The coordinator
    # is in memory and remains authoritative, so the answer must not be `:ok`.
    result =
      Task.async(fn ->
        Availability.status_with_credentials("id", "secret", ctx.coordinator)
      end)
      |> Task.await()

    assert result == {:error, :source_withdrawn}
  end

  test "missing credentials are still reported when the database is unreachable", ctx do
    result =
      Task.async(fn ->
        Availability.status_with_credentials("", "", ctx.coordinator)
      end)
      |> Task.await()

    assert result == {:error, :credentials_missing}
  end

  test "a dead coordinator fails closed", ctx do
    Process.unlink(ctx.coordinator)
    Process.exit(ctx.coordinator, :kill)
    refute Process.alive?(ctx.coordinator)

    assert Availability.status_with_credentials("id", "secret", ctx.coordinator) ==
             {:error, :source_withdrawn}
  end
end
