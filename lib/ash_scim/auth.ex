# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Auth do
  @moduledoc """
  Behaviour for authenticating inbound SCIM requests.

  An `AshScim.Router` is configured with one auth implementation; the router
  invokes `c:authenticate/2` before any resource handler runs. Returning
  `{:ok, conn, actor}` allows the request to proceed (the actor is passed to
  Ash actions); returning `{:error, reason}` halts with a 401 SCIM error.

  Built-in implementations:

    * `AshScim.Auth.StaticBearer` — accepts one or more bearer tokens from
      configuration. Useful for development and simple deployments.

  Planned: an `AshScim.Auth.AshAuthenticationToken` adapter that delegates to
  the host app's `AshAuthentication.TokenResource` so SCIM bearer tokens live
  alongside the existing token store and inherit its revocation semantics.
  """

  @typedoc "Implementation module + opts (the second tuple element is passed verbatim to the callbacks)."
  @type config :: {module(), keyword()}

  @typedoc "Optional Ash actor to use for actions performed by the request."
  @type actor :: term() | nil

  @doc """
  Authenticate `conn`. Return `{:ok, conn, actor}` to proceed (the conn may
  be modified, e.g. to stash details), or `{:error, reason}` to reject.
  """
  @callback authenticate(Plug.Conn.t(), keyword()) ::
              {:ok, Plug.Conn.t(), actor()} | {:error, String.t()}
end
