# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Test.SourceExample.User do
  @moduledoc """
  Fixture for verifying that auth-time context flows through to
  changesets/queries the router builds.

  Two SCIM clients (e.g. Okta + Azure AD) hit the same endpoint with
  different JWTs. Each JWT carries a `scim_source` claim. The custom
  auth implementation verifies the JWT, reads the claim, and sets it as
  context via `Ash.PlugHelpers.set_context/2`. The router merges that
  context into every changeset/query.

  Here, a `change` reads `changeset.context.private.scim_source` and
  stamps it on creates; a `prepare` filters reads down to records owned
  by the requesting source. The result: each SCIM client only sees and
  manages the users it created, even though they share one resource.
  """

  use Ash.Resource,
    domain: AshScim.Test.SourceExample.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshAuthentication, AshScim.User]

  authentication do
    tokens do
      enabled?(true)
      token_resource(AshScim.Test.SourceExample.Token)
      signing_secret(AshScim.Test.SourceExample.Secrets)
      store_all_tokens?(true)
      require_token_presence_for_authentication?(true)
    end
  end

  scim do
    map :userName, attribute: :email
    map :externalId, attribute: :scim_external_id

    read_action :scoped_read
  end

  actions do
    defaults [:destroy]

    create :create do
      primary? true
      accept [:email, :scim_external_id]

      change AshScim.Test.SourceExample.StampSource
    end

    update :update do
      primary? true
      accept [:email, :scim_external_id]
      require_atomic? false
    end

    read :read do
      primary? true
    end

    read :scoped_read do
      prepare AshScim.Test.SourceExample.ScopeBySource
    end

    read :get_by_subject do
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :scim_external_id, :string, public?: true
    attribute :scim_source, :string, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_email, [:email], pre_check_with: AshScim.Test.SourceExample.Domain
  end
end
