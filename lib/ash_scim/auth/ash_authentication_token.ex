# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Auth.AshAuthenticationToken do
  @moduledoc """
  Authenticates SCIM requests using JWTs issued by `AshAuthentication`.

  The bearer token is verified against the host app's signing key, its
  `purpose` claim is checked, the JTI is verified against the
  `AshAuthentication.TokenResource` so revocations are honored, and the
  `sub` claim is resolved into a user record. That user is returned as the
  Ash actor for the request.

  ## Example

      plug AshScim.Router,
        domains: [MyApp.Accounts],
        auth: {AshScim.Auth.AshAuthenticationToken, otp_app: :my_app}

  Revocation is handled transparently by `AshAuthentication.Jwt.verify/2`,
  which checks the JTI against the resource's token resource as part of
  validation. There is no separate revocation check inside this module.

  ## Options

    * `:otp_app` — required. The OTP application name configured by
      AshAuthentication. Used to discover the user resource(s).
    * `:purpose` — required claim value to match. Defaults to `"scim"`.
      Tokens issued for other purposes (sign-in, magic link, confirmation)
      cannot be used to access SCIM endpoints.

  ## Issuing tokens

  Generate a SCIM token from the host app — typically from an admin UI or an
  iex console — by minting a JWT with `purpose: "scim"` for a service-account
  user and persisting it in the token resource. A `mix ash_scim.gen.token`
  task is provided for local development convenience but should not be used
  against production.
  """

  @behaviour AshScim.Auth

  alias AshAuthentication.Jwt

  @impl true
  def authenticate(conn, opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    expected_purpose = Keyword.get(opts, :purpose, "scim")

    with {:ok, token} <- extract_bearer(conn),
         {:ok, claims, resource} <- verify_jwt(token, otp_app),
         :ok <- check_purpose(claims, expected_purpose),
         {:ok, user} <- subject_to_user(claims, resource) do
      {:ok, conn, user}
    end
  end

  defp extract_bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      ["bearer " <> token] when token != "" -> {:ok, token}
      _ -> {:error, "missing or malformed Authorization header"}
    end
  end

  defp verify_jwt(token, otp_app) do
    case Jwt.verify(token, otp_app) do
      {:ok, claims, resource} -> {:ok, claims, resource}
      :error -> {:error, "invalid, revoked, or expired token"}
    end
  end

  defp check_purpose(%{"purpose" => purpose}, expected) when purpose == expected, do: :ok
  defp check_purpose(_, _), do: {:error, "token is not authorised for SCIM"}

  defp subject_to_user(%{"sub" => subject}, resource) do
    case AshAuthentication.subject_to_user(subject, resource) do
      {:ok, user} -> {:ok, user}
      {:error, _} -> {:error, "subject does not resolve to a user"}
    end
  end

  defp subject_to_user(_, _), do: {:error, "token is missing subject"}
end
