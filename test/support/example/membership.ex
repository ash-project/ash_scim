# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Test.Example.Membership do
  @moduledoc false

  use Ash.Resource,
    domain: AshScim.Test.Example.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    uuid_primary_key :id
    attribute :user_id, :string, allow_nil?: false, public?: true
    attribute :group_id, :uuid, allow_nil?: false, public?: true
  end

  identities do
    identity :user_in_group, [:user_id, :group_id], pre_check_with: AshScim.Test.Example.Domain
  end
end
