# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Dsl.Multivalued do
  @moduledoc """
  Represents a SCIM multi-valued attribute, declared via the `multivalued/2`
  block in the `scim` section.

  A `multivalued` attribute emits an array of complex objects under a single
  SCIM key, e.g. SCIM's `emails` array where each element has `value`,
  `primary`, and `type` sub-attributes.

  In the simple/initial form a multivalued attribute backed by a single Ash
  attribute is emitted as a one-element array. Future iterations may support
  has_many-style mappings.
  """

  defstruct [
    :name,
    :relationship,
    :returned,
    :mutability,
    on_remove: :set_nil,
    maps: [],
    __spark_metadata__: nil
  ]

  @type on_remove :: :set_nil | :ignore | :reject

  @type t :: %__MODULE__{
          name: atom(),
          relationship: atom() | nil,
          returned: :always | :never | :default | :request | nil,
          mutability: :read_only | :read_write | :immutable | :write_only | nil,
          on_remove: on_remove(),
          maps: [AshScim.Dsl.Map.t()]
        }

  @schema [
    name: [
      type: :atom,
      required: true,
      doc: "The SCIM attribute name for the multivalued array, e.g. `:emails`."
    ],
    relationship: [
      type: :atom,
      doc: """
      Optional. The name of a `has_many` relationship on this resource that
      backs this multivalued attribute. When present, encoding loads the
      relationship and emits one array element per related record; PATCH
      operations on this attribute manipulate the related rows directly.
      Sub-`map` declarations reference attributes on the *related* resource
      rather than on this one.

      Leave unset to use the simple model where the multivalued is backed
      by attributes on this resource (one-element array semantics).
      """
    ],
    returned: [
      type: {:in, [:always, :never, :default, :request]},
      doc: "RFC 7643 `returned`. Defaults to `:default`."
    ],
    mutability: [
      type: {:in, [:read_only, :read_write, :immutable, :write_only]},
      doc: "RFC 7643 `mutability`. Defaults to `:read_write`."
    ],
    on_remove: [
      type: {:in, [:set_nil, :ignore, :reject]},
      default: :set_nil,
      doc: """
      How to handle PATCH `remove` on this multivalued (only meaningful for
      single-attribute-backed multivalueds; relationship-backed always
      destroys the related rows).

        * `:set_nil` (default) — set the underlying Ash attribute(s) to
          `nil`. Fails with `400 invalidValue` if the attribute is
          `allow_nil?: false`.
        * `:ignore` — silently succeed without touching the data. Useful
          for required identity fields (e.g. `email`) where the IdP's
          remove semantics don't fit your model but you don't want to
          surface the conflict to the IdP.
        * `:reject` — return a `400 mutability` SCIM error explicitly.
          Tells the IdP "this attribute can't be removed" without the
          ambiguity of `invalidValue`.
      """
    ]
  ]

  @doc false
  def schema, do: @schema
end
