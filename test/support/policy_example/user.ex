# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Test.PolicyExample.User do
  @moduledoc """
  Fixture for verifying that `AshScim.Checks.AshScimInteraction` bypasses
  policies that would otherwise forbid every action.

  Without the bypass, every policy below would reject the router's reads,
  creates, updates, and destroys outright.
  """

  use Ash.Resource,
    domain: AshScim.Test.PolicyExample.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshScim.User]

  scim do
    map :userName, attribute: :email
    map :externalId, attribute: :scim_external_id
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :ci_string, allow_nil?: false, public?: true
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

  policies do
    bypass AshScim.Checks.AshScimInteraction do
      authorize_if always()
    end

    policy always() do
      # Without the bypass above, every operation on this resource is denied.
      forbid_if always()
    end
  end

  identities do
    identity :unique_email, [:email], pre_check_with: AshScim.Test.PolicyExample.Domain
  end
end
