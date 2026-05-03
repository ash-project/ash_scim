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
      map :value, attribute: :email
      map :primary, value: true
      map :type, value: "work"
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
  end
end
