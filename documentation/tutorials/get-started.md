<!--
SPDX-FileCopyrightText: 2026 Zach Daniel

SPDX-License-Identifier: MIT
-->

# Get started with AshScim

This guide walks you through adding a SCIM 2.0 server to an existing Ash
application — wiring up `AshScim` on your user resource, exposing a
`/scim/v2` endpoint, and authenticating identity providers (Okta, Azure AD,
etc.) with bearer tokens.

If you don't yet have an Ash application, start with the
[Ash Getting Started guide](https://hexdocs.pm/ash/get-started.html). If
you also want logged-in users (separate concern from SCIM), follow the
[AshAuthentication Getting Started guide](https://hexdocs.pm/ash_authentication/get-started.html)
first — AshScim integrates cleanly with it.

## What you'll build

By the end of this guide:

- Your `User` resource is exposed as a SCIM `User` resource at `/scim/v2/Users`.
- Optionally, a `Group` resource is exposed at `/scim/v2/Groups`, with
  group memberships managed via SCIM PATCH ops.
- IdPs authenticate using bearer JWTs minted by AshAuthentication, stored
  in your existing token resource so they can be revoked at any time.

## Install with Igniter (recommended)

```sh
mix igniter.install ash_scim
```

This:

- adds `:ash_scim` to your deps and `.formatter.exs`,
- adds the `AshScim.User` extension to your user resource (default
  `MyApp.Accounts.User` — pass `--user` to override),
- adds the `:scim_external_id` and `:active` attributes if they're not
  already present,
- adds a default `scim do` block with sensible mappings,
- adds the `AshScim.Checks.AshScimInteraction` policy bypass,
- generates a `MyAppWeb.ScimRouter` module wired to your accounts domain.

When AshAuthentication is also a dep of the project, the router defaults
to `{AshScim.Auth.AshAuthenticationToken, otp_app: :my_app}`. Otherwise
it defaults to `{AshScim.Auth.StaticBearer, tokens: {:env, "SCIM_BEARER_TOKEN"}}`.

The installer is idempotent — re-running it on a partially-installed app
picks up where it left off. The printed notices cover the two manual
steps that remain: mounting the router in your endpoint, and minting a
token.

If you'd rather wire things by hand, the rest of this guide covers the
equivalent manual setup.

## Add the dependency (manual)

```elixir
# mix.exs
defp deps do
  [
    # ...
    {:ash_scim, "~> 0.1"}
  ]
end
```

Add `:ash_scim` to your `.formatter.exs`:

```elixir
# .formatter.exs
[
  import_deps: [..., :ash_scim]
]
```

## Add the extension to your User resource

Whatever your existing User resource looks like, add `AshScim.User` to its
`extensions:` list and declare the SCIM mapping in a `scim do ... end`
block:

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    # Add AshScim.User to your existing extensions
    extensions: [AshAuthentication, AshScim.User]

  scim do
    map :userName,   attribute: :email
    map :active,     attribute: :active
    map :externalId, attribute: :scim_external_id

    complex :name do
      map :givenName,  attribute: :first_name
      map :familyName, attribute: :last_name
    end

    multivalued :emails do
      map :value,   attribute: :email
      map :primary, value: true
      map :type,    value: "work"
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :email,            :ci_string, allow_nil?: false, public?: true
    attribute :first_name,       :string,    public?: true
    attribute :last_name,        :string,    public?: true
    attribute :active,           :boolean,   default: true, public?: true
    attribute :scim_external_id, :string,    public?: true
  end

  identities do
    identity :unique_email, [:email]
  end

  # ...your authentication block, actions, etc...
end
```

The `scim do` block describes how SCIM JSON projects to and from Ash
attributes. See [Multi-valued
attributes](../topics/multi-valued-attributes.md) for the full breakdown of
`map`/`complex`/`multivalued`.

### Add the policy bypass

If your resource uses `Ash.Policy.Authorizer`, add a bypass for AshScim's
internal interactions so the router's reads, creates, updates, and
destroys aren't blocked by your user-facing policies:

```elixir
policies do
  bypass AshScim.Checks.AshScimInteraction do
    authorize_if always()
  end

  # ... your existing policies ...
end
```

See [Policies & the bypass check](../topics/policies.md) for the
rationale.

## Optional: add Group + Membership for SCIM groups

Most IdPs sync groups in addition to users. The simplest model is a
`Group` resource plus a `Membership` join resource:

```elixir
defmodule MyApp.Accounts.Membership do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: AshPostgres.DataLayer

  attributes do
    uuid_primary_key :id
    attribute :user_id,  :string, allow_nil?: false, public?: true
    attribute :group_id, :uuid,   allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  identities do
    identity :user_in_group, [:user_id, :group_id]
  end
end
```

```elixir
defmodule MyApp.Accounts.Group do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshScim.Group]

  scim do
    map :displayName, attribute: :name
    map :externalId,  attribute: :scim_external_id

    multivalued :members do
      relationship :memberships
      map :value, attribute: :user_id
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name,             :string, allow_nil?: false, public?: true
    attribute :scim_external_id, :string, public?: true
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
    bypass AshScim.Checks.AshScimInteraction do
      authorize_if always()
    end
  end

  relationships do
    has_many :memberships, MyApp.Accounts.Membership do
      destination_attribute :group_id
      public? true
    end
  end
end
```

Add both resources to your domain:

```elixir
defmodule MyApp.Accounts do
  use Ash.Domain

  resources do
    resource MyApp.Accounts.User
    resource MyApp.Accounts.Group
    resource MyApp.Accounts.Membership
    # ... existing resources ...
  end
end
```

Run a codegen + migration so the new tables exist:

```sh
mix ash.codegen add_scim_groups
mix ecto.migrate
```

## Define a SCIM router module

```elixir
defmodule MyAppWeb.ScimRouter do
  use AshScim.Router,
    domains: [MyApp.Accounts],
    auth: {AshScim.Auth.AshAuthenticationToken, otp_app: :my_app},
    base_url: "https://my-app.example.com/scim/v2"
end
```

This module is a Plug. The `auth:` option chooses how IdP requests are
authenticated — see [Authentication](../topics/authentication.md) for the
built-in options.

## Mount the router in your Phoenix endpoint

SCIM URLs include `:` characters in schema IDs (e.g.
`/Schemas/urn:ietf:params:scim:schemas:core:2.0:User`), which Phoenix's
default `Plug.Static` middleware rejects. The cleanest fix is to dispatch
SCIM requests at the **endpoint** level, before `Plug.Static`:

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  socket "/live", Phoenix.LiveView.Socket, # ...

  # Dispatch SCIM requests before Plug.Static.
  plug :scim_dispatch

  defp scim_dispatch(%Plug.Conn{path_info: ["scim", "v2" | rest]} = conn, _opts) do
    conn = %{conn | path_info: rest, script_name: conn.script_name ++ ["scim", "v2"]}

    conn
    |> MyAppWeb.ScimRouter.call(MyAppWeb.ScimRouter.init([]))
    |> Plug.Conn.halt()
  end

  defp scim_dispatch(conn, _opts), do: conn

  plug Plug.Static,
    at: "/",
    from: :my_app,
    only: MyAppWeb.static_paths()

  # ... rest of the standard endpoint plugs ...
end
```

## Mint a SCIM bearer token

SCIM requests authenticate as a service-account user with a JWT whose
`purpose` claim is `"scim"`. You create one by inserting into your
existing token resource via a normal Ash action — typically from an admin
UI or an `iex` console attached to your production node.

The simplest approach for development:

```elixir
# A one-off script — priv/repo/scim_token.exs
require Ash.Query

email = "scim-service@my-app.local"

user =
  case MyApp.Accounts.User
       |> Ash.Query.filter(email == ^email)
       |> Ash.read_one(authorize?: false) do
    {:ok, %MyApp.Accounts.User{} = u} -> u
    {:ok, nil} ->
      MyApp.Accounts.User
      |> Ash.Changeset.for_create(:create, %{email: email, active: true})
      |> Ash.create!(authorize?: false)
  end

{:ok, jwt, _claims} = AshAuthentication.Jwt.token_for_user(user, %{"purpose" => "scim"})

IO.puts("SCIM bearer token:\n#{jwt}")
```

Run with `mix run priv/repo/scim_token.exs`. Paste the JWT into your IdP's
SCIM provisioning configuration (or use it for `curl` testing).

For production, expose this as a "Generate SCIM token" action on your
existing token resource and call it from your admin UI. Tokens stored
this way can be revoked at any time using
`AshAuthentication.TokenResource.revoke/2`.

## Verify the setup

Smoke-test from the command line:

```sh
TOKEN=...   # paste the JWT printed above

curl -sS https://my-app.example.com/scim/v2/ServiceProviderConfig \
  -H "Authorization: Bearer $TOKEN"

curl -sS https://my-app.example.com/scim/v2/Users \
  -H "Authorization: Bearer $TOKEN"
```

You should get a `200` with a SCIM `ServiceProviderConfig` document, and
a `200` with a `ListResponse` (initially containing just your service
account user).

## Run a real compliance suite

For a thorough end-to-end check, run the
[`scim2-tester`](https://github.com/python-scim/scim2-tester) compliance
suite against your endpoint:

```sh
pipx install scim2-cli

scim -u https://my-app.example.com/scim/v2 \
     -h "Authorization:Bearer $TOKEN" \
     test
```

This exercises every endpoint AshScim emits, validates the responses
against RFC 7643/7644, and reports any deviations.

## What next?

- [Multi-valued attributes](../topics/multi-valued-attributes.md) —
  single-attribute vs relationship-backed.
- [Filter syntax](../topics/filters.md) — what your IdP can filter on.
- [PATCH operations](../topics/patch-operations.md) — what the router does
  with each kind of `PatchOp`.
- [Authentication](../topics/authentication.md) — `StaticBearer` vs
  AshAuthentication-backed JWTs.
- [Policies & the bypass check](../topics/policies.md).
- [Limitations](../topics/limitations.md) — known gaps.
