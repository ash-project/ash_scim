# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Test.Example.User do
  @moduledoc false

  use Ash.Resource,
    domain: AshScim.Test.Example.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshScim.User]

  scim do
    map :userName, attribute: :email
    map :active, attribute: :active
    map :externalId, attribute: :scim_external_id

    complex :name do
      map :givenName, attribute: :first_name
      map :familyName, attribute: :last_name
    end

    multivalued :emails do
      relationship :emails
      mirror_primary_to :email
      map :value, attribute: :value
      map :primary, attribute: :primary
      map :type, attribute: :type
    end

    extension "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User" do
      complex :manager do
        map :value, attribute: :manager_value
        map :displayName, attribute: :manager_display_name
      end
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :active, :boolean, default: true, public?: true
    attribute :first_name, :string, public?: true
    attribute :last_name, :string, public?: true
    attribute :scim_external_id, :string, public?: true
    attribute :manager_value, :string, public?: true
    attribute :manager_display_name, :string, public?: true
  end

  relationships do
    has_many :emails, AshScim.Test.Example.Email do
      destination_attribute :user_id
      public? true
    end
  end
end
