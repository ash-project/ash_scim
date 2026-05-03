defmodule AshScimDemo.Accounts.Email do
  use Ash.Resource,
    otp_app: :ash_scim_demo,
    domain: AshScimDemo.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "user_emails"
    repo AshScimDemo.Repo

    references do
      reference :user, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  policies do
    bypass AshScim.Checks.AshScimInteraction do
      authorize_if always()
    end

    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :value, :string, allow_nil?: false, public?: true
    attribute :primary, :boolean, default: false, public?: true
    attribute :type, :string, public?: true
  end

  relationships do
    belongs_to :user, AshScimDemo.Accounts.User do
      attribute_type :uuid
      allow_nil? false
      public? true
    end
  end
end
