<!--
SPDX-FileCopyrightText: 2026 Zach Daniel

SPDX-License-Identifier: MIT
-->

# Authentication

`AshScim.Router` is configured with one authentication implementation that
runs against every inbound request. SCIM is intentionally orthogonal to
end-user login — this is purely about how the **identity provider**
authenticates to your SCIM endpoints.

The router calls `c:AshScim.Auth.authenticate/2`, which returns either
`{:ok, conn, actor}` (the request proceeds with `actor` as the Ash actor)
or `{:error, reason}` (the request is rejected with a 401 SCIM error).

## Built-in implementations

### `AshScim.Auth.StaticBearer`

Accepts one or more bearer tokens from configuration. Constant-time
compare. Suitable for development and simple deployments.

```elixir
plug AshScim.Router,
  domains: [MyApp.Accounts],
  auth: {AshScim.Auth.StaticBearer,
         tokens: {:env, "SCIM_BEARER_TOKEN"}}
```

Options:

- `:tokens` — required. A list of accepted token strings, a single
  string, or a `{:env, "VAR"}` tuple to read at request time.
  `{:env, …}` is preferred for production-like setups since it avoids
  baking tokens into compiled releases.
- `:actor` — optional. The Ash actor used for actions performed by
  authenticated requests. Defaults to `nil`.

Multiple tokens are useful during rotation — issue a new one, deploy,
remove the old one.

### `AshScim.Auth.AshAuthenticationToken`

Authenticates using JWTs issued by `AshAuthentication`. The bearer token
is verified against the host app's signing key, its `purpose` claim is
checked, the JTI is verified against the configured `TokenResource`, and
the `sub` claim is resolved into a user record. The verified user becomes
the Ash actor for the request.

```elixir
plug AshScim.Router,
  domains: [MyApp.Accounts],
  auth: {AshScim.Auth.AshAuthenticationToken, otp_app: :my_app}
```

Options:

- `:otp_app` — required. The OTP application name configured by
  AshAuthentication.
- `:purpose` — required claim value to match. Defaults to `"scim"`. Tokens
  issued for other purposes (sign-in, magic link, confirmation) cannot be
  used to access SCIM endpoints.

Revocation is handled transparently by `AshAuthentication.Jwt.verify/2`,
which checks the JTI against the resource's token resource as part of
validation. Calling
[`AshAuthentication.TokenResource.revoke/2`](https://hexdocs.pm/ash_authentication/AshAuthentication.TokenResource.html#revoke/2)
from anywhere — admin UI, iex, scheduled cleanup — invalidates the token
immediately.

## Issuing SCIM tokens

`AshAuthentication.Jwt.token_for_user/3` mints a JWT and stores it in the
configured `TokenResource`. Pass `purpose: "scim"` so the SCIM verifier
will accept it:

```elixir
{:ok, jwt, _claims} =
  AshAuthentication.Jwt.token_for_user(service_account_user, %{"purpose" => "scim"})
```

The most common production pattern: expose a `:create_scim_token` action
on your existing token resource that calls `token_for_user/3` and returns
the JWT in the action's metadata. Surface it in your admin UI as
"Generate SCIM token", restrict it to admins via policy, and let
operators paste the resulting JWT into their IdP's SCIM configuration.

For local development, a one-off `mix run` script that prints a token to
stdout is fine — see the [Get Started guide](../tutorials/get-started.md).

## Writing your own auth implementation

`AshScim.Auth` is a behaviour. To plug in custom logic — mTLS, signed
requests, OAuth2 client credentials, anything else — implement
`authenticate/2`:

```elixir
defmodule MyApp.Scim.MutualTlsAuth do
  @behaviour AshScim.Auth

  @impl true
  def authenticate(conn, opts) do
    case verify_client_cert(conn, opts) do
      {:ok, service_account} -> {:ok, conn, service_account}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Then point the router at it:

```elixir
auth: {MyApp.Scim.MutualTlsAuth, opts}
```

The `actor` returned in the third tuple element is the Ash actor used for
all actions in this request — typically your service-account user. If you
return `nil`, actions run unauthenticated and your resource policies need
to allow that.
