<!--
SPDX-FileCopyrightText: 2026 Zach Daniel

SPDX-License-Identifier: MIT
-->

# AshScim

[![Hex.pm](https://img.shields.io/hexpm/v/ash_scim.svg)](https://hex.pm/packages/ash_scim)
[![REUSE status](https://api.reuse.software/badge/github.com/ash-project/ash_scim)](https://api.reuse.software/info/github.com/ash-project/ash_scim)

A [SCIM 2.0](https://datatracker.ietf.org/doc/html/rfc7644) server extension for
the [Ash Framework](https://ash-hq.org).

`AshScim` lets identity providers (Okta, Azure AD, OneLogin, etc.) provision
users and groups into your application by exposing standards-compliant SCIM
endpoints over your existing Ash resources.

It is intentionally orthogonal to authentication: SCIM only describes how user
and group records are synchronized — login itself remains the responsibility of
[`ash_authentication`](https://github.com/team-alembic/ash_authentication) (or
any other strategy you choose).

## Status

Early development — API is not yet stable.

## Installation

```elixir
def deps do
  [
    {:ash_scim, "~> 0.1"}
  ]
end
```

## Multi-valued attributes

SCIM multi-valued attributes (`emails`, `phoneNumbers`, `members`, etc.)
have two flavors in `AshScim`:

**Single-attribute-backed** — the default. The multivalued maps to one Ash
attribute on the resource and emits a one-element array. Ideal for "user
has one email which is also their identity":

```elixir
multivalued :emails do
  map :value, attribute: :email
  map :primary, value: true
end
```

When decoding inbound payloads with multiple email entries, the entry
marked `primary: true` is preferred; otherwise the first entry wins.

**Relationship-backed** — for true many-rows-per-resource cases like group
members. The multivalued points at a `has_many` relationship, and each
array element corresponds to one related row:

```elixir
# in your Group resource
scim do
  map :displayName, attribute: :name

  multivalued :members do
    relationship :memberships
    map :value, attribute: :user_id
  end
end

relationships do
  has_many :memberships, MyApp.Accounts.Membership do
    destination_attribute :group_id
  end
end
```

`POST` / `PUT` bodies, `PATCH add path: members`, `PATCH replace path:
members`, and `PATCH remove path: members[value eq "user-id"]` all map
through to the relationship as you'd expect. A compile-time verifier
checks that the relationship is declared, is a `has_many`, and that every
sub-map's `:attribute` exists on the related resource.

## Demo app & compliance testing

A working Phoenix app using AshScim lives at `demo/`. It wires
`AshAuthentication`, `ash_postgres`, and `AshScim` together with `User`,
`Group`, and `Membership` resources.

To run it locally:

```sh
cd demo
mix deps.get
mix ash.setup
mix run priv/repo/seeds.exs   # prints a SCIM bearer token
PORT=4002 mix phx.server
```

To validate against the
[`scim2-tester`](https://github.com/python-scim/scim2-tester) compliance
suite:

```sh
pipx install scim2-cli
TOKEN=...   # paste from seeds output
scim -u http://localhost:4002/scim/v2 -h "Authorization:Bearer $TOKEN" test
```

CI runs this suite on every push and pull request — see
`.github/workflows/scim_compliance.yml`. The current bar is **≥ 51
successes / ≤ 3 errors**, the latter being known-acceptable artifacts of
the demo's `User.email` being both required and unique (see Limitations).

## Limitations

- **`sw` / `ew` filter operators** (RFC 7644 §3.4.2.2). These appear almost
  exclusively in admin search UIs, not in IdP-to-server provisioning, so
  the practical impact is nil. Filters using them return
  `400 invalidValue`.

- **Per-element `replace` via bracket filter on relationship-backed
  multivalueds.** `replace path: members[value eq "u1"].value` is not yet
  wired up — most IdPs achieve the same effect with `remove` followed by
  `add`, which both work.

If your integration hits one of these corners, please open an issue with
the IdP and the exact request — concrete examples make the right design
fall out much faster than abstract spec compliance.

## License

`AshScim` is licensed under the MIT license. See `LICENSES/` for details. The
project is [REUSE](https://reuse.software) compliant.
