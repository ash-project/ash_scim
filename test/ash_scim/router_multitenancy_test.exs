# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.RouterMultitenancyTest do
  # ETS data layer is process-shared.
  use ExUnit.Case, async: false

  use Plug.Test

  alias AshScim.Test.TenantExample.{Domain, User}

  @opts AshScim.Router.init(
          domains: [Domain],
          auth: {AshScim.Auth.StaticBearer, tokens: ["secret"]},
          base_url: "https://example.com/scim/v2"
        )

  setup do
    for tenant <- ["acme", "globex"],
        record <- Ash.read!(User, tenant: tenant) do
      Ash.destroy!(record, tenant: tenant)
    end

    :ok
  end

  defp request(method, path, tenant, body \\ nil) do
    conn(method, path, body)
    |> put_req_header("authorization", "Bearer secret")
    |> Ash.PlugHelpers.set_tenant(tenant)
    |> then(fn c ->
      if body, do: put_req_header(c, "content-type", "application/scim+json"), else: c
    end)
    |> AshScim.Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp create_user!(tenant, attrs) do
    User
    |> Ash.Changeset.for_create(:create, attrs, tenant: tenant)
    |> Ash.create!()
  end

  describe "tenant-scoped reads" do
    test "GET /Users only returns the requesting tenant's users" do
      _ = create_user!("acme", %{email: "alice@acme.example", scim_external_id: "okta-1"})
      _ = create_user!("acme", %{email: "bob@acme.example", scim_external_id: "okta-2"})
      _ = create_user!("globex", %{email: "charlie@globex.example", scim_external_id: "okta-3"})

      conn = request("GET", "/Users", "acme")

      assert conn.status == 200
      decoded = body(conn)
      assert decoded["totalResults"] == 2

      emails = decoded["Resources"] |> Enum.map(& &1["userName"]) |> Enum.sort()
      assert emails == ["alice@acme.example", "bob@acme.example"]
    end

    test "GET /Users without tenant returns no records (per Ash global?: false)" do
      _ = create_user!("acme", %{email: "alice@acme.example", scim_external_id: "okta-1"})

      # No tenant set on the conn — request is rejected at the data layer.
      conn =
        conn(:get, "/Users")
        |> put_req_header("authorization", "Bearer secret")
        |> AshScim.Router.call(@opts)

      assert conn.status in [400, 500]
    end

    test "filters can't escape the tenant" do
      acme_user = create_user!("acme", %{email: "alice@acme.example", scim_external_id: "okta-1"})

      _ =
        create_user!("globex", %{
          email: "alice@globex.example",
          scim_external_id: "okta-other"
        })

      # Filter for "alice" — there's a matching user in BOTH tenants, but
      # only the acme one should come back.
      conn =
        request(
          "GET",
          "/Users?filter=" <> URI.encode("userName co \"alice\""),
          "acme"
        )

      assert conn.status == 200
      decoded = body(conn)
      assert decoded["totalResults"] == 1

      [resource] = decoded["Resources"]
      assert resource["id"] == to_string(acme_user.id)
      assert resource["userName"] == "alice@acme.example"
    end
  end

  describe "tenant-scoped show" do
    test "GET /Users/:id returns the resource only when the requesting tenant matches" do
      acme_user = create_user!("acme", %{email: "alice@acme.example", scim_external_id: "okta-1"})

      conn = request("GET", "/Users/#{acme_user.id}", "acme")
      assert conn.status == 200

      conn2 = request("GET", "/Users/#{acme_user.id}", "globex")
      assert conn2.status == 404
    end
  end

  describe "tenant-scoped writes" do
    test "POST /Users creates the user under the requesting tenant" do
      body =
        Jason.encode!(%{
          "userName" => "new@acme.example",
          "externalId" => "okta-new"
        })

      conn = request("POST", "/Users", "acme", body)
      assert conn.status == 201

      created_id = body(conn)["id"]
      assert {:ok, [%User{tenant_id: "acme"}]} = Ash.read(User, tenant: "acme")
      refute Enum.any?(Ash.read!(User, tenant: "globex"), &(&1.id == created_id))
    end

    test "PUT /Users/:id can't modify another tenant's record" do
      acme_user = create_user!("acme", %{email: "alice@acme.example", scim_external_id: "okta-1"})

      body =
        Jason.encode!(%{
          "userName" => "alice@acme.example",
          "externalId" => "MUTATED"
        })

      conn = request("PUT", "/Users/#{acme_user.id}", "globex", body)
      assert conn.status == 404

      # Confirm acme's record is untouched.
      [reread] = Ash.read!(User, tenant: "acme")
      assert reread.scim_external_id == "okta-1"
    end

    test "DELETE /Users/:id can't delete another tenant's record" do
      acme_user = create_user!("acme", %{email: "alice@acme.example", scim_external_id: "okta-1"})

      conn = request("DELETE", "/Users/#{acme_user.id}", "globex")
      assert conn.status == 404

      assert [%User{}] = Ash.read!(User, tenant: "acme")
    end
  end

  describe "tenant-scoped PATCH" do
    test "PATCH succeeds for the right tenant" do
      acme_user = create_user!("acme", %{email: "alice@acme.example", scim_external_id: "okta-1"})

      body =
        Jason.encode!(%{
          "Operations" => [
            %{"op" => "replace", "path" => "externalId", "value" => "okta-renamed"}
          ]
        })

      conn = request("PATCH", "/Users/#{acme_user.id}", "acme", body)
      assert conn.status == 200
      assert body(conn)["externalId"] == "okta-renamed"
    end

    test "PATCH 404s when the requesting tenant doesn't own the record" do
      acme_user = create_user!("acme", %{email: "alice@acme.example", scim_external_id: "okta-1"})

      body =
        Jason.encode!(%{
          "Operations" => [
            %{"op" => "replace", "path" => "externalId", "value" => "okta-mutated"}
          ]
        })

      conn = request("PATCH", "/Users/#{acme_user.id}", "globex", body)
      assert conn.status == 404

      [reread] = Ash.read!(User, tenant: "acme")
      assert reread.scim_external_id == "okta-1"
    end
  end
end
