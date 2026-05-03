# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Discovery do
  @moduledoc """
  Generates the SCIM 2.0 discovery documents — `Schemas` (RFC 7643 §7) and
  `ResourceTypes` (RFC 7644 §4) — directly from the resource DSL.

  These endpoints let SCIM clients introspect what the server supports
  without reading our docs. Most IdPs hit them once during initial setup
  to validate that user/group attributes line up.
  """

  alias AshScim.Dsl.{Complex, Map, Multivalued}

  @schema_schema "urn:ietf:params:scim:schemas:core:2.0:Schema"
  @resource_type_schema "urn:ietf:params:scim:schemas:core:2.0:ResourceType"
  @list_response_schema "urn:ietf:params:scim:api:messages:2.0:ListResponse"

  @doc "Build a `ListResponse` of every Schema document for the given resources."
  @spec schemas([module()]) :: %{String.t() => term()}
  def schemas(resources) do
    list = Enum.map(resources, &schema/1)

    %{
      "schemas" => [@list_response_schema],
      "totalResults" => length(list),
      "Resources" => list
    }
  end

  @doc "Build the Schema document for a single resource."
  @spec schema(module()) :: %{String.t() => term()}
  def schema(resource) do
    schema_id = AshScim.Info.scim_schema!(resource)
    type = AshScim.Info.scim_type(resource)

    %{
      "schemas" => [@schema_schema],
      "id" => schema_id,
      "name" => resource_type_name(type),
      "description" => "SCIM #{resource_type_name(type)} schema for #{inspect(resource)}",
      "attributes" => attribute_definitions(resource)
    }
  end

  @doc "Build a `ListResponse` of every ResourceType document for the given resources."
  @spec resource_types([module()]) :: %{String.t() => term()}
  def resource_types(resources) do
    list = Enum.map(resources, &resource_type/1)

    %{
      "schemas" => [@list_response_schema],
      "totalResults" => length(list),
      "Resources" => list
    }
  end

  @doc "Build the ResourceType document for a single resource."
  @spec resource_type(module()) :: %{String.t() => term()}
  def resource_type(resource) do
    type = AshScim.Info.scim_type(resource)
    name = resource_type_name(type)
    schema_id = AshScim.Info.scim_schema!(resource)
    path = AshScim.Info.scim_path!(resource)

    %{
      "schemas" => [@resource_type_schema],
      "id" => name,
      "name" => name,
      "endpoint" => path,
      "description" => "#{name} resource",
      "schema" => schema_id
    }
  end

  defp resource_type_name(:user), do: "User"
  defp resource_type_name(:group), do: "Group"

  defp attribute_definitions(resource) do
    resource
    |> AshScim.Info.scim_mappings()
    |> Enum.map(&attribute_definition(&1, resource))
  end

  defp attribute_definition(%Map{} = m, resource) do
    %{
      "name" => to_string(m.name),
      "type" => map_type(m, resource),
      "multiValued" => false,
      "required" => map_required?(m, resource),
      "caseExact" => m.case_exact? || false,
      "mutability" => mutability(m.mutability),
      "returned" => returned(m.returned),
      "uniqueness" => uniqueness(m.uniqueness)
    }
  end

  defp attribute_definition(%Complex{} = c, resource) do
    %{
      "name" => to_string(c.name),
      "type" => "complex",
      "multiValued" => false,
      "required" => false,
      "mutability" => mutability(c.mutability),
      "returned" => returned(c.returned),
      "subAttributes" => Enum.map(c.maps, &attribute_definition(&1, resource))
    }
  end

  defp attribute_definition(%Multivalued{} = mv, resource) do
    sub_resource = related_resource(mv, resource) || resource

    %{
      "name" => to_string(mv.name),
      "type" => "complex",
      "multiValued" => true,
      "required" => false,
      "mutability" => mutability(mv.mutability),
      "returned" => returned(mv.returned),
      "subAttributes" => Enum.map(mv.maps, &attribute_definition(&1, sub_resource))
    }
  end

  defp related_resource(%Multivalued{relationship: nil}, _resource), do: nil

  defp related_resource(%Multivalued{relationship: rel}, resource) do
    case Ash.Resource.Info.relationship(resource, rel) do
      %{destination: dest} -> dest
      _ -> nil
    end
  end

  # Type inference: a static-value mapping uses the literal's type; an
  # attribute-backed mapping uses the resource attribute's type.
  defp map_type(%Map{value: value}, _resource) when not is_nil(value) do
    scim_type_for(value)
  end

  defp map_type(%Map{attribute: nil}, _resource), do: "string"

  defp map_type(%Map{attribute: attr}, resource) do
    case Ash.Resource.Info.attribute(resource, attr) do
      %{type: t} -> ash_type_to_scim(t)
      _ -> "string"
    end
  end

  defp scim_type_for(v) when is_boolean(v), do: "boolean"
  defp scim_type_for(v) when is_integer(v), do: "integer"
  defp scim_type_for(v) when is_float(v), do: "decimal"
  defp scim_type_for(_), do: "string"

  defp ash_type_to_scim(Ash.Type.Boolean), do: "boolean"
  defp ash_type_to_scim(Ash.Type.Integer), do: "integer"
  defp ash_type_to_scim(Ash.Type.Float), do: "decimal"
  defp ash_type_to_scim(Ash.Type.Decimal), do: "decimal"
  defp ash_type_to_scim(Ash.Type.UtcDatetime), do: "dateTime"
  defp ash_type_to_scim(Ash.Type.UtcDatetimeUsec), do: "dateTime"
  defp ash_type_to_scim(Ash.Type.NaiveDatetime), do: "dateTime"
  defp ash_type_to_scim(Ash.Type.Date), do: "dateTime"
  defp ash_type_to_scim(Ash.Type.Binary), do: "binary"
  defp ash_type_to_scim(_), do: "string"

  defp map_required?(%Map{attribute: nil}, _resource), do: false

  defp map_required?(%Map{attribute: attr}, resource) do
    case Ash.Resource.Info.attribute(resource, attr) do
      %{allow_nil?: false} -> true
      _ -> false
    end
  end

  defp mutability(nil), do: "readWrite"
  defp mutability(:read_only), do: "readOnly"
  defp mutability(:read_write), do: "readWrite"
  defp mutability(:immutable), do: "immutable"
  defp mutability(:write_only), do: "writeOnly"

  defp returned(nil), do: "default"
  defp returned(value) when is_atom(value), do: Atom.to_string(value)

  defp uniqueness(nil), do: "none"
  defp uniqueness(value) when is_atom(value), do: Atom.to_string(value)
end
