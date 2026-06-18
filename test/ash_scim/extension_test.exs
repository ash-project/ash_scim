# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.ExtensionTest do
  use ExUnit.Case, async: true

  alias AshScim.{Decoder, Discovery, Encoder, Patch}
  alias AshScim.Test.Example.User

  @enterprise "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User"

  describe "decode/2 — extension" do
    test "extracts nested complex sub-attributes from an extension object" do
      decoded =
        Decoder.decode(User, %{
          "userName" => "alice@example.com",
          @enterprise => %{
            "manager" => %{"value" => "boss@example.com", "displayName" => "The Boss"}
          }
        })

      assert decoded.attrs == %{
               email: "alice@example.com",
               manager_value: "boss@example.com",
               manager_display_name: "The Boss"
             }
    end

    test "ignores a missing or non-object extension" do
      assert Decoder.decode(User, %{"userName" => "a@b.com"}).attrs == %{email: "a@b.com"}
    end
  end

  describe "encode/2 — extension" do
    test "emits the extension object under its URN and lists it in schemas" do
      record =
        struct(User,
          email: "alice@example.com",
          id: Ash.UUID.generate(),
          manager_value: "boss@example.com",
          manager_display_name: "The Boss"
        )

      body = Encoder.encode(record)

      assert body[@enterprise] == %{
               "manager" => %{"value" => "boss@example.com", "displayName" => "The Boss"}
             }

      assert @enterprise in body["schemas"]
    end

    test "omits the extension (and URN) when its attributes are nil" do
      record = struct(User, email: "alice@example.com", id: Ash.UUID.generate())
      body = Encoder.encode(record)

      refute Map.has_key?(body, @enterprise)
      refute @enterprise in body["schemas"]
    end
  end

  describe "discovery — extension" do
    test "resource type advertises the extension and a schema doc is emitted" do
      assert %{"schemaExtensions" => [%{"schema" => @enterprise, "required" => false}]} =
               Discovery.resource_type(User)

      ext_schema = Enum.find(Discovery.schemas([User])["Resources"], &(&1["id"] == @enterprise))
      assert ext_schema
      assert Enum.any?(ext_schema["attributes"], &(&1["name"] == "manager"))
    end
  end

  describe "patch — extension" do
    test "applies a fully-qualified extension sub-attribute path" do
      {:ok, params} =
        Patch.to_params(
          %{
            "Operations" => [
              %{
                "op" => "replace",
                "path" => "#{@enterprise}:manager.value",
                "value" => "boss@example.com"
              }
            ]
          },
          User
        )

      assert params.attrs == %{manager_value: "boss@example.com"}
    end

    test "applies an extension complex path with an object value" do
      {:ok, params} =
        Patch.to_params(
          %{
            "Operations" => [
              %{
                "op" => "replace",
                "path" => "#{@enterprise}:manager",
                "value" => %{"value" => "boss@example.com", "displayName" => "The Boss"}
              }
            ]
          },
          User
        )

      assert params.attrs == %{
               manager_value: "boss@example.com",
               manager_display_name: "The Boss"
             }
    end

    test "applies a path-less op carrying the extension object" do
      {:ok, params} =
        Patch.to_params(
          %{
            "Operations" => [
              %{
                "op" => "replace",
                "value" => %{@enterprise => %{"manager" => %{"value" => "boss@example.com"}}}
              }
            ]
          },
          User
        )

      assert params.attrs == %{manager_value: "boss@example.com"}
    end
  end
end
