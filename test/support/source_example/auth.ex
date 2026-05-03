# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Test.SourceExample.Auth do
  @moduledoc """
  Realistic per-source auth implementation: each SCIM client carries a
  JWT issued by AshAuthentication, and the JWT contains a custom
  `scim_source` claim identifying which IdP the request is from.

  This implementation:

    1. Verifies the JWT via `AshAuthentication.Jwt.verify/2` (signature,
       expiry, JTI presence in the token resource — the same checks
       `AshScim.Auth.AshAuthenticationToken` does).
    2. Confirms the token's `purpose` claim is `"scim"`.
    3. Reads the custom `scim_source` claim and stashes it on the conn
       via `Ash.PlugHelpers.set_context/2` so the router threads it
       through every Ash call.
    4. Resolves the JWT subject into a service-account user record, used
       as the Ash actor for the request.

  The router never sees `scim_source` — it just merges whatever context
  the auth implementation set. The resource's `change` and `prepare`
  modules read `context.private.scim_source` to enforce per-source
  isolation.
  """

  @behaviour AshScim.Auth

  alias AshAuthentication.Jwt

  @impl true
  def authenticate(conn, _opts) do
    with {:ok, token} <- extract_bearer(conn),
         {:ok, claims, resource} <- verify(token),
         :ok <- check_purpose(claims),
         {:ok, source} <- fetch_source(claims),
         {:ok, user} <- subject_to_user(claims, resource) do
      conn = Ash.PlugHelpers.set_context(conn, %{private: %{scim_source: source}})
      {:ok, conn, user}
    end
  end

  defp extract_bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _ -> {:error, "missing or malformed Authorization header"}
    end
  end

  defp verify(token) do
    case Jwt.verify(token, AshScim.Test.SourceExample.User) do
      {:ok, claims, resource} -> {:ok, claims, resource}
      :error -> {:error, "invalid, revoked, or expired token"}
    end
  end

  defp check_purpose(%{"purpose" => "scim"}), do: :ok
  defp check_purpose(_), do: {:error, "token is not authorised for SCIM"}

  defp fetch_source(%{"scim_source" => source}) when is_binary(source), do: {:ok, source}
  defp fetch_source(_), do: {:error, "token is missing scim_source claim"}

  defp subject_to_user(%{"sub" => subject}, resource) do
    case AshAuthentication.subject_to_user(subject, resource) do
      {:ok, user} -> {:ok, user}
      _ -> {:error, "subject does not resolve to a user"}
    end
  end

  defp subject_to_user(_, _), do: {:error, "token is missing subject"}
end
