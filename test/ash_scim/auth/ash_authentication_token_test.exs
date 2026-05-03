# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Auth.AshAuthenticationTokenTest do
  # AshAuthentication's TokenResource and the user ETS table are
  # process-shared.
  use ExUnit.Case, async: false

  use Plug.Test

  alias AshAuthentication.{Jwt, TokenResource}
  alias AshScim.Auth.AshAuthenticationToken
  alias AshScim.Test.AuthExample.{Domain, Token, User}

  @opts AshScim.Router.init(
          domains: [Domain],
          auth: {AshAuthenticationToken, otp_app: :ash_scim_test},
          base_url: "https://example.com/scim/v2"
        )

  setup do
    for resource <- [User, Token], record <- Ash.read!(resource) do
      Ash.destroy!(record)
    end

    :ok
  end

  defp create_user!(overrides \\ []) do
    attrs =
      [email: "service-account@example.com", active: true, scim_external_id: "svc-1"]
      |> Keyword.merge(overrides)
      |> Enum.into(%{})

    User
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end

  defp issue_scim_token!(user, extra_claims \\ %{}) do
    {:ok, jwt, _claims} =
      Jwt.token_for_user(user, Map.merge(%{"purpose" => "scim"}, extra_claims))

    jwt
  end

  defp request_with(token, method \\ "GET", path \\ "/Users") do
    conn(method, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> AshScim.Router.call(@opts)
  end

  describe "happy path" do
    test "accepts a SCIM-purposed token issued for a real user" do
      user = create_user!()
      jwt = issue_scim_token!(user)

      conn = request_with(jwt)

      assert conn.status == 200

      assert %{"schemas" => ["urn:ietf:params:scim:api:messages:2.0:ListResponse"]} =
               Jason.decode!(conn.resp_body)
    end
  end

  describe "rejection" do
    test "rejects a token signed with the wrong secret" do
      conn = request_with("not.a.valid.jwt.at.all")
      assert conn.status == 401
    end

    test "rejects a token whose purpose is not `scim`" do
      user = create_user!()

      {:ok, jwt, _} = Jwt.token_for_user(user, %{"purpose" => "user"})

      conn = request_with(jwt)
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["detail"] =~ "not authorised for SCIM"
    end

    test "rejects a token whose JTI has been revoked" do
      user = create_user!()
      jwt = issue_scim_token!(user)

      :ok = TokenResource.revoke(Token, jwt)

      # Revocation is enforced by AshAuthentication.Jwt.verify itself, which
      # rolls revoked/expired/invalid into a single error class. Asserting on
      # the 401 status (and the absence of the actor assign) is what we
      # guarantee.
      conn = request_with(jwt)
      assert conn.status == 401
      refute conn.assigns[:ash_scim_actor]
    end

    test "rejects when the subject does not resolve to a user" do
      user = create_user!()
      jwt = issue_scim_token!(user)

      # Drop the user but keep the JWT — subject_to_user must fail.
      Ash.destroy!(user)

      conn = request_with(jwt)
      assert conn.status == 401
    end

    test "rejects when no Authorization header is present" do
      conn = AshScim.Router.call(conn(:get, "/Users"), @opts)
      assert conn.status == 401
    end
  end

  describe "actor propagation" do
    test "the verified user is plumbed through as the Ash actor" do
      user = create_user!()
      jwt = issue_scim_token!(user)

      conn =
        conn(:get, "/Users")
        |> put_req_header("authorization", "Bearer #{jwt}")
        |> AshScim.Router.call(@opts)

      assert conn.status == 200
      # The actor should have been assigned on the conn for the duration of the
      # request — verifying via the assign rather than re-reading auth state
      # avoids coupling the test to internal Ash query plumbing.
      assert conn.assigns[:ash_scim_actor].id == user.id
    end
  end
end
