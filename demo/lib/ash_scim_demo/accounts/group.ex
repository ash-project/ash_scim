defmodule AshScimDemo.Accounts.Group do
  use Ash.Resource,
    otp_app: :ash_scim_demo,
    domain: AshScimDemo.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshScim.Group]

  scim do
    map :displayName, attribute: :name
    map :externalId, attribute: :scim_external_id

    multivalued :members do
      relationship :memberships
      map :value, attribute: :user_id
    end
  end

  postgres do
    table "groups"
    repo AshScimDemo.Repo
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
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :scim_external_id, :string, public?: true
  end

  relationships do
    has_many :memberships, AshScimDemo.Accounts.Membership do
      destination_attribute :group_id
      public? true
    end
  end
end
