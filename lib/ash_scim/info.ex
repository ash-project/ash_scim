# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Info do
  @moduledoc """
  Introspection for the `AshScim.User` and `AshScim.Group` extensions.

  Use these helpers when you need to inspect a resource's SCIM mapping at
  runtime (e.g. in routers, plugs, or custom rendering code).
  """

  use Spark.InfoGenerator,
    extension: AshScim.User,
    sections: [:scim]

  alias AshScim.Dsl.{Complex, Extension, Map, Multivalued}

  @doc """
  Returns `true` if `resource` carries either the `AshScim.User` or
  `AshScim.Group` extension.
  """
  @spec scim_resource?(module()) :: boolean()
  def scim_resource?(resource) do
    extensions = Spark.extensions(resource)
    AshScim.User in extensions or AshScim.Group in extensions
  end

  @doc """
  Returns the SCIM resource type for `resource` — `:user`, `:group`, or `nil`.
  """
  @spec scim_type(module()) :: :user | :group | nil
  def scim_type(resource) do
    extensions = Spark.extensions(resource)

    cond do
      AshScim.User in extensions -> :user
      AshScim.Group in extensions -> :group
      true -> nil
    end
  end

  @doc """
  Returns all SCIM mapping entities (maps, complex, multivalued) declared on
  the resource, preserving declaration order.
  """
  @spec scim_mappings(module()) :: [Map.t() | Complex.t() | Multivalued.t() | Extension.t()]
  def scim_mappings(resource) do
    Spark.Dsl.Extension.get_entities(resource, [:scim])
  end

  @doc "Returns the declared SCIM schema-extension URNs for `resource`."
  @spec scim_extension_urns(module()) :: [String.t()]
  def scim_extension_urns(resource) do
    resource
    |> scim_mappings()
    |> Enum.filter(&match?(%Extension{}, &1))
    |> Enum.map(& &1.urn)
  end
end
