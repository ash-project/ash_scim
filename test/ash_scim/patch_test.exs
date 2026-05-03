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

  describe "relationship-backed multivalued with mirror_primary_to (User.emails)" do
    test "replace path: \"emails\" value: [...] emits :replace_all and mirrors primary's value" do
      ops = [
        %{
          "op" => "replace",
          "path" => "emails",
          "value" => [
            %{"value" => "alt@example.com", "primary" => false, "type" => "home"},
            %{"value" => "primary@example.com", "primary" => true, "type" => "work"}
          ]
        }
      ]

      assert {:ok,
              %{
                attrs: %{email: "primary@example.com"},
                relationships: [{:replace_all, :emails, inputs}]
              }} = Patch.to_params(body(ops), User)

      assert length(inputs) == 2
    end

    test "replace with no explicit primary mirrors the lex-sorted-first entry" do
      ops = [
        %{
          "op" => "replace",
          "path" => "emails",
          "value" => [
            %{"value" => "zach@example.com"},
            %{"value" => "alice@example.com"}
          ]
        }
      ]

      assert {:ok, %{attrs: %{email: "alice@example.com"}}} = Patch.to_params(body(ops), User)
    end

    test "add path: \"emails\" emits :append plus a :mirror_sync post-op" do
      ops = [
        %{
          "op" => "add",
          "path" => "emails",
          "value" => [%{"value" => "new@example.com", "primary" => true, "type" => "work"}]
        }
      ]

      assert {:ok,
              %{
                attrs: %{},
                relationships: [
                  {:append, :emails, _},
                  {:mirror_sync, :emails, :email, :value}
                ]
              }} = Patch.to_params(body(ops), User)
    end

    test "remove path: \"emails\" leaves the mirror untouched when allow_nil?: false" do
      ops = [%{"op" => "remove", "path" => "emails"}]

      # User.email is allow_nil?: false (it's the identity column), so
      # `remove path: emails` clears the relationship rows but leaves the
      # parent's email attribute alone — and still reports success.
      assert {:ok, %{attrs: %{}, relationships: [{:replace_all, :emails, []}]}} =
               Patch.to_params(body(ops), User)
    end

    test "remove path: \"emails[filter]\" emits :remove_where plus :mirror_sync" do
      ops = [%{"op" => "remove", "path" => ~S(emails[value eq "alt@example.com"])}]

      assert {:ok,
              %{
                attrs: %{},
                relationships: [
                  {:remove_where, :emails, _filter},
                  {:mirror_sync, :emails, :email, :value}
                ]
              }} = Patch.to_params(body(ops), User)
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

    test ~s(`remove path: "members[value eq \\"u1\\"]"` produces a :remove_where op with the resolved filter) do
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
