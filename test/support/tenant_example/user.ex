# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Test.TenantExample.User do
  @moduledoc """
  Multi-tenant fixture using Ash's attribute-based multitenancy strategy.

  Each user record carries a `:tenant_id` and queries are auto-scoped to
  that tenant when one is set on the query/changeset. The router threads
  the tenant through every Ash call, so requests with one tenant should
  never see another tenant's records.
  """

  use Ash.Resource,
    domain: AshScim.Test.TenantExample.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshScim.User]

  scim do
    map :userName, attribute: :email
    map :externalId, attribute: :scim_external_id
  end

  actions do
    defaults [:read, :destroy, create: :*]

    update :update do
      primary? true
      accept :*
      require_atomic? false
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? false
  end

  attributes do
    uuid_primary_key :id
    # Not public, not in `accept :*`. Attribute multitenancy auto-sets it
    # from the changeset's tenant before validations run.
    attribute :tenant_id, :string, allow_nil?: false
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :scim_external_id, :string, public?: true
  end

  identities do
    identity :unique_email_per_tenant, [:email], pre_check_with: AshScim.Test.TenantExample.Domain
  end
end
