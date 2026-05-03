# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.ProjectionTest do
  use ExUnit.Case, async: true

  alias AshScim.Projection

  defp resource do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:User"],
      "id" => "abc",
      "userName" => "alice@example.com",
      "active" => true,
      "name" => %{"givenName" => "Alice", "familyName" => "Anderson"},
      "emails" => [%{"value" => "alice@example.com", "primary" => true}],
      "meta" => %{"resourceType" => "User"}
    }
  end

  describe "no params" do
    test "returns the resource unchanged" do
      assert Projection.apply(resource(), %{}) == resource()
    end

    test "treats empty strings as no-ops" do
      assert Projection.apply(resource(), %{"attributes" => "", "excludedAttributes" => ""}) ==
               resource()
    end
  end

  describe "?attributes=" do
    test "keeps only the named top-level fields plus id/schemas/meta" do
      result = Projection.apply(resource(), %{"attributes" => "userName,active"})

      assert Map.keys(result) |> Enum.sort() == ~w(active id meta schemas userName)
    end

    test "narrows complex objects to a single sub-attribute by dotted path" do
      result = Projection.apply(resource(), %{"attributes" => "name.givenName"})

      assert result["name"] == %{"givenName" => "Alice"}
    end

    test "strips a complex object's sibling sub-attributes" do
      result = Projection.apply(resource(), %{"attributes" => "name.givenName"})

      refute Map.has_key?(result["name"], "familyName")
    end
  end

  describe "?excludedAttributes=" do
    test "removes the named fields" do
      result = Projection.apply(resource(), %{"excludedAttributes" => "userName,emails"})

      refute Map.has_key?(result, "userName")
      refute Map.has_key?(result, "emails")
      assert Map.has_key?(result, "active")
    end

    test "preserves id/schemas/meta even if listed" do
      result = Projection.apply(resource(), %{"excludedAttributes" => "id,schemas,meta"})

      assert Map.has_key?(result, "id")
      assert Map.has_key?(result, "schemas")
      assert Map.has_key?(result, "meta")
    end

    test "removes a single sub-attribute via dotted path" do
      result = Projection.apply(resource(), %{"excludedAttributes" => "name.familyName"})

      assert result["name"] == %{"givenName" => "Alice"}
    end
  end
end
