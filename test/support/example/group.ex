# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Test.Example.Group do
  @moduledoc false

  use Ash.Resource,
    domain: AshScim.Test.Example.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshScim.Group]

  scim do
    map :displayName, attribute: :name
    map :externalId, attribute: :scim_external_id

    multivalued :members do
      relationship :memberships
      map :value, attribute: :user_id
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :scim_external_id, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*]

    update :update do
      primary? true
      accept :*
      require_atomic? false
    end
  end

  relationships do
    has_many :memberships, AshScim.Test.Example.Membership do
      destination_attribute :group_id
      public? true
    end
  end
end
