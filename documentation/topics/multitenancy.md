<!--
SPDX-FileCopyrightText: 2026 Zach Daniel

SPDX-License-Identifier: MIT
-->

# Multi-tenancy

`AshScim` is multi-tenancy-agnostic. The router threads whatever tenant
your upstream pipeline placed on the conn into every Ash call it makes —
both `Ash.Query.set_tenant/2` / `Ash.Changeset.set_tenant/2` and the
`:tenant` option to `Ash.read`, `Ash.get`, `Ash.create`, `Ash.update`,
`Ash.destroy`, `Ash.load`, and `Ash.bulk_destroy`. Because of that, both
of Ash's multitenancy strategies — attribute-based and context-based —
work end to end.

## Setting the tenant

The router reads the tenant via
[`Ash.PlugHelpers.get_tenant/1`](https://hexdocs.pm/ash/Ash.PlugHelpers.html#get_tenant/1).
You set it upstream — typically in a Phoenix plug that runs before the
SCIM router, or directly inside your custom auth implementation:

```elixir
defmodule MyAppWeb.ScimTenantPlug do
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    tenant = derive_tenant(conn)
    Ash.PlugHelpers.set_tenant(conn, tenant)
  end

  defp derive_tenant(conn) do
    # Examples:
    # - From the JWT claim:    conn.assigns[:current_user].tenant_id
    # - From the URL prefix:   conn.path_info |> hd()
    # - From a custom header:  Plug.Conn.get_req_header(conn, "x-tenant") |> hd()
    # ...
  end
end
```

Wire it into your endpoint just before the SCIM dispatch:

```elixir
plug MyAppWeb.ScimTenantPlug   # sets the tenant
plug :scim_dispatch            # forwards to AshScim.Router
```

The router itself never makes a tenancy policy decision — it just
honours whatever you set. If you don't set anything, all Ash calls run
without a tenant, which on resources configured with `global?: false`
will fail at the data layer (the safer default).

## Attribute-based multitenancy

For resources where the tenant lives in a column on the resource itself:

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication, AshScim.User]

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? false
  end

  attributes do
    uuid_primary_key :id
    attribute :tenant_id, :string, allow_nil?: false   # not public; auto-set
    attribute :email,     :ci_string, allow_nil?: false, public?: true
    # ...
  end

  scim do
    map :userName, attribute: :email
    # ...
  end

  # ... your authentication block, actions, etc...
end
```

When the router calls `Ash.read/2` with `tenant: "acme"`, Ash applies
`tenant_id == "acme"` automatically. Inbound SCIM filters can't escape
the tenant — they're combined with the tenancy filter at the data layer.
A `GET /Users/:id` for a record belonging to a different tenant returns
404 (it's invisible to the request).

## Context-based multitenancy

For multi-schema or multi-database setups:

```elixir
multitenancy do
  strategy :context
  global? false
end
```

The router's `tenant:` plumbing is identical — Ash interprets it as the
schema name (or whatever the data layer's `set_tenant/3` callback does).
For AshPostgres, this typically means the request operates against
`SET search_path = "tenant_xyz"` for its duration.

## Filters and PATCH ops are tenant-safe

Every entry point honours the tenant:

- `GET /Users` and `?filter=…` apply tenant scoping at the query level.
- `GET /Users/:id` returns 404 (not 403) if the record belongs to
  another tenant — to avoid leaking the existence of cross-tenant
  records.
- `POST /Users` writes the new record under the request's tenant.
- `PUT`/`PATCH`/`DELETE` only act on records that belong to the
  request's tenant; cross-tenant attempts 404.
- PATCH `add path: "members"` and `replace path: "members"` apply the
  same tenant to the related-row writes via `manage_relationship`.
- PATCH `remove path: "members[…]"` runs its `bulk_destroy` query under
  the same tenant.

## Authenticating per-tenant SCIM clients

A common multi-tenant SCIM use case: each customer plugs in their own
IdP, with their own bearer token. Two patterns:

**1. Tenant from the bearer token.** Your custom
`AshScim.Auth` implementation looks up which tenant the token belongs
to, sets `Ash.PlugHelpers.set_tenant/2` on the conn, and returns a
service-account user as the actor:

```elixir
defmodule MyApp.Scim.PerTenantAuth do
  @behaviour AshScim.Auth

  @impl true
  def authenticate(conn, _opts) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, tenant, service_user} <- MyApp.Scim.Tokens.verify(token) do
      conn = Ash.PlugHelpers.set_tenant(conn, tenant)
      {:ok, conn, service_user}
    else
      _ -> {:error, "invalid token"}
    end
  end
end
```

**2. Tenant from the URL.** Your endpoint plug strips a tenant prefix
out of the path before forwarding to the SCIM router:

```elixir
plug :scim_dispatch

defp scim_dispatch(%Plug.Conn{path_info: ["scim", "v2", tenant | rest]} = conn, _opts) do
  conn =
    %{conn | path_info: rest, script_name: conn.script_name ++ ["scim", "v2", tenant]}
    |> Ash.PlugHelpers.set_tenant(tenant)

  conn
  |> MyAppWeb.ScimRouter.call(MyAppWeb.ScimRouter.init([]))
  |> Plug.Conn.halt()
end

defp scim_dispatch(conn, _opts), do: conn
```

Either pattern is fine — pick the one that matches how your IdPs are
configured.
