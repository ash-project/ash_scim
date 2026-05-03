# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.RouterGroupsTest do
  # ETS data layer is process-shared.
  use ExUnit.Case, async: false

  use Plug.Test

  alias AshScim.Test.Example.{Domain, Group, Membership}

  @opts AshScim.Router.init(
          domains: [Domain],
          auth: {AshScim.Auth.StaticBearer, tokens: ["secret"]},
          base_url: "https://example.com/scim/v2"
        )

  setup do
    for resource <- [Group, Membership], record <- Ash.read!(resource) do
      Ash.destroy!(record)
    end

    :ok
  end

  defp request(method, path, body \\ nil) do
    conn =
      conn(method, path, body)
      |> put_req_header("authorization", "Bearer secret")

    conn =
      if body do
        put_req_header(conn, "content-type", "application/scim+json")
      else
        conn
      end

    AshScim.Router.call(conn, @opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp create_group_with_members!(name, member_ids) do
    body =
      Jason.encode!(%{
        "displayName" => name,
        "members" => Enum.map(member_ids, &%{"value" => &1})
      })

    conn = request("POST", "/Groups", body)
    assert conn.status == 201
    body(conn)
  end

  describe "POST /Groups" do
    test "creates a Group and its membership rows from `members` array" do
      created =
        create_group_with_members!("engineering", ["user-a", "user-b"])

      assert created["displayName"] == "engineering"
      assert created["members"] |> Enum.map(& &1["value"]) |> Enum.sort() == ["user-a", "user-b"]

      memberships = Ash.read!(Membership)
      assert length(memberships) == 2
      assert Enum.map(memberships, & &1.user_id) |> Enum.sort() == ["user-a", "user-b"]
    end
  end

  describe "GET /Groups/:id" do
    test "emits the members array reflecting current memberships" do
      group = create_group_with_members!("engineering", ["user-a", "user-b"])

      conn = request("GET", "/Groups/#{group["id"]}")

      assert conn.status == 200
      decoded = body(conn)
      assert decoded["displayName"] == "engineering"

      assert decoded["members"] |> Enum.map(& &1["value"]) |> Enum.sort() ==
               ["user-a", "user-b"]
    end
  end

  describe "PATCH add path: members" do
    test "appends new memberships without removing existing ones" do
      group = create_group_with_members!("engineering", ["user-a"])

      patch_body =
        Jason.encode!(%{
          "Operations" => [
            %{"op" => "add", "path" => "members", "value" => [%{"value" => "user-b"}]}
          ]
        })

      conn = request("PATCH", "/Groups/#{group["id"]}", patch_body)

      assert conn.status == 200

      assert body(conn)["members"] |> Enum.map(& &1["value"]) |> Enum.sort() ==
               ["user-a", "user-b"]
    end
  end

  describe "PATCH replace path: members" do
    test "replaces the full membership set" do
      group = create_group_with_members!("engineering", ["user-a", "user-b"])

      patch_body =
        Jason.encode!(%{
          "Operations" => [
            %{"op" => "replace", "path" => "members", "value" => [%{"value" => "user-c"}]}
          ]
        })

      conn = request("PATCH", "/Groups/#{group["id"]}", patch_body)

      assert conn.status == 200
      assert body(conn)["members"] |> Enum.map(& &1["value"]) == ["user-c"]

      remaining_user_ids =
        Ash.read!(Membership) |> Enum.map(& &1.user_id) |> Enum.sort()

      assert remaining_user_ids == ["user-c"]
    end
  end

  describe "PATCH remove path: members[value eq id]" do
    test "removes only the matching membership row" do
      group = create_group_with_members!("engineering", ["user-a", "user-b", "user-c"])

      patch_body =
        Jason.encode!(%{
          "Operations" => [
            %{"op" => "remove", "path" => ~S(members[value eq "user-b"])}
          ]
        })

      conn = request("PATCH", "/Groups/#{group["id"]}", patch_body)

      assert conn.status == 200

      assert body(conn)["members"] |> Enum.map(& &1["value"]) |> Enum.sort() ==
               ["user-a", "user-c"]

      remaining_user_ids =
        Ash.read!(Membership) |> Enum.map(& &1.user_id) |> Enum.sort()

      assert remaining_user_ids == ["user-a", "user-c"]
    end

    test "is a no-op when the filter matches no rows" do
      group = create_group_with_members!("engineering", ["user-a"])

      patch_body =
        Jason.encode!(%{
          "Operations" => [
            %{"op" => "remove", "path" => ~S(members[value eq "ghost"])}
          ]
        })

      conn = request("PATCH", "/Groups/#{group["id"]}", patch_body)

      assert conn.status == 200
      assert body(conn)["members"] |> Enum.map(& &1["value"]) == ["user-a"]
    end
  end
end
