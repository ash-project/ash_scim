# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Dsl.Multivalued do
  @moduledoc """
  Represents a SCIM multi-valued attribute, declared via the `multivalued/2`
  block in the `scim` section.

  A `multivalued` attribute emits an array of complex objects under a single
  SCIM key, e.g. SCIM's `emails` array where each element has `value`,
  `primary`, and `type` sub-attributes. There are two modes:

  ### Mode A — relationship-backed

  Each entry is a row in a `has_many` relationship. SCIM round-trips
  arbitrary `value`/`primary`/`type` per entry. Sub-`map`s reference
  attributes on the *related* resource.

      multivalued :emails do
        relationship :emails
        mirror_primary_to :email   # optional — also sync to parent column
        map :value,   attribute: :value
        map :primary, attribute: :primary
        map :type,    attribute: :type
      end

  ### Mode B — mirror-only (no relationship)

  The parent has a single scalar (e.g. `:email`) and the SCIM `emails`
  array is collapsed: writes pick the primary entry's `value` into the
  scalar; reads emit one element with `value:` from the scalar plus any
  static decorators. Simpler to set up; doesn't preserve `primary`/`type`
  per entry.

      multivalued :emails do
        mirror_primary_to :email
        map :primary, value: true
        map :type,    value: "work"
      end

  At least one of `relationship:` or `mirror_primary_to:` must be set.
  """

  defstruct [
    :name,
    :relationship,
    :mirror_primary_to,
    :returned,
    :mutability,
    maps: [],
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          relationship: atom() | nil,
          mirror_primary_to: atom() | nil,
          returned: :always | :never | :default | :request | nil,
          mutability: :read_only | :read_write | :immutable | :write_only | nil,
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
      The name of a `has_many` relationship on this resource that backs
      this multivalued attribute. When set, encoding loads the relationship
      and emits one array element per related record; PATCH operations on
      this attribute manipulate the related rows directly. Sub-`map`
      declarations reference attributes on the *related* resource.

      Either `relationship:` or `mirror_primary_to:` must be set.
      """
    ],
    mirror_primary_to: [
      type: :atom,
      doc: """
      Names a scalar attribute on *this* resource that mirrors the SCIM
      `value` of the multivalued's *primary* entry.

      With `relationship:` also set, the relationship is the source of
      truth for SCIM output and `mirror_primary_to:` keeps the parent
      scalar in sync (e.g. for use as a login identity).

      Without `relationship:`, the parent scalar **is** the source of
      truth: SCIM `emails` is collapsed to one element on read, and writes
      pick the primary entry's value into the scalar. The other
      sub-attributes (`primary`, `type`) can be filled in via static
      `value:` decorators on sub-`map`s.

      The primary entry is picked as: the entry with `primary: true` if
      one exists; otherwise the lexicographically first entry by `value`.

      Either `relationship:` or `mirror_primary_to:` must be set.
      """
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
