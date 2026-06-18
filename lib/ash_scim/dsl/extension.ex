# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Dsl.Extension do
  @moduledoc """
  Represents a SCIM schema extension (RFC 7643 §3.3): a group of attributes
  that live under a separate schema URN key in the resource JSON — e.g. the
  enterprise user extension
  `urn:ietf:params:scim:schemas:extension:enterprise:2.0:User`, whose object
  carries `manager`, `department`, etc.

  Declared via `extension <urn> do … end` in the `scim` section. The body holds
  the same `map`/`complex`/`multivalued` entities as the top level; they are
  applied against the extension's nested object rather than the resource root.
  """

  defstruct [
    :urn,
    maps: [],
    complexes: [],
    multivalueds: [],
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          urn: String.t(),
          maps: [AshScim.Dsl.Map.t()],
          complexes: [AshScim.Dsl.Complex.t()],
          multivalueds: [AshScim.Dsl.Multivalued.t()]
        }

  @schema [
    urn: [
      type: :string,
      required: true,
      doc:
        "The SCIM schema-extension URN this object is keyed under, e.g. `urn:ietf:params:scim:schemas:extension:enterprise:2.0:User`."
    ]
  ]

  @doc false
  def schema, do: @schema
end
