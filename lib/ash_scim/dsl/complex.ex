# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Dsl.Complex do
  @moduledoc """
  Represents a SCIM complex (object-valued) attribute, declared via the
  `complex/2` block in the `scim` section.

  A `complex` attribute groups sub-attribute mappings under a single SCIM key,
  e.g. SCIM's `name` object containing `givenName` and `familyName`.
  """

  defstruct [:name, :returned, :mutability, maps: [], __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: atom(),
          returned: :always | :never | :default | :request | nil,
          mutability: :read_only | :read_write | :immutable | :write_only | nil,
          maps: [AshScim.Dsl.Map.t()]
        }

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: "The SCIM attribute name for the complex object, e.g. `:name`."
    ],
    returned: [
      type: {:in, [:always, :never, :default, :request]},
      doc: "RFC 7643 `returned`. Defaults to `:default`."
    ],
    mutability: [
      type: {:in, [:read_only, :read_write, :immutable, :write_only]},
      doc: "RFC 7643 `mutability`. Defaults to `:read_write`."
    ]
  ]

  @doc false
  def schema, do: @schema
end
