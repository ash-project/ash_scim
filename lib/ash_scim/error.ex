# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Error do
  @moduledoc """
  Builders for SCIM 2.0 error response bodies (RFC 7644 §3.12).

  All errors share the same envelope shape:

      {
        "schemas": ["urn:ietf:params:scim:api:messages:2.0:Error"],
        "status": "404",
        "scimType": "...",
        "detail": "..."
      }

  `scimType` is required by the spec for some HTTP statuses (notably 400) and
  optional otherwise.
  """

  @schema "urn:ietf:params:scim:api:messages:2.0:Error"

  @type scim_type ::
          :invalidFilter
          | :tooMany
          | :uniqueness
          | :mutability
          | :invalidSyntax
          | :invalidPath
          | :noTarget
          | :invalidValue
          | :invalidVers
          | :sensitive

  @doc "Build a SCIM error envelope."
  @spec build(non_neg_integer(), String.t(), scim_type() | nil) :: %{String.t() => term()}
  def build(status, detail, scim_type \\ nil) do
    base = %{
      "schemas" => [@schema],
      "status" => Integer.to_string(status),
      "detail" => detail
    }

    case scim_type do
      nil -> base
      type -> Elixir.Map.put(base, "scimType", to_string(type))
    end
  end
end
