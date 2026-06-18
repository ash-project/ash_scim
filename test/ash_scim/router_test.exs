# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.RouterTest do
  # ETS data layer is process-shared; tests must run serially and clean up
  # between cases.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AshScim.Test.Example.{Domain, Group, User}

  @opts AshScim.Router.init(
          domains: [Domain],
          auth: {AshScim.Auth.StaticBearer, tokens: ["secret"]},
          base_url: "https://example.com/scim/v2"
        )

  setup do
    # Reset the ETS tables between tests so list/filter assertions are deterministic.
    for resource <- [User, Group], record <- Ash.read!(resource) do
      Ash.destroy!(record)
    end

    :ok
  end

  defp request(method, path, body \\ nil, headers \\ []) do
    conn =
      conn(method, path, body)
      |> put_req_header("authorization", "Bearer secret")

    conn =
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    conn =
      if body do
        put_req_header(conn, "content-type", "application/scim+json")
      else
        conn
      end

    AshScim.Router.call(conn, @opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp create_user!(overrides \\ []) do
    attrs =
      [
        email: "alice@example.com",
        active: true,
        first_name: "Alice",
        last_name: "Anderson",
        scim_external_id: "okta-1"
      ]
      |> Keyword.merge(overrides)
      |> Enum.into(%{})

    User
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end

  describe "authentication" do
    test "rejects requests without a bearer token" do
      conn = AshScim.Router.call(conn(:get, "/Users"), @opts)

      assert conn.status == 401
      assert body(conn)["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
    end

    test "rejects requests with the wrong token" do
      conn =
        conn(:get, "/Users")
        |> put_req_header("authorization", "Bearer nope")
        |> AshScim.Router.call(@opts)

      assert conn.status == 401
    end
  end

  describe "GET /<type>" do
    test "lists users in a SCIM ListResponse envelope" do
      _ = create_user!()
      _ = create_user!(email: "bob@example.com", scim_external_id: "okta-2")

      conn = request("GET", "/Users")

      assert conn.status == 200

      assert %{
               "schemas" => ["urn:ietf:params:scim:api:messages:2.0:ListResponse"],
               "totalResults" => 2,
               "Resources" => resources
             } = body(conn)

      assert length(resources) == 2

      assert Enum.all?(
               resources,
               &(&1["schemas"] == ["urn:ietf:params:scim:schemas:core:2.0:User"])
             )
    end

    test "applies a filter when ?filter= is provided" do
      _ = create_user!()
      _ = create_user!(email: "bob@example.com", scim_external_id: "okta-2")

      conn = request("GET", "/Users?filter=" <> URI.encode("userName eq \"bob@example.com\""))

      assert conn.status == 200
      assert %{"totalResults" => 1, "Resources" => [resource]} = body(conn)
      assert resource["userName"] == "bob@example.com"
    end

    test "returns 400 invalidFilter on bad filter syntax" do
      conn = request("GET", "/Users?filter=" <> URI.encode("garbage"))

      assert conn.status == 400
      assert body(conn)["scimType"] == "invalidFilter"
    end

    test "returns 400 invalidFilter on unknown attribute" do
      conn =
        request("GET", "/Users?filter=" <> URI.encode("password eq \"hunter2\""))

      assert conn.status == 400
      assert body(conn)["scimType"] == "invalidFilter"
      assert body(conn)["detail"] =~ "password"
    end
  end

  describe "GET /<type> pagination, sorting, projection" do
    setup do
      _ =
        create_user!(email: "alice@example.com", scim_external_id: "okta-1", first_name: "Alice")

      _ =
        create_user!(email: "bob@example.com", scim_external_id: "okta-2", first_name: "Bob")

      _ =
        create_user!(email: "carol@example.com", scim_external_id: "okta-3", first_name: "Carol")

      :ok
    end

    test "respects ?count= and ?startIndex=" do
      conn = request("GET", "/Users?count=2&startIndex=1")

      assert conn.status == 200
      decoded = body(conn)
      assert decoded["totalResults"] == 3
      assert decoded["startIndex"] == 1
      assert decoded["itemsPerPage"] == 2
      assert length(decoded["Resources"]) == 2

      conn2 = request("GET", "/Users?count=2&startIndex=3")
      decoded2 = body(conn2)
      assert decoded2["startIndex"] == 3
      assert length(decoded2["Resources"]) == 1
    end

    test "rejects non-positive count/startIndex" do
      conn = request("GET", "/Users?count=0")
      assert conn.status == 400

      conn2 = request("GET", "/Users?startIndex=-1")
      assert conn2.status == 400
    end

    test "respects ?sortBy= and ?sortOrder=" do
      conn = request("GET", "/Users?sortBy=userName&sortOrder=ascending")
      ordered = Enum.map(body(conn)["Resources"], & &1["userName"])
      assert ordered == ["alice@example.com", "bob@example.com", "carol@example.com"]

      conn2 = request("GET", "/Users?sortBy=userName&sortOrder=descending")
      ordered2 = Enum.map(body(conn2)["Resources"], & &1["userName"])
      assert ordered2 == ["carol@example.com", "bob@example.com", "alice@example.com"]
    end

    test "rejects sortBy on an unmapped attribute" do
      conn = request("GET", "/Users?sortBy=password")
      assert conn.status == 400
    end

    test "?attributes= keeps only the named fields plus id/schemas/meta" do
      conn = request("GET", "/Users?attributes=userName")
      [first | _] = body(conn)["Resources"]

      assert Map.has_key?(first, "userName")
      assert Map.has_key?(first, "id")
      assert Map.has_key?(first, "schemas")
      refute Map.has_key?(first, "active")
      refute Map.has_key?(first, "name")
      refute Map.has_key?(first, "emails")
    end

    test "?attributes= with a dotted path projects sub-attributes" do
      user = create_user!(email: "dotted@example.com", scim_external_id: "okta-dotted")

      conn = request("GET", "/Users/#{user.id}?attributes=name.givenName")
      decoded = body(conn)

      assert decoded["name"] == %{"givenName" => "Alice"}
      refute Map.has_key?(decoded, "userName")
    end

    test "?excludedAttributes= strips the named fields but keeps id/schemas/meta" do
      user = create_user!(email: "excl@example.com", scim_external_id: "okta-excl")

      conn = request("GET", "/Users/#{user.id}?excludedAttributes=userName,name")
      decoded = body(conn)

      refute Map.has_key?(decoded, "userName")
      refute Map.has_key?(decoded, "name")
      assert Map.has_key?(decoded, "id")
      assert Map.has_key?(decoded, "schemas")
      assert Map.has_key?(decoded, "meta")
    end
  end

  describe "GET /<type>/:id" do
    test "returns a single user" do
      user = create_user!()

      conn = request("GET", "/Users/#{user.id}")

      assert conn.status == 200
      decoded = body(conn)
      assert decoded["id"] == to_string(user.id)
      assert decoded["userName"] == "alice@example.com"
      assert decoded["meta"]["location"] =~ "/Users/" <> to_string(user.id)
    end

    test "returns 404 for a nonexistent id" do
      conn = request("GET", "/Users/00000000-0000-0000-0000-000000000000")

      assert conn.status == 404
    end
  end

  describe "POST /<type>" do
    test "creates a user from a SCIM JSON body" do
      body =
        Jason.encode!(%{
          "userName" => "carol@example.com",
          "active" => true,
          "name" => %{"givenName" => "Carol", "familyName" => "Carlsen"},
          "externalId" => "okta-3"
        })

      conn = request("POST", "/Users", body)

      assert conn.status == 201
      decoded = body(conn)
      assert decoded["userName"] == "carol@example.com"
      assert decoded["name"]["givenName"] == "Carol"
      assert decoded["externalId"] == "okta-3"
      assert decoded["id"]
    end

    test "rejects malformed JSON" do
      conn = request("POST", "/Users", "{ not json")
      assert conn.status == 400
      assert body(conn)["scimType"] == "invalidSyntax"
    end
  end

  describe "PUT /<type>/:id" do
    test "replaces the user's mapped attributes" do
      user = create_user!()

      body =
        Jason.encode!(%{
          "userName" => "alice@example.com",
          "active" => false,
          "name" => %{"givenName" => "Alicia", "familyName" => "Anderson"},
          "externalId" => "okta-1"
        })

      conn = request("PUT", "/Users/#{user.id}", body)

      assert conn.status == 200
      decoded = body(conn)
      assert decoded["active"] == false
      assert decoded["name"]["givenName"] == "Alicia"
    end
  end

  describe "PATCH /<type>/:id" do
    test "applies a replace op to a simple attribute" do
      user = create_user!()

      body =
        Jason.encode!(%{
          "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
          "Operations" => [
            %{"op" => "replace", "path" => "active", "value" => false}
          ]
        })

      conn = request("PATCH", "/Users/#{user.id}", body)

      assert conn.status == 200
      assert body(conn)["active"] == false
    end

    test "applies a replace op to a complex sub-attribute" do
      user = create_user!()

      body =
        Jason.encode!(%{
          "Operations" => [
            %{"op" => "replace", "path" => "name.givenName", "value" => "Alicia"}
          ]
        })

      conn = request("PATCH", "/Users/#{user.id}", body)

      assert conn.status == 200
      assert body(conn)["name"]["givenName"] == "Alicia"
    end

    test "merges multiple ops in a single update" do
      user = create_user!()

      body =
        Jason.encode!(%{
          "Operations" => [
            %{"op" => "replace", "path" => "active", "value" => false},
            %{"op" => "replace", "path" => "name.givenName", "value" => "Al"}
          ]
        })

      conn = request("PATCH", "/Users/#{user.id}", body)

      assert conn.status == 200
      decoded = body(conn)
      assert decoded["active"] == false
      assert decoded["name"]["givenName"] == "Al"
    end

    test "returns 400 invalidPath for unmapped paths" do
      user = create_user!()

      body =
        Jason.encode!(%{
          "Operations" => [%{"op" => "replace", "path" => "password", "value" => "x"}]
        })

      conn = request("PATCH", "/Users/#{user.id}", body)

      assert conn.status == 400
      assert body(conn)["scimType"] == "invalidPath"
    end

    test "returns 404 for a nonexistent user" do
      body =
        Jason.encode!(%{
          "Operations" => [%{"op" => "replace", "path" => "active", "value" => false}]
        })

      conn = request("PATCH", "/Users/00000000-0000-0000-0000-000000000000", body)

      assert conn.status == 404
    end
  end

  describe "DELETE /<type>/:id" do
    test "destroys the user and returns 204" do
      user = create_user!()

      conn = request("DELETE", "/Users/#{user.id}")

      assert conn.status == 204
      assert conn.resp_body == ""

      conn2 = request("GET", "/Users/#{user.id}")
      assert conn2.status == 404
    end
  end

  describe "GET /ServiceProviderConfig" do
    test "returns the ServiceProviderConfig document" do
      conn = request("GET", "/ServiceProviderConfig")

      assert conn.status == 200
      decoded = body(conn)

      assert decoded["schemas"] == [
               "urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"
             ]

      assert decoded["filter"]["supported"] == true
      assert decoded["patch"]["supported"] == true
      assert decoded["sort"]["supported"] == true
    end
  end

  describe "GET /Schemas" do
    test "lists every configured resource's Schema document" do
      conn = request("GET", "/Schemas")

      assert conn.status == 200
      decoded = body(conn)
      assert decoded["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:ListResponse"]
      # Two resource schemas (User, Group) plus the User's enterprise extension schema.
      assert decoded["totalResults"] == 3

      ids = Enum.map(decoded["Resources"], & &1["id"])
      assert "urn:ietf:params:scim:schemas:core:2.0:User" in ids
      assert "urn:ietf:params:scim:schemas:core:2.0:Group" in ids
      assert "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User" in ids
    end

    test "returns a single Schema document by id" do
      conn = request("GET", "/Schemas/urn:ietf:params:scim:schemas:core:2.0:User")

      assert conn.status == 200
      decoded = body(conn)
      assert decoded["id"] == "urn:ietf:params:scim:schemas:core:2.0:User"
      assert decoded["name"] == "User"

      attribute_names = Enum.map(decoded["attributes"], & &1["name"])
      assert "userName" in attribute_names
      assert "name" in attribute_names
      assert "emails" in attribute_names

      name_def = Enum.find(decoded["attributes"], &(&1["name"] == "name"))
      assert name_def["type"] == "complex"
      sub_names = Enum.map(name_def["subAttributes"], & &1["name"])
      assert "givenName" in sub_names
      assert "familyName" in sub_names

      emails_def = Enum.find(decoded["attributes"], &(&1["name"] == "emails"))
      assert emails_def["multiValued"] == true
    end

    test "404 for unknown schema id" do
      conn = request("GET", "/Schemas/urn:not-a-real-thing")
      assert conn.status == 404
    end
  end

  describe "GET /ResourceTypes" do
    test "lists every configured resource's ResourceType document" do
      conn = request("GET", "/ResourceTypes")

      assert conn.status == 200
      decoded = body(conn)
      assert decoded["totalResults"] == 2

      types = Enum.map(decoded["Resources"], & &1["name"])
      assert "User" in types
      assert "Group" in types
    end

    test "returns a single ResourceType by name" do
      conn = request("GET", "/ResourceTypes/User")

      assert conn.status == 200
      decoded = body(conn)
      assert decoded["name"] == "User"
      assert decoded["endpoint"] == "/Users"
      assert decoded["schema"] == "urn:ietf:params:scim:schemas:core:2.0:User"
    end

    test "404 for unknown resource type" do
      conn = request("GET", "/ResourceTypes/NotARealType")
      assert conn.status == 404
    end
  end

  describe "unknown paths" do
    test "returns 404" do
      conn = request("GET", "/NotARealEndpoint")
      assert conn.status == 404
    end
  end
end
