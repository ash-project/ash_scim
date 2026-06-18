# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.DslTest do
  use ExUnit.Case, async: true

  alias AshScim.Dsl.{Complex, Map, Multivalued}
  alias AshScim.Test.Example.{Group, User}

  describe "AshScim.User extension" do
    test "marks the resource as a SCIM user" do
      assert AshScim.Info.scim_resource?(User)
      assert AshScim.Info.scim_type(User) == :user
    end

    test "applies default path and schema" do
      assert AshScim.Info.scim_path!(User) == "/Users"
      assert AshScim.Info.scim_schema!(User) == "urn:ietf:params:scim:schemas:core:2.0:User"
      assert AshScim.Info.scim_meta?(User) == true
    end

    test "captures simple maps in declaration order" do
      mappings = AshScim.Info.scim_mappings(User)

      assert [
               %Map{name: :userName, attribute: :email},
               %Map{name: :active, attribute: :active},
               %Map{name: :externalId, attribute: :scim_external_id},
               %Complex{name: :name, maps: name_maps},
               %Multivalued{
                 name: :emails,
                 relationship: :emails,
                 mirror_primary_to: :email,
                 maps: emails_maps
               },
               %AshScim.Dsl.Extension{
                 urn: "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User",
                 complexes: [%Complex{name: :manager, maps: manager_maps}]
               }
             ] = mappings

      assert [
               %Map{name: :value, attribute: :manager_value},
               %Map{name: :displayName, attribute: :manager_display_name}
             ] = manager_maps

      assert [
               %Map{name: :givenName, attribute: :first_name},
               %Map{name: :familyName, attribute: :last_name}
             ] = name_maps

      assert [
               %Map{name: :value, attribute: :value},
               %Map{name: :primary, attribute: :primary},
               %Map{name: :type, attribute: :type}
             ] = emails_maps
    end
  end

  describe "AshScim.Group extension" do
    test "marks the resource as a SCIM group" do
      assert AshScim.Info.scim_resource?(Group)
      assert AshScim.Info.scim_type(Group) == :group
    end

    test "applies default path and schema" do
      assert AshScim.Info.scim_path!(Group) == "/Groups"
      assert AshScim.Info.scim_schema!(Group) == "urn:ietf:params:scim:schemas:core:2.0:Group"
    end
  end

  describe "scim_resource?/1" do
    test "returns false for resources without the extension" do
      defmodule Plain do
        @moduledoc false
        use Ash.Resource, domain: nil, validate_domain_inclusion?: false

        actions do
          defaults [:read]
        end

        attributes do
          uuid_primary_key :id
        end
      end

      refute AshScim.Info.scim_resource?(Plain)
      assert AshScim.Info.scim_type(Plain) == nil
    end
  end
end
