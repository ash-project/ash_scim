defmodule AshScimDemo.Accounts.Membership do
  use Ash.Resource,
    otp_app: :ash_scim_demo,
    domain: AshScimDemo.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "memberships"
    repo AshScimDemo.Repo
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :user_id, :string, allow_nil?: false, public?: true
    attribute :group_id, :uuid, allow_nil?: false, public?: true
  end

  identities do
    identity :user_in_group, [:user_id, :group_id]
  end
end
