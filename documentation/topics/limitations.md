<!--
SPDX-FileCopyrightText: 2026 Zach Daniel

SPDX-License-Identifier: MIT
-->

# Known limitations

`AshScim` covers the SCIM 2.0 surface that mainstream IdPs actually
exercise. A handful of corners aren't implemented yet — none of them
prevent typical Okta or Azure AD provisioning flows from working, but
they're worth knowing about.

## Per-element `replace` via bracket filter on relationship-backed multivalueds

`replace path: "members[value eq \"u1\"].value"` — meaning "change the
membership for u1 to be for u2 instead" — isn't currently supported.
The simpler patterns work:

- `replace path: "members" value: [...]` — full-replace the membership set
- `add path: "members" value: [...]` — append new memberships
- `remove path: "members[value eq \"u1\"]"` — destroy specific memberships

Since `remove` followed by `add` achieves the same effect, no real-world
IdP integration we've seen relies on per-element replace.

## SCIM extension schemas

The Enterprise extension
(`urn:ietf:params:scim:schemas:extension:enterprise:2.0:User`, with
`manager`, `costCenter`, `department`, etc.) and custom schemas are not
currently representable in the DSL. Inbound extension blocks are
silently dropped (RFC 7644 §3.1 allows this), and we don't emit them.

If your IdP relies on these — Microsoft Entra ID does for org-chart
sync — open an issue. The DSL extension would look something like:

```elixir
scim do
  map :userName, attribute: :email

  extension "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User" do
    map :department, attribute: :department
    map :costCenter, attribute: :cost_center
  end
end
```

## PUT / PATCH on `schemas` array

The `schemas` claim in a SCIM resource declares which schemas the
resource conforms to. AshScim derives it from the resource's DSL
mappings, so mutating it from the IdP side isn't meaningful. Ops that
target `schemas` are silently ignored.

## Scope-limited filter operators

Filter expressions can only target attributes declared in the DSL
mappings. This is by design (see [Filter syntax](filters.md#security-closed-world-resolution))
but worth restating: if your Ash resource has an attribute the DSL
doesn't expose, no SCIM filter can reference it. To allow filtering,
add an explicit `map`.

## ETS-backed apps and atomicity

The PATCH flow runs inside `Ash.transact/2` and (when supported) takes a
`SELECT … FOR UPDATE` row lock. ETS supports neither, so PATCH ops run
sequentially without rollback semantics. This is fine for the test
suite but means a partial PATCH failure in an ETS-backed app leaves the
resource in a half-applied state. Postgres / SQL data layers get full
atomicity automatically.

---

If you hit a corner not listed here, please open an issue — concrete
IdP requests make the right design fall out much faster than abstract
spec compliance.
