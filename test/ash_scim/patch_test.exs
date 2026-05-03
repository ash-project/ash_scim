# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.PatchTest do
  use ExUnit.Case, async: true

  alias AshScim.Patch
  alias AshScim.Test.Example.{Group, User}

  defp body(operations), do: %{"Operations" => operations}

  describe "replace with simple paths" do
    test "translates a single replace to its Ash attribute" do
      assert {:ok, %{attrs: %{active: false}, relationships: []}} =
               Patch.to_params(
                 body([%{"op" => "replace", "path" => "active", "value" => false}]),
                 User
               )
    end

    test "translates a complex sub-attribute path" do
      assert {:ok, %{attrs: %{first_name: "Alicia"}, relationships: []}} =
               Patch.to_params(
                 body([%{"op" => "replace", "path" => "name.givenName", "value" => "Alicia"}]),
                 User
               )
    end

    test "merges multiple replace ops, last write wins per attribute" do
      ops = [
        %{"op" => "replace", "path" => "active", "value" => false},
        %{"op" => "replace", "path" => "userName", "value" => "alice2@example.com"},
        %{"op" => "replace", "path" => "active", "value" => true}
      ]

      assert {:ok, %{attrs: %{active: true, email: "alice2@example.com"}, relationships: []}} =
               Patch.to_params(body(ops), User)
    end

    test "unwraps single-element value arrays (some IdPs send arrays)" do
      assert {:ok, %{attrs: %{first_name: "Alicia"}, relationships: []}} =
               Patch.to_params(
                 body([%{"op" => "replace", "path" => "name.givenName", "value" => ["Alicia"]}]),
                 User
               )
    end
  end

  describe "add operations" do
    test "with a path behaves like replace for simple attributes" do
      assert {:ok, %{attrs: %{first_name: "Alicia"}, relationships: []}} =
               Patch.to_params(
                 body([%{"op" => "add", "path" => "name.givenName", "value" => "Alicia"}]),
                 User
               )
    end

    test "without a path decodes the value as a partial SCIM resource" do
      ops = [
        %{
          "op" => "add",
          "value" => %{
            "userName" => "alice@example.com",
            "name" => %{"givenName" => "Alice"}
          }
        }
      ]

      assert {:ok,
              %{attrs: %{email: "alice@example.com", first_name: "Alice"}, relationships: []}} =
               Patch.to_params(body(ops), User)
    end
  end

  describe "remove operations" do
    test "set the mapped attribute to nil" do
      assert {:ok, %{attrs: %{first_name: nil}, relationships: []}} =
               Patch.to_params(
                 body([%{"op" => "remove", "path" => "name.givenName"}]),
                 User
               )
    end

    test "without a path is rejected" do
      assert {:error, _} = Patch.to_params(body([%{"op" => "remove"}]), User)
    end
  end

  describe "errors" do
    test "rejects unknown SCIM paths with :invalid_path" do
      assert {:error, {:invalid_path, "password"}} =
               Patch.to_params(
                 body([%{"op" => "replace", "path" => "password", "value" => "x"}]),
                 User
               )

      assert {:error, {:invalid_path, "name.middleName"}} =
               Patch.to_params(
                 body([%{"op" => "replace", "path" => "name.middleName", "value" => "x"}]),
                 User
               )
    end

    test "tolerates unknown attribute names *inside* a bracket filter on single-attr multivalued" do
      assert {:ok, %{attrs: %{email: "x"}, relationships: []}} =
               Patch.to_params(
                 body([
                   %{
                     "op" => "replace",
                     "path" => ~S(emails[notARealField eq "work"].value),
                     "value" => "x"
                   }
                 ]),
                 User
               )
    end

    test "rejects unknown ops" do
      assert {:error, _} =
               Patch.to_params(
                 body([%{"op" => "morph", "path" => "userName", "value" => "x"}]),
                 User
               )
    end

    test "rejects bodies without an Operations array" do
      assert {:error, _} = Patch.to_params(%{"foo" => "bar"}, User)
    end
  end

  describe "bracket-filter paths on single-attribute multivalued" do
    test "`attr[filter]` resolves to the multivalued's default value attribute" do
      assert {:ok, %{attrs: %{email: "new@example.com"}, relationships: []}} =
               Patch.to_params(
                 body([
                   %{
                     "op" => "replace",
                     "path" => ~S(emails[type eq "work"]),
                     "value" => "new@example.com"
                   }
                 ]),
                 User
               )
    end

    test "`attr[filter].sub` resolves to the named sub-attribute" do
      assert {:ok, %{attrs: %{email: "new@example.com"}, relationships: []}} =
               Patch.to_params(
                 body([
                   %{
                     "op" => "replace",
                     "path" => ~S(emails[type eq "work"].value),
                     "value" => "new@example.com"
                   }
                 ]),
                 User
               )
    end

    test "remove with a bracket path nils the underlying attribute" do
      assert {:ok, %{attrs: %{email: nil}, relationships: []}} =
               Patch.to_params(
                 body([
                   %{
                     "op" => "remove",
                     "path" => ~S(emails[type eq "work"].value)
                   }
                 ]),
                 User
               )
    end

    test "syntactically invalid bracket filters fail with :invalid_path" do
      assert {:error, {:invalid_path, _}} =
               Patch.to_params(
                 body([
                   %{
                     "op" => "replace",
                     "path" => ~S(emails[not a filter].value),
                     "value" => "x"
                   }
                 ]),
                 User
               )
    end
  end

  describe "bare multivalued path on single-attribute multivalued" do
    test "scalar value resolves to the multivalued's `:value`-mapped attribute" do
      assert {:ok, %{attrs: %{email: "new@example.com"}, relationships: []}} =
               Patch.to_params(
                 body([%{"op" => "replace", "path" => "emails", "value" => "new@example.com"}]),
                 User
               )
    end

    test "array-of-objects value extracts the underlying attribute via sub-maps" do
      ops = [
        %{
          "op" => "replace",
          "path" => "emails",
          "value" => [
            %{"value" => "new@example.com", "primary" => true, "type" => "work"}
          ]
        }
      ]

      assert {:ok, %{attrs: %{email: "new@example.com"}, relationships: []}} =
               Patch.to_params(body(ops), User)
    end

    test "array-of-objects with multiple entries picks the primary one" do
      ops = [
        %{
          "op" => "replace",
          "path" => "emails",
          "value" => [
            %{"value" => "alt@example.com", "primary" => false},
            %{"value" => "primary@example.com", "primary" => true}
          ]
        }
      ]

      assert {:ok, %{attrs: %{email: "primary@example.com"}, relationships: []}} =
               Patch.to_params(body(ops), User)
    end

    test "`add` with array-of-objects also extracts via sub-maps" do
      ops = [
        %{
          "op" => "add",
          "path" => "emails",
          "value" => [%{"value" => "new@example.com", "primary" => true}]
        }
      ]

      assert {:ok, %{attrs: %{email: "new@example.com"}, relationships: []}} =
               Patch.to_params(body(ops), User)
    end

    test "`remove` clears all sub-map-backed attributes" do
      ops = [%{"op" => "remove", "path" => "emails"}]

      # Only :email is attribute-backed in the example User's :emails
      # multivalued; :primary and :type are static-value mappings.
      assert {:ok, %{attrs: %{email: nil}, relationships: []}} =
               Patch.to_params(body(ops), User)
    end
  end

  describe "relationship-backed multivalued (Group.members)" do
    test "`add path: \"members\" value: [...]` produces an :append op" do
      ops = [
        %{
          "op" => "add",
          "path" => "members",
          "value" => [%{"value" => "u1"}, %{"value" => "u2"}]
        }
      ]

      assert {:ok,
              %{
                attrs: %{},
                relationships: [
                  {:append, :memberships, [%{user_id: "u1"}, %{user_id: "u2"}]}
                ]
              }} = Patch.to_params(body(ops), Group)
    end

    test "`replace path: \"members\" value: [...]` produces a :replace_all op" do
      ops = [
        %{"op" => "replace", "path" => "members", "value" => [%{"value" => "u1"}]}
      ]

      assert {:ok,
              %{
                attrs: %{},
                relationships: [{:replace_all, :memberships, [%{user_id: "u1"}]}]
              }} = Patch.to_params(body(ops), Group)
    end

    test "`remove path: \"members[value eq \\\"u1\\\"]\"` produces a :remove_where op with the resolved filter" do
      ops = [
        %{"op" => "remove", "path" => ~S(members[value eq "u1"])}
      ]

      assert {:ok,
              %{
                attrs: %{},
                relationships: [
                  {:remove_where, :memberships, %{user_id: %{eq: "u1"}}}
                ]
              }} = Patch.to_params(body(ops), Group)
    end

    test "rejects per-element :replace via bracket filter (currently unsupported)" do
      ops = [
        %{
          "op" => "replace",
          "path" => ~S(members[value eq "u1"].value),
          "value" => "u2"
        }
      ]

      assert {:error, {:invalid_path, _}} = Patch.to_params(body(ops), Group)
    end

    test "rejects an unknown attribute name inside a relationship bracket filter" do
      ops = [%{"op" => "remove", "path" => ~S(members[notReal eq "x"])}]
      assert {:error, {:invalid_path, _}} = Patch.to_params(body(ops), Group)
    end
  end
end
