<!--
SPDX-FileCopyrightText: 2026 Zach Daniel

SPDX-License-Identifier: MIT
-->

# Multi-valued attributes

SCIM 2.0 makes a distinction between three attribute shapes:

- **Simple** — a scalar value (`"userName": "alice@example.com"`).
- **Complex** — a single nested object (`"name": {"givenName": "Alice", "familyName": "Anderson"}`).
- **Multi-valued** — an array of objects (`"emails": [{"value": "alice@x.com", "primary": true}]`).

`AshScim` exposes each via a corresponding DSL entity: `map`, `complex`, and
`multivalued`. This page covers the multi-valued case in detail, since it
has the most options and the most subtle semantics.

## Two ways a multivalued can be backed

A `multivalued` declaration is **always** an array on the wire — even if
your data model has only one row. AshScim supports two ways to back that
array, chosen by whether you set the `relationship` option.

### Single-attribute-backed (default)

When you don't set `relationship:`, the multivalued is backed by a single
field on the parent resource. The encoder always emits a one-element
array; the decoder collapses any inbound array to a single entry.

```elixir
multivalued :emails do
  map :value,   attribute: :email
  map :primary, value: true
  map :type,    value: "work"
end
```

This is the right choice when each user has exactly one email (or phone,
or address) and the value is also their identity. The `User.email` column
is your source of truth; SCIM gets a wrapped view of it.

**Decoding behavior**: when an IdP sends multiple entries (e.g. a primary
work email plus a personal one), the decoder picks the entry marked
`primary: true` and falls back to the first entry otherwise. A
`Logger.warning` fires if any entries are dropped, so operators can see
when an IdP is sending data the model can't preserve.

### Relationship-backed

When you set `relationship:`, the multivalued is backed by a `has_many`
relationship. Each array element corresponds to one related row.

```elixir
multivalued :members do
  relationship :memberships
  map :value, attribute: :user_id
end
```

This is the right choice when one parent record can have many entries —
canonically, group `members`. `POST` / `PUT` bodies carry the full list,
and PATCH ops manipulate individual rows.

The sub-`map` declarations reference attributes on the **related**
resource (here, `Membership`'s `:user_id`), not the parent.

A compile-time verifier (`AshScim.Verifiers.Relationship`) checks at
compile time that:

- the relationship exists on the resource;
- it is a `has_many`;
- every sub-`map`'s `:attribute` is declared on the related resource.

So typos fail early with a clear `Spark.Error.DslError`.

## Static-value sub-maps

Inside a `multivalued` (or `complex`) block, a `map` can be backed by a
literal `value:` instead of an Ash attribute:

```elixir
multivalued :emails do
  map :value, attribute: :email
  map :primary, value: true   # always emitted as `true`
  map :type, value: "work"    # always emitted as `"work"`
end
```

These mappings are **emit-only**. Inbound `primary: false` or
`type: "home"` values are silently ignored — there's no Ash attribute to
write them to. Useful when your data model doesn't track the distinction
the SCIM spec implies (e.g. you only have one email and it's always the
work one).

## Bracket-filter PATCH paths

SCIM clients can target a specific element of a multi-valued attribute
using a bracket filter in the PATCH path:

```
emails[type eq "work"].value
members[value eq "user-id-1"]
```

How AshScim handles them depends on which kind of multivalued is targeted:

- **Single-attribute-backed**: the bracket filter is informational. Since
  there's only one underlying field, the operation applies to it
  regardless of what the filter says. Syntax errors in the filter still
  fail fast.
- **Relationship-backed**: the bracket filter resolves through the sub-`map`s
  to attributes on the related resource. `members[value eq "u1"]` becomes
  "the membership row where `user_id == "u1"`", and PATCH `remove` deletes
  that row (via a `bulk_destroy` query when the relationship is a plain
  `has_many`, or load-and-destroy otherwise).

## When the model fits, when it doesn't

The standard SCIM core schemas declare these multi-valued attributes:

| Resource | Attribute | Single-attr OK? | Notes |
| --- | --- | --- | --- |
| User | `emails` | usually yes | most apps store one email per user |
| User | `phoneNumbers` | usually yes | same |
| User | `addresses` | sometimes | most apps don't model multiple |
| User | `groups` | n/a | this is a *back-reference*, read-only |
| Group | `members` | **no** | groups inherently have many members; relationship-backed only |
| User | `ims`, `photos`, `entitlements`, `roles`, `x509Certificates` | rarely used in practice |

If your app has a real has-many for emails or phones (e.g. a separate
`UserEmail` resource), use `relationship:`. If it doesn't, the
single-attribute model is fine — and the warning logs will tell you if an
IdP ever sends data you're dropping.
