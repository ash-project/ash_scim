# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Test.Example.Email do
  @moduledoc false

  use Ash.Resource,
    domain: AshScim.Test.Example.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    uuid_primary_key :id
    attribute :value, :string, allow_nil?: false, public?: true
    attribute :primary, :boolean, default: false, public?: true
    attribute :type, :string, public?: true
  end

  relationships do
    belongs_to :user, AshScim.Test.Example.User do
      attribute_type :uuid
      allow_nil? false
      public? true
    end
  end
end
