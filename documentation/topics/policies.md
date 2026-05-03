<!--
SPDX-FileCopyrightText: 2026 Zach Daniel

SPDX-License-Identifier: MIT
-->

# Policies & the bypass check

If your resources use `Ash.Policy.Authorizer`, AshScim's internal Ash
calls (the reads, creates, updates, destroys, and loads it issues from
the router) need a way to bypass your application-level policies.
Otherwise filters that work fine in your app code can fail when issued
from the SCIM router because of `public?:`, field policies, or
restrictive read policies.

## The pattern

This mirrors AshAuthentication's
[`AshAuthenticationInteraction`](https://hexdocs.pm/ash_authentication/AshAuthentication.Checks.AshAuthenticationInteraction.html)
check. AshScim provides
[`AshScim.Checks.AshScimInteraction`](AshScim.Checks.AshScimInteraction.html),
which returns `true` whenever the changeset/query was built by AshScim
itself.

To enable the bypass on a SCIM-exposed resource, add it as the first
policy:

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    # ...
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication, AshScim.User]

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    bypass AshScim.Checks.AshScimInteraction do
      authorize_if always()
    end

    # ... your normal user-facing policies ...
  end

  # ...
end
```

## How it works

Every changeset and query the router constructs is tagged with the
private context flag `%{private: %{ash_scim?: true}}`. The check
`AshScim.Checks.AshScimInteraction` matches on that flag and returns
`true`, so the bypass authorizes the operation.

Crucially, **this flag can only be set by code running inside the
AshScim router**. Your application code can't accidentally trip it: an
end-user request that ends up calling `Ash.read` on the same resource
goes through your normal policies.

The same flag is also passed via `:context` on `Ash.get`, `Ash.load`, and
`Ash.bulk_destroy` calls so policy checks see it consistently across all
the entry points the router uses.

## When you don't want a blanket bypass

The pattern above is convenient but blunt — it gives the router
unrestricted access to the resource. If you want to narrow it (e.g.
"the SCIM router can only read users with `active == true`"), replace
the bypass with a regular policy that checks the SCIM context flag plus
additional conditions:

```elixir
policies do
  # SCIM has limited access: it can read/update users, but only active ones.
  policy AshScim.Checks.AshScimInteraction do
    authorize_if action_type([:read, :update])
    authorize_if expr(active == true)
  end

  # ... regular user-facing policies ...
end
```

The check is just an `Ash.Policy.SimpleCheck` — compose it however your
authorization model needs.

## Why not just give the SCIM service account broad permissions instead?

You could in principle skip the bypass and use a service-account user
with policies that grant full SCIM access. Two reasons we recommend the
bypass instead:

1. **It's more explicit.** Reading the resource's `policies` block, you
   can immediately see the SCIM-managed paths in or out.
2. **It survives actor changes.** If your auth implementation ever
   changes (e.g. you switch from
   `AshScim.Auth.AshAuthenticationToken` to a per-IdP service identity),
   you don't have to re-encode "this thing can do SCIM stuff" in your
   policies — the context flag carries that intent regardless of who
   the actor is.
