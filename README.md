<!--
SPDX-FileCopyrightText: 2026 Zach Daniel

SPDX-License-Identifier: MIT
-->

![Logo](https://github.com/ash-project/ash/blob/main/logos/cropped-for-header-black-text.png?raw=true#gh-light-mode-only)
![Logo](https://github.com/ash-project/ash/blob/main/logos/cropped-for-header-white-text.png?raw=true#gh-dark-mode-only)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Hex version badge](https://img.shields.io/hexpm/v/ash_scim.svg)](https://hex.pm/packages/ash_scim)
[![Hexdocs badge](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/ash_scim)
[![REUSE status](https://api.reuse.software/badge/github.com/ash-project/ash_scim)](https://api.reuse.software/info/github.com/ash-project/ash_scim)

# AshScim

Welcome! `AshScim` is a [SCIM 2.0](https://datatracker.ietf.org/doc/html/rfc7644)
server extension for the [Ash Framework](https://hexdocs.pm/ash). It lets
identity providers (Okta, Azure AD / Entra, OneLogin, JumpCloud, …) provision
users and groups into your application by exposing standards-compliant
SCIM endpoints over your existing Ash resources. This documentation is
best viewed on [hexdocs](https://hexdocs.pm/ash_scim).

`AshScim` is intentionally orthogonal to authentication: SCIM only describes
how user and group records are synchronized — login itself remains the
responsibility of [`ash_authentication`](https://hexdocs.pm/ash_authentication)
(or any other strategy you choose). The two integrate cleanly: AshScim
can authenticate IdP requests using JWTs minted and stored by
AshAuthentication.

## Status

Early development — API is not yet stable. The library is end-to-end
validated against the
[`scim2-tester`](https://github.com/python-scim/scim2-tester) compliance
suite in CI.

## About the Documentation

[**Tutorials**](#tutorials) walk you through a series of steps to
accomplish a goal. These are **learning-oriented**, and are a great
place for beginners to start.

---

[**Topics**](#topics) provide a high level overview of a specific
concept or feature. These are **understanding-oriented**, and are
perfect for discovering design patterns, features, and tools related to
a given topic.

---

[**Reference**](#reference) documentation is produced automatically from
our source code. It comes in the form of module documentation and DSL
documentation. This documentation is **information-oriented**. Use the
sidebar and the search bar to find relevant reference information.

## Tutorials

- [Get Started](documentation/tutorials/get-started.md)

---

## Topics

- [Multi-valued attributes](documentation/topics/multi-valued-attributes.md) —
  single-attribute vs relationship-backed multivalueds.
- [Filter syntax](documentation/topics/filters.md) — operators, dotted
  paths, security guarantees.
- [PATCH operations](documentation/topics/patch-operations.md) — what the
  router does with each kind of `PatchOp`.
- [Authentication](documentation/topics/authentication.md) — `StaticBearer`
  and AshAuthentication-backed JWTs.
- [Policies & the bypass check](documentation/topics/policies.md) — letting
  the router run unimpeded by application policies.
- [Multi-tenancy](documentation/topics/multitenancy.md) — attribute and
  context strategies, per-tenant IdPs.
- [Limitations](documentation/topics/limitations.md) — known gaps.

---

## Reference

- [AshScim.User DSL](documentation/dsls/DSL-AshScim.User.md)
- [AshScim.Group DSL](documentation/dsls/DSL-AshScim.Group.md)
- For other reference documentation, see the sidebar & search bar.

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
the demo's `User.email` being both required and unique (see
[Limitations](documentation/topics/limitations.md)).

## Related packages

- [Ash Framework](https://hexdocs.pm/ash)
- [Ash Authentication](https://hexdocs.pm/ash_authentication) | Authenticate
  users with password, OAuth, and more — pairs naturally with AshScim
  for JWT-based bearer authentication of SCIM clients.
- [Ash Postgres](https://hexdocs.pm/ash_postgres) | PostgreSQL data layer
  — required if you want PATCH atomicity with row-level locking.
