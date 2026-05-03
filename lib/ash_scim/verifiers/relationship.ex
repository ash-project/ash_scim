# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Verifiers.Relationship do
  @moduledoc """
  Compile-time verifier for relationship-backed multivalued attributes.

  When a `multivalued` block declares a `relationship`, this verifier
  ensures the relationship is wired up coherently:

    * the relationship exists on the resource
    * it is a `has_many`
    * every sub-`map` whose `:attribute` is set names a real attribute on
      the related resource

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
    |> Enum.filter(fn
      %Multivalued{relationship: rel} when is_atom(rel) and not is_nil(rel) -> true
      _ -> false
    end)
    |> Enum.reduce_while(:ok, fn mv, :ok ->
      case verify_multivalued(mv, dsl_state, resource) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp verify_multivalued(%Multivalued{name: name, relationship: rel, maps: maps}, dsl_state, resource) do
    rel_def = Ash.Resource.Info.relationship(dsl_state, rel)

    with :ok <- ensure_relationship(rel_def, rel, name, resource),
         :ok <- ensure_has_many(rel_def, rel, name, resource),
         :ok <- ensure_sub_attributes(rel_def, name, maps, resource) do
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
