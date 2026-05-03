# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.RouterAuthContextTest do
  @moduledoc """
  End-to-end test that an `AshScim.Auth` implementation can stash arbitrary
  request-scoped context on the conn, and that the router threads it through
  every Ash call so resources can use it in `change`s and `prepare`s.

  The realistic shape: two SCIM clients (Okta + Azure AD) hit the same
  endpoint with separate JWTs. Each JWT carries a `scim_source` claim. The
  custom `AshScim.Test.SourceExample.Auth` implementation verifies the JWT,
  extracts the claim, and sets it via `Ash.PlugHelpers.set_context/2`. The
  resource's create-time `change` stamps `:scim_source` from that context;
  the read-time `prepare` filters by it.

  Net effect: even though Okta and Azure AD share one users table, neither
  can see or mutate users belonging to the other.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AshAuthentication.Jwt
  alias AshScim.Test.SourceExample.{Auth, Domain, Token, User}

  @opts AshScim.Router.init(
          domains: [Domain],
          auth: {Auth, []},
          base_url: "https://example.com/scim/v2"
        )

  setup do
    for resource <- [User, Token], record <- Ash.read!(resource) do
      Ash.destroy!(record)
    end

    :ok
  end

  defp create_user!(source, attrs) do
    User
    |> Ash.Changeset.for_create(:create, attrs, context: %{private: %{scim_source: source}})
    |> Ash.create!()
  end

  defp jwt_for(user, source) do
    {:ok, jwt, _claims} =
      Jwt.token_for_user(user, %{"purpose" => "scim", "scim_source" => source})

    jwt
  end

  defp request(method, path, jwt, body \\ nil) do
    conn(method, path, body)
    |> put_req_header("authorization", "Bearer #{jwt}")
    |> then(fn c ->
      if body, do: put_req_header(c, "content-type", "application/scim+json"), else: c
    end)
    |> AshScim.Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "auth context flows to changesets" do
    test "POST /Users stamps the request's scim_source onto the new record" do
      service = create_user!("okta", %{email: "okta-svc@example.com"})
      jwt = jwt_for(service, "okta")

      conn =
        request(
          "POST",
          "/Users",
          jwt,
          Jason.encode!(%{"userName" => "alice@okta.example", "externalId" => "okta-1"})
        )

      assert conn.status == 201

      [%User{scim_source: "okta", email: alice_email}] =
        Ash.read!(User)
        |> Enum.filter(&(to_string(&1.email) == "alice@okta.example"))

      assert to_string(alice_email) == "alice@okta.example"
    end

    test "two different sources stamp their own value" do
      okta_svc = create_user!("okta", %{email: "okta-svc@example.com"})
      azure_svc = create_user!("azure", %{email: "azure-svc@example.com"})

      okta_jwt = jwt_for(okta_svc, "okta")
      azure_jwt = jwt_for(azure_svc, "azure")

      assert request(
               "POST",
               "/Users",
               okta_jwt,
               Jason.encode!(%{"userName" => "alice@okta.example"})
             ).status == 201

      assert request(
               "POST",
               "/Users",
               azure_jwt,
               Jason.encode!(%{"userName" => "alice@azure.example"})
             ).status == 201

      sources_by_email =
        User
        |> Ash.read!()
        |> Enum.reject(&String.contains?(to_string(&1.email), "svc@"))
        |> Enum.into(%{}, &{to_string(&1.email), &1.scim_source})

      assert sources_by_email == %{
               "alice@okta.example" => "okta",
               "alice@azure.example" => "azure"
             }
    end
  end

  describe "auth context flows to queries" do
    test "GET /Users only returns users owned by the requesting source" do
      okta_svc = create_user!("okta", %{email: "okta-svc@example.com"})
      _ = create_user!("okta", %{email: "alice@okta.example"})
      _ = create_user!("azure", %{email: "alice@azure.example"})

      okta_jwt = jwt_for(okta_svc, "okta")

      conn = request("GET", "/Users", okta_jwt)
      assert conn.status == 200

      decoded = body(conn)

      emails =
        decoded["Resources"]
        |> Enum.map(& &1["userName"])
        |> Enum.sort()

      # Service accounts created via the test helper also live in the same
      # table — both are scoped through the same prepare. The point: no
      # azure-source records are visible to the okta-source request.
      assert "alice@okta.example" in emails
      refute "alice@azure.example" in emails
    end

    test "GET /Users/:id returns 404 for a record owned by another source" do
      okta_svc = create_user!("okta", %{email: "okta-svc@example.com"})
      azure_user = create_user!("azure", %{email: "alice@azure.example"})

      okta_jwt = jwt_for(okta_svc, "okta")

      conn = request("GET", "/Users/#{azure_user.id}", okta_jwt)
      assert conn.status == 404
    end
  end

  describe "rejection" do
    test "rejects a JWT without a scim_source claim" do
      service = create_user!("okta", %{email: "okta-svc@example.com"})

      {:ok, jwt, _} = Jwt.token_for_user(service, %{"purpose" => "scim"})

      conn = request("GET", "/Users", jwt)
      assert conn.status == 401
      assert body(conn)["detail"] =~ "scim_source"
    end

    test "rejects a JWT whose purpose isn't scim" do
      service = create_user!("okta", %{email: "okta-svc@example.com"})

      {:ok, jwt, _} = Jwt.token_for_user(service, %{"scim_source" => "okta"})

      conn = request("GET", "/Users", jwt)
      assert conn.status == 401
    end
  end
end
