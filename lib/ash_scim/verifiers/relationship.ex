# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Verifiers.Relationship do
  @moduledoc """
  Compile-time verifier for `multivalued` declarations.

  For relationship-backed multivalueds:

    * the relationship exists on the resource
    * it is a `has_many`
    * every sub-`map` whose `:attribute` is set names a real attribute on
      the related resource

  For multivalueds with `mirror_primary_to:`:

    * `mirror_primary_to` requires `relationship:` to also be set
    * the named attribute exists on the parent resource
    * the multivalued declares a sub-`map` for the SCIM `:value`
      sub-attribute (since that's what gets mirrored)

  This catches typos at compile time so users don't get cryptic runtime
  errors from `manage_relationship` or the encoder's load step.
  """

  use Spark.Dsl.Verifier

  alias AshScim.Dsl.{Map, Multivalued}
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    resource = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Spark.Dsl.Verifier.get_entities([:scim])
    |> Enum.filter(&match?(%Multivalued{}, &1))
    |> Enum.reduce_while(:ok, fn mv, :ok ->
      case verify_multivalued(mv, dsl_state, resource) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp verify_multivalued(%Multivalued{} = mv, dsl_state, resource) do
    with :ok <- verify_at_least_one_form(mv, resource),
         :ok <- verify_relationship(mv, dsl_state, resource) do
      verify_mirror_primary_to(mv, dsl_state, resource)
    end
  end

  defp verify_at_least_one_form(
         %Multivalued{name: name, relationship: nil, mirror_primary_to: nil},
         resource
       ) do
    {:error,
     DslError.exception(
       module: resource,
       path: [:scim, :multivalued, name],
       message:
         "multivalued `:#{name}` must set either `relationship:` (one row per entry) " <>
           "or `mirror_primary_to:` (collapse to a single scalar on the parent), " <>
           "or both."
     )}
  end

  defp verify_at_least_one_form(_mv, _resource), do: :ok

  defp verify_relationship(%Multivalued{relationship: nil}, _dsl_state, _resource), do: :ok

  defp verify_relationship(
         %Multivalued{name: name, relationship: rel, maps: maps},
         dsl_state,
         resource
       ) do
    rel_def = Ash.Resource.Info.relationship(dsl_state, rel)

    with :ok <- ensure_relationship(rel_def, rel, name, resource),
         :ok <- ensure_has_many(rel_def, rel, name, resource) do
      ensure_sub_attributes(rel_def, name, maps, resource)
    end
  end

  defp verify_mirror_primary_to(%Multivalued{mirror_primary_to: nil}, _dsl_state, _resource),
    do: :ok

  defp verify_mirror_primary_to(
         %Multivalued{name: name, mirror_primary_to: attr, relationship: rel, maps: maps},
         dsl_state,
         resource
       ) do
    cond do
      Ash.Resource.Info.attribute(dsl_state, attr) == nil ->
        {:error,
         DslError.exception(
           module: resource,
           path: [:scim, :multivalued, name],
           message:
             "multivalued `:#{name}` sets `mirror_primary_to: :#{attr}` but `:#{attr}` is " <>
               "not declared as an attribute on #{inspect(resource)}."
         )}

      not is_nil(rel) and not Enum.any?(maps, &match?(%Map{name: :value}, &1)) ->
        {:error,
         DslError.exception(
           module: resource,
           path: [:scim, :multivalued, name],
           message:
             "multivalued `:#{name}` is relationship-backed and sets " <>
               "`mirror_primary_to: :#{attr}` but does not declare a `map :value, ...` " <>
               "sub-attribute. Mirroring copies the SCIM `value` sub-attribute of the " <>
               "primary entry into the parent."
         )}

      true ->
        :ok
    end
  end

  defp ensure_relationship(nil, rel, mv_name, resource) do
    {:error,
     DslError.exception(
       module: resource,
       path: [:scim, :multivalued, mv_name],
       message:
         "multivalued `:#{mv_name}` references relationship `:#{rel}` which is not declared on the resource"
     )}
  end

  defp ensure_relationship(_rel_def, _rel, _mv_name, _resource), do: :ok

  defp ensure_has_many(%{type: :has_many}, _rel, _mv_name, _resource), do: :ok

  defp ensure_has_many(%{type: type}, rel, mv_name, resource) do
    {:error,
     DslError.exception(
       module: resource,
       path: [:scim, :multivalued, mv_name],
       message:
         "multivalued `:#{mv_name}` references relationship `:#{rel}` which is `#{inspect(type)}` — only `has_many` is supported"
     )}
  end

  defp ensure_has_many(_, _, _, _), do: :ok

  defp ensure_sub_attributes(%{destination: dest}, mv_name, maps, resource) do
    attrs_to_check =
      maps
      |> Enum.filter(&match?(%Map{attribute: a} when not is_nil(a), &1))
      |> Enum.map(& &1.attribute)

    Enum.reduce_while(attrs_to_check, :ok, fn attr, :ok ->
      if Ash.Resource.Info.attribute(dest, attr) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          DslError.exception(
            module: resource,
            path: [:scim, :multivalued, mv_name],
            message:
              "multivalued `:#{mv_name}` map references attribute `:#{attr}` which is not declared on `#{inspect(dest)}`"
          )}}
      end
    end)
  end

  defp ensure_sub_attributes(_, _, _, _), do: :ok
end
