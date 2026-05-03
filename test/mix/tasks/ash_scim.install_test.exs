# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshScim.InstallTest do
  use ExUnit.Case

  import Igniter.Test

  @moduletag :igniter

  defp installed_user_project do
    test_project()
    |> Igniter.Project.Deps.add_dep({:picosat_elixir, ">= 0.0.0"})
    |> Igniter.Project.Deps.add_dep({:ash_authentication, ">= 0.0.0"})
    |> Igniter.compose_task("ash_authentication.install", ["--yes"])
    # Add the password strategy so the user resource gets an `:email`
    # attribute — that's what triggers the installer's `multivalued :emails`
    # default.
    |> Igniter.compose_task("ash_authentication.add_strategy", ["password", "--yes"])
    |> Igniter.Project.Formatter.remove_imported_dep(:ash_authentication)
    |> Igniter.Project.Formatter.remove_formatter_plugin(Spark.Formatter)
    |> apply_igniter!()
  end

  describe "mix ash_scim.install" do
    setup do
      [igniter: installed_user_project()]
    end

    test "adds the AshScim.User extension to the user resource", %{igniter: igniter} do
      igniter
      |> Igniter.compose_task("ash_scim.install", ["--yes"])
      |> assert_has_patch("lib/test/accounts/user.ex", """
      |    extensions: [AshScim.User, AshAuthentication]
      """)
    end

    test "adds a scim do block with sensible default mappings", %{igniter: igniter} do
      igniter
      |> Igniter.compose_task("ash_scim.install", ["--yes"])
      |> assert_has_patch("lib/test/accounts/user.ex", """
      |  scim do
      """)
      |> assert_has_patch("lib/test/accounts/user.ex", """
      |    map(:userName, attribute: :email)
      """)
      |> assert_has_patch("lib/test/accounts/user.ex", """
      |    map(:externalId, attribute: :scim_external_id)
      """)
      |> assert_has_patch("lib/test/accounts/user.ex", """
      |    multivalued :emails do
      """)
    end

    test "adds the scim_external_id and active attributes", %{igniter: igniter} do
      result =
        igniter
        |> Igniter.compose_task("ash_scim.install", ["--yes"])

      assert_has_patch(result, "lib/test/accounts/user.ex", """
      |    attribute :scim_external_id, :string do
      """)

      assert_has_patch(result, "lib/test/accounts/user.ex", """
      |    attribute :active, :boolean do
      """)
    end

    test "adds the AshScim.Checks.AshScimInteraction bypass", %{igniter: igniter} do
      igniter
      |> Igniter.compose_task("ash_scim.install", ["--yes"])
      |> assert_has_patch("lib/test/accounts/user.ex", """
      |    bypass AshScim.Checks.AshScimInteraction do
      """)
    end

    test "generates a SCIM router module under the web module by default",
         %{igniter: igniter} do
      result =
        igniter
        |> Igniter.compose_task("ash_scim.install", ["--yes"])

      assert_creates(result, "lib/test_web/scim_router.ex")
    end

    test "the generated router is wired to AshScim.Router with the accounts domain",
         %{igniter: igniter} do
      igniter
      |> Igniter.compose_task("ash_scim.install", ["--yes"])
      |> assert_has_patch("lib/test_web/scim_router.ex", """
      |  use AshScim.Router,
      """)
      |> assert_has_patch("lib/test_web/scim_router.ex", """
      |    domains: [Test.Accounts],
      """)
    end

    test "auth defaults to AshAuthenticationToken when ash_authentication is present",
         %{igniter: igniter} do
      igniter
      |> Igniter.compose_task("ash_scim.install", ["--yes"])
      |> assert_has_patch("lib/test_web/scim_router.ex", """
      |    auth: {AshScim.Auth.AshAuthenticationToken, otp_app: :test}
      """)
    end

    test "is idempotent — running twice doesn't double-add anything",
         %{igniter: igniter} do
      first = Igniter.compose_task(igniter, "ash_scim.install", ["--yes"]) |> apply_igniter!()
      second = Igniter.compose_task(first, "ash_scim.install", ["--yes"])

      # No new diff on the second run.
      assert_unchanged(second)
    end
  end

  describe "mix ash_scim.install --user / --router overrides" do
    setup do
      [igniter: installed_user_project()]
    end

    test "respects --router for the generated module name", %{igniter: igniter} do
      igniter
      |> Igniter.compose_task("ash_scim.install", [
        "--yes",
        "--router",
        "Test.Custom.ScimRouter"
      ])
      |> assert_creates("lib/test/custom/scim_router.ex")
    end
  end
end
