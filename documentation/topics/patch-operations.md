<!--
SPDX-FileCopyrightText: 2026 Zach Daniel

SPDX-License-Identifier: MIT
-->

# PATCH operations

SCIM 2.0 PATCH (RFC 7644 §3.5.2) is the most expressive part of the
protocol — and the one that varies the most between IdPs. AshScim parses
PATCH bodies into a structured shape the router applies atomically.

## The shape of a PATCH body

```json
{
  "schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
  "Operations": [
    {"op": "replace", "path": "active", "value": false},
    {"op": "replace", "path": "name.givenName", "value": "Alicia"},
    {"op": "add",     "path": "members",
                       "value": [{"value": "user-c"}]},
    {"op": "remove",  "path": "members[value eq \"user-a\"]"}
  ]
}
```

Each operation has:

- `op` — `add`, `replace`, or `remove`
- `path` — the target (optional for `add` and `replace`)
- `value` — the new value (required for `add` and `replace`)

## The path expression grammar

PATCH `path` values come in four shapes:

| Shape | Example |
| --- | --- |
| Simple | `userName` |
| Sub-attribute | `name.givenName` |
| Bracket filter | `emails[type eq "work"]` |
| Bracket filter + sub | `emails[type eq "work"].value` |

The bracket filter is a sub-set of the SCIM filter grammar and is
resolved against the sub-attributes of the multi-valued attribute being
targeted. See [Filter syntax](filters.md) for the operators.

## Supported operations

### `replace path: "scalar" value: …`

Sets the underlying Ash attribute. `name.givenName` writes to the
attribute mapped by the `:givenName` sub-`map` of the `:name` complex
attribute. Works for any simple or complex sub-attribute.

### `replace path: "name" value: {givenName: …, familyName: …}`

Bare-path replace on a complex attribute decodes the value through the
complex's sub-`map`s and merges all the underlying attributes in one
update.

### `add` / `replace` with no path, `value` is a partial SCIM object

The decoder runs over the value as if it were a partial SCIM resource;
each declared mapping that appears writes to its underlying attribute.
Useful as "merge this object into the resource."

Path-less ops only carry attribute changes — relationship arrays in the
value are ignored, since the semantics of "add a partial resource that
also includes a member list" aren't well-defined in the spec.

### `remove path: "scalar"`

Sets the underlying attribute to `nil`. Whether your resource accepts
that depends on its `allow_nil?` declaration; if not, you get a
`400 invalidValue`.

### `remove path: "name"`

Removes a complex attribute by setting all its sub-`map` attributes to
`nil` in one update.

### `add path: "members" value: [...]`

For relationship-backed multivalueds, **append** new related rows. Uses
`Ash.Changeset.manage_relationship/4` with
`on_no_match: :create, on_match: :ignore`. Existing related rows are
left in place.

### `replace path: "members" value: [...]`

For relationship-backed multivalueds, **full-replace** the related rows.
`manage_relationship` with
`on_no_match: :create, on_match: :ignore, on_missing: :destroy`.

### `remove path: "members"` (no filter)

Clears all related rows. Equivalent to `replace` with an empty array.

### `remove path: "members[value eq \"user-id\"]"`

Destroys the related rows matching the bracket filter.

When the relationship is a plain `has_many` (no relationship-level
filter, not `many_to_many`), the router builds a single query:

```elixir
Membership
|> Ash.Query.filter_input(%{
     and: [
       %{user_id: %{eq: "user-id"}},
       %{group_id: %{eq: ^parent_group_id}}
     ]
   })
|> Ash.bulk_destroy(:destroy, %{}, ...)
```

For more complex relationships (with their own `filter expr(...)` clause,
or `many_to_many`), it falls back to loading through the relationship
and destroying the loaded records — that path correctly applies the
relationship's own scoping rules.

## Atomicity

The whole PATCH — the `Ash.update` for attribute changes,
`manage_relationship` for append/replace ops, and the post-update
`bulk_destroy` for `:remove_where` ops — runs inside a single
`Ash.transact/2` call. If any step fails, the entire transaction rolls
back. There is no partial-PATCH state.

On data layers that support row-level locking (Postgres), the parent
record is fetched with `Ash.Query.lock(:for_update)`, so concurrent SCIM
PATCHes against the same record serialize cleanly.

## Not yet supported

- **Per-element `replace` via bracket filter on relationship-backed
  multivalueds.** `replace path: "members[value eq \"u1\"].value"` with
  intent "change u1 to u2" is not currently wired up; most IdPs achieve
  the same effect with `remove` followed by `add`, both of which work.

- **PATCH ops that target the schemas array** (e.g. adding/removing
  schema URNs from the `schemas` claim). Since AshScim derives
  `schemas` from the resource's DSL, mutating it from the IdP side
  isn't meaningful.
