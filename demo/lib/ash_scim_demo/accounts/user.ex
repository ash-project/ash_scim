defmodule AshScimDemo.Accounts.User do
  use Ash.Resource,
    otp_app: :ash_scim_demo,
    domain: AshScimDemo.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication, AshScim.User]

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end

    tokens do
      enabled? true
      token_resource AshScimDemo.Accounts.Token
      signing_secret AshScimDemo.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end
  end

  scim do
    map :userName, attribute: :email
    map :active, attribute: :active
    map :externalId, attribute: :scim_external_id

    complex :name do
      map :givenName, attribute: :first_name
      map :familyName, attribute: :last_name
    end

    multivalued :emails do
      # `:email` is the user's identity (required + unique). PATCH `remove
      # path: "emails"` is honoured as a no-op since dropping the email
      # would invalidate the user record.
      on_remove :ignore
      map :value, attribute: :email
      map :primary, value: true
      map :type, value: "work"
    end
  end

  postgres do
    table "users"
    repo AshScimDemo.Repo
  end

  actions do
    defaults [:read, :destroy, create: :*]

    update :update do
      primary? true
      accept :*
      require_atomic? false
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    bypass AshScim.Checks.AshScimInteraction do
      authorize_if always()
    end

    # SCIM endpoints run with the service-account user as actor; allow them
    # to read/write user records freely. In a real deployment you'd narrow
    # this to "actor has scim role" or similar.
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :active, :boolean, default: true, public?: true
    attribute :first_name, :string, public?: true
    attribute :last_name, :string, public?: true
    attribute :scim_external_id, :string, public?: true
  end

  identities do
    identity :unique_email, [:email]
  end
end
