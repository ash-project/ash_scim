# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Test.OnRemoveExample.User do
  @moduledoc """
  Fixture for the three `on_remove` modes on a single-attribute multivalued.
  """

  use Ash.Resource,
    domain: AshScim.Test.OnRemoveExample.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshScim.User]

  scim do
    map :userName, attribute: :email

    multivalued :default_emails do
      # default :set_nil
      map :value, attribute: :email
    end

    multivalued :ignored_emails do
      on_remove :ignore
      map :value, attribute: :email
    end

    multivalued :rejected_emails do
      on_remove :reject
      map :value, attribute: :email
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :ci_string, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_email, [:email], pre_check_with: AshScim.Test.OnRemoveExample.Domain
  end
end
