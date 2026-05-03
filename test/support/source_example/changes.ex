# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Test.SourceExample.StampSource do
  @moduledoc """
  Reads the request-scoped `scim_source` that the auth implementation
  put on the conn (then onto the changeset's context by the router) and
  writes it onto the new record's `:scim_source` attribute.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case get_in(changeset.context, [:private, :scim_source]) do
      nil ->
        Ash.Changeset.add_error(
          changeset,
          field: :scim_source,
          message: "scim_source not set on request context"
        )

      source ->
        Ash.Changeset.force_change_attribute(changeset, :scim_source, source)
    end
  end
end

defmodule AshScim.Test.SourceExample.ScopeBySource do
  @moduledoc """
  Filters reads to records whose `:scim_source` matches the request-scoped
  `scim_source` set by the auth implementation. Demonstrates the same
  context-flowing-through-to-queries pattern as the changeset side.
  """

  use Ash.Resource.Preparation
  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    case get_in(query.context, [:private, :scim_source]) do
      nil -> Ash.Query.filter_input(query, %{scim_source: %{eq: "__no_match__"}})
      source -> Ash.Query.filter_input(query, %{scim_source: %{eq: source}})
    end
  end
end
