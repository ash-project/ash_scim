# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Verifiers.RelationshipTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  describe "verifier" do
    test "rejects a multivalued referencing a missing relationship" do
      output =
        capture_io(:stderr, fn ->
          try do
            Code.compile_string("""
            defmodule AshScim.Verifiers.RelationshipTest.MissingRel do
              use Ash.Resource,
                domain: nil,
                validate_domain_inclusion?: false,
                data_layer: Ash.DataLayer.Ets,
                extensions: [AshScim.Group]

              scim do
                map :displayName, attribute: :name
                multivalued :members do
                  relationship :nope
                  map :value, attribute: :user_id
                end
              end

              attributes do
                uuid_primary_key :id
                attribute :name, :string, public?: true
              end

              actions do
                defaults [:read]
              end
            end
            """)
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "relationship `:nope` which is not declared"
    end

    test "rejects a sub-map referencing an attribute the related resource doesn't have" do
      output =
        capture_io(:stderr, fn ->
          try do
            Code.compile_string("""
            defmodule AshScim.Verifiers.RelationshipTest.BadAttr do
              use Ash.Resource,
                domain: nil,
                validate_domain_inclusion?: false,
                data_layer: Ash.DataLayer.Ets,
                extensions: [AshScim.Group]

              scim do
                map :displayName, attribute: :name
                multivalued :members do
                  relationship :memberships
                  map :value, attribute: :not_a_real_attr
                end
              end

              attributes do
                uuid_primary_key :id
                attribute :name, :string, public?: true
              end

              actions do
                defaults [:read]
              end

              relationships do
                has_many :memberships, AshScim.Test.Example.Membership do
                  destination_attribute :group_id
                  public? true
                end
              end
            end
            """)
          rescue
            _ -> :ok
          end
        end)

      assert output =~ "attribute `:not_a_real_attr` which is not declared"
    end
  end
end
