# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Dsl do
  @moduledoc false

  alias AshScim.Dsl.{Complex, Extension, Map, Multivalued}

  @map_entity %Spark.Dsl.Entity{
    name: :map,
    target: AshScim.Dsl.Map,
    args: [:name],
    describe: "Map a SCIM attribute name to an Ash attribute (or a static value).",
    schema: Map.schema()
  }

  @complex_entity %Spark.Dsl.Entity{
    name: :complex,
    target: AshScim.Dsl.Complex,
    args: [:name],
    describe: "Declare a SCIM complex (object-valued) attribute.",
    schema: Complex.schema(),
    entities: [maps: [@map_entity]]
  }

  @multivalued_entity %Spark.Dsl.Entity{
    name: :multivalued,
    target: AshScim.Dsl.Multivalued,
    args: [:name],
    describe: "Declare a SCIM multi-valued attribute (an array of complex objects).",
    schema: Multivalued.schema(),
    entities: [maps: [@map_entity]]
  }

  @extension_entity %Spark.Dsl.Entity{
    name: :extension,
    target: AshScim.Dsl.Extension,
    args: [:urn],
    describe:
      "Map attributes that live under a SCIM schema-extension URN (RFC 7643 §3.3), e.g. the enterprise user extension.",
    schema: Extension.schema(),
    entities: [
      maps: [@map_entity],
      complexes: [@complex_entity],
      multivalueds: [@multivalued_entity]
    ]
  }

  @doc false
  def section(opts) do
    type = Keyword.fetch!(opts, :type)

    %Spark.Dsl.Section{
      name: :scim,
      describe: """
      Configure how this resource is exposed via SCIM 2.0.

      The presence of an `AshScim.User` or `AshScim.Group` extension enables
      this resource for inclusion in an `AshScim.Router`. Mapping declarations
      describe how Ash attributes are projected to and from SCIM JSON.
      """,
      schema: [
        path: [
          type: :string,
          default: default_path(type),
          doc: "URL path under which this resource is mounted (relative to the SCIM root)."
        ],
        schema: [
          type: :string,
          default: default_schema(type),
          doc: "The SCIM `schemas` URN advertised for this resource."
        ],
        read_action: [
          type: :atom,
          doc:
            "The Ash read action used by SCIM `GET` requests. Defaults to the resource's primary read action."
        ],
        create_action: [
          type: :atom,
          doc:
            "The Ash create action used by SCIM `POST` requests. Defaults to the resource's primary create action."
        ],
        update_action: [
          type: :atom,
          doc:
            "The Ash update action used by SCIM `PUT`/`PATCH` requests. Defaults to the resource's primary update action."
        ],
        destroy_action: [
          type: :atom,
          doc:
            "The Ash destroy action used by SCIM `DELETE` requests. Defaults to the resource's primary destroy action."
        ],
        meta?: [
          type: :boolean,
          default: true,
          doc:
            "Emit the standard SCIM `meta` object (created, lastModified, location, resourceType)."
        ]
      ],
      entities: [@map_entity, @complex_entity, @multivalued_entity, @extension_entity]
    }
  end

  defp default_path(:user), do: "/Users"
  defp default_path(:group), do: "/Groups"

  defp default_schema(:user), do: "urn:ietf:params:scim:schemas:core:2.0:User"
  defp default_schema(:group), do: "urn:ietf:params:scim:schemas:core:2.0:Group"
end
