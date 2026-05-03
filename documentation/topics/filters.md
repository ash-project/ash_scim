<!--
SPDX-FileCopyrightText: 2026 Zach Daniel

SPDX-License-Identifier: MIT
-->

# Filter syntax

SCIM clients can filter list responses (`GET /Users?filter=…`) and search
endpoints (`POST /Users/.search`) using the SCIM 2.0 filter grammar
defined in
[RFC 7644 §3.4.2.2](https://datatracker.ietf.org/doc/html/rfc7644#section-3.4.2.2).
AshScim parses these filters into the map-shaped input format consumed by
`Ash.Query.filter_input/2`, with the security-critical attribute
resolution done in the same pass.

## Operator support

| SCIM | Ash | Example |
| --- | --- | --- |
| `eq` | `eq` | `userName eq "alice"` |
| `ne` | `not_eq` | `active ne true` |
| `co` | `contains` | `userName co "alice"` |
| `pr` | `is_nil: false` | `externalId pr` |
| `gt` | `greater_than` | `created gt "2024-01-01"` |
| `ge` | `greater_than_or_equal` | `created ge "2024-01-01"` |
| `lt` | `less_than` | `created lt "2024-12-31"` |
| `le` | `less_than_or_equal` | `created le "2024-12-31"` |

`sw` (starts with) and `ew` (ends with) are not currently implemented.
They appear almost exclusively in admin search UIs, not in
IdP-to-server provisioning, so the practical impact is nil. Filters using
them return `400 invalidValue`.

## Boolean composition

`and`, `or`, and parenthesized `not (...)` are supported with the standard
precedence (`not` > `and` > `or`):

```
userName eq "alice" or userName eq "bob"
active eq true and externalId pr
not (active eq true)
(userName co "alice" or userName co "bob") and active eq true
```

Chained `and`s and `or`s flatten into a single list:

- `a or b or c` parses to `%{or: [a, b, c]}`
- `a and b and c` parses to `%{and: [a, b, c]}`

## Dotted paths

Sub-attributes of `complex` and `multivalued` mappings are addressable via
dotted paths:

```
name.familyName co "Anderson"
emails.value eq "alice@example.com"
```

For complex and single-attribute multivalueds, the dotted path resolves
through the sub-`map`s to the underlying scalar attribute and emits a flat
filter (`%{last_name: %{contains: "Anderson"}}`).

For **relationship-backed multivalueds**, the dotted path emits Ash's
native nested filter form:

```elixir
# members.value eq "u1" against a Group
%{memberships: %{user_id: %{eq: "u1"}}}
```

This traverses the `:memberships` relationship, so a query like
`?filter=members.value eq "u1"` finds groups whose `memberships` include
the matching user.

## Security: closed-world resolution

The filter resolver is the security boundary between IdP-supplied input
and your data layer. The rule it enforces:

> **Every attribute path in the filter must be declared in the resource's
> SCIM mappings.** Anything else fails closed.

If an IdP sends `?filter=password eq "hunter2"`, the resolver sees that
`password` is not a declared SCIM attribute on this resource and returns
`400 invalidFilter` — even if the resource has a `password` Ash attribute.
The filter cannot reach the data layer.

This means **filters can only target what the DSL exposes**. If you have
`attribute :department, :string` on the resource but don't write
`map :department, attribute: :department`, IdP filters can't reference
it. For SCIM that's correct — you don't expose what you didn't declare.

## Sorting

SCIM `?sortBy=` parameters go through the same resolution pipeline. A
sort by an unmapped attribute fails with `400 invalidValue`.

```
GET /Users?sortBy=userName&sortOrder=descending
```

`sortOrder` accepts `ascending` (default) or `descending`.
