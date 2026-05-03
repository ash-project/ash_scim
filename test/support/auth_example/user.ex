# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Test.AuthExample.User do
  @moduledoc false

  use Ash.Resource,
    domain: AshScim.Test.AuthExample.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshAuthentication, AshScim.User]

  authentication do
    tokens do
      enabled? true
      token_resource AshScim.Test.AuthExample.Token
      signing_secret AshScim.Test.AuthExample.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end
  end

  scim do
    map :userName, attribute: :email
    map :active, attribute: :active
    map :externalId, attribute: :scim_external_id
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :active, :boolean, default: true, public?: true
    attribute :scim_external_id, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  identities do
    identity :unique_email, [:email], pre_check_with: AshScim.Test.AuthExample.Domain
  end
end
