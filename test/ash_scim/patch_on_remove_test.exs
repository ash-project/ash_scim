# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.PatchOnRemoveTest do
  # ETS data layer is process-shared.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AshScim.Patch
  alias AshScim.Test.OnRemoveExample.{Domain, User}

  @opts AshScim.Router.init(
          domains: [Domain],
          auth: {AshScim.Auth.StaticBearer, tokens: ["secret"]},
          base_url: "https://example.com/scim/v2"
        )

  defp body(operations), do: %{"Operations" => operations}

  describe "on_remove option on single-attribute multivalueds" do
    test "default :set_nil writes nil to the underlying attribute" do
      assert {:ok, %{attrs: %{email: nil}, relationships: []}} =
               Patch.to_params(
                 body([%{"op" => "remove", "path" => "default_emails"}]),
                 User
               )
    end

    test ":ignore returns success without touching the data" do
      assert {:ok, %{attrs: attrs, relationships: []}} =
               Patch.to_params(
                 body([%{"op" => "remove", "path" => "ignored_emails"}]),
                 User
               )

      assert attrs == %{}
    end

    test ":reject returns a SCIM mutability error" do
      assert {:error, {:mutability, :rejected_emails}} =
               Patch.to_params(
                 body([%{"op" => "remove", "path" => "rejected_emails"}]),
                 User
               )
    end

    test "on_remove only affects :remove — :replace still writes" do
      ops = [
        %{
          "op" => "replace",
          "path" => "ignored_emails",
          "value" => [%{"value" => "new@example.com", "primary" => true}]
        }
      ]

      assert {:ok, %{attrs: %{email: "new@example.com"}, relationships: []}} =
               Patch.to_params(body(ops), User)
    end
  end

  describe "router integration" do
    setup do
      for record <- Ash.read!(User), do: Ash.destroy!(record)
      :ok
    end

    defp user_fixture do
      User
      |> Ash.Changeset.for_create(:create, %{email: "alice@example.com"})
      |> Ash.create!()
    end

    defp request(method, path, body) do
      conn(method, path, body)
      |> put_req_header("authorization", "Bearer secret")
      |> put_req_header("content-type", "application/scim+json")
      |> AshScim.Router.call(@opts)
    end

    test ":ignore PATCH returns 200 and the resource is unchanged" do
      user = user_fixture()

      patch_body =
        Jason.encode!(%{
          "Operations" => [%{"op" => "remove", "path" => "ignored_emails"}]
        })

      conn = request("PATCH", "/Users/#{user.id}", patch_body)

      assert conn.status == 200

      reread = Ash.get!(User, user.id)
      assert to_string(reread.email) == "alice@example.com"
    end

    test ":reject PATCH returns 400 with scimType `mutability`" do
      user = user_fixture()

      patch_body =
        Jason.encode!(%{
          "Operations" => [%{"op" => "remove", "path" => "rejected_emails"}]
        })

      conn = request("PATCH", "/Users/#{user.id}", patch_body)

      assert conn.status == 400
      decoded = Jason.decode!(conn.resp_body)
      assert decoded["scimType"] == "mutability"
      assert decoded["detail"] =~ "rejected_emails"
    end
  end
end
