# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Dsl.Map do
  @moduledoc """
  Represents a single SCIM attribute mapping declared via `map/2` in the
  `scim` section of a resource.

  Each map binds a SCIM attribute name to either an Ash attribute on the
  resource (`attribute:`) or a static value (`value:`). Static values are
  useful for things like `primary: true` on a multivalued sub-attribute.
  """

  defstruct [
    :name,
    :attribute,
    :value,
    :case_exact?,
    :returned,
    :mutability,
    :uniqueness,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          attribute: atom() | nil,
          value: term(),
          case_exact?: boolean() | nil,
          returned: :always | :never | :default | :request | nil,
          mutability: :read_only | :read_write | :immutable | :write_only | nil,
          uniqueness: :none | :server | :global | nil
        }

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: "The SCIM attribute name (camelCase per RFC 7643), e.g. `:userName`."
    ],
    attribute: [
      type: :atom,
      doc: "The Ash attribute on this resource that backs the SCIM attribute."
    ],
    value: [
      type: :any,
      doc: """
      A static value to emit for this SCIM attribute. Useful inside multivalued
      mappings, e.g. `map :primary, value: true`. Mutually exclusive with
      `attribute`.
      """
    ],
    case_exact?: [
      type: :boolean,
      doc: "RFC 7643 `caseExact`. Defaults to false for strings."
    ],
    returned: [
      type: {:in, [:always, :never, :default, :request]},
      doc: "RFC 7643 `returned`. Defaults to `:default`."
    ],
    mutability: [
      type: {:in, [:read_only, :read_write, :immutable, :write_only]},
      doc: "RFC 7643 `mutability`. Defaults to `:read_write`."
    ],
    uniqueness: [
      type: {:in, [:none, :server, :global]},
      doc: "RFC 7643 `uniqueness`. Defaults to `:none`."
    ]
  ]

  @doc false
  def schema, do: @schema
end
