# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Auth.StaticBearer do
  @moduledoc """
  Authenticates SCIM requests against one or more static bearer tokens.

  ## Example

      plug AshScim.Router,
        domains: [MyApp.Accounts],
        auth: {AshScim.Auth.StaticBearer, tokens: {:env, "SCIM_BEARER_TOKEN"}}

  ## Options

    * `:tokens` — required. A list of accepted token strings, a single
      string, or a `{:env, "VAR"}` tuple to read at request time. Reading
      from the environment lazily avoids baking tokens into compiled
      releases. Multiple tokens are useful during rotation.
    * `:actor` — optional. The Ash actor to use for actions performed by
      authenticated requests. Defaults to `nil`. For most setups you will
      want to provide a service-account user record so that policies see a
      consistent identity in audit logs.

  Constant-time comparison is used to match the presented token, so this
  module is safe against timing attacks even when tokens differ in length.
  """

  @behaviour AshScim.Auth

  @impl true
  def authenticate(conn, opts) do
    with {:ok, presented} <- extract_bearer(conn),
         accepted when accepted != [] <- accepted_tokens(opts[:tokens]),
         true <- token_matches?(presented, accepted) do
      {:ok, conn, opts[:actor]}
    else
      [] -> {:error, "no SCIM tokens configured"}
      false -> {:error, "invalid bearer token"}
      {:error, _} = err -> err
    end
  end

  defp extract_bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      ["bearer " <> token] when token != "" -> {:ok, token}
      _ -> {:error, "missing or malformed Authorization header"}
    end
  end

  defp accepted_tokens(nil), do: []
  defp accepted_tokens(token) when is_binary(token), do: [token]
  defp accepted_tokens(tokens) when is_list(tokens), do: tokens

  defp accepted_tokens({:env, var}) when is_binary(var) do
    case System.get_env(var) do
      nil -> []
      "" -> []
      value -> [value]
    end
  end

  defp token_matches?(presented, accepted) do
    Enum.any?(accepted, &Plug.Crypto.secure_compare(&1, presented))
  end
end
