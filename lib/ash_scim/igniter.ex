# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Igniter) do
  defmodule AshScim.Igniter do
    @moduledoc """
    Igniter helpers used by `mix ash_scim.install` and friends. None of
    these touch runtime introspection — they all read and write the
    project's source files via `Igniter` so the installer can run before
    the user's code is compiled.
    """

    @doc """
    Returns `{igniter, true}` if the resource already declares a `scim`
    DSL block, `{igniter, false}` otherwise. Used to make the installer
    idempotent.
    """
    @spec has_scim_section?(Igniter.t(), module()) :: {Igniter.t(), boolean()}
    def has_scim_section?(igniter, resource) do
      Spark.Igniter.find(igniter, resource, fn _, zipper ->
        case Igniter.Code.Function.move_to_function_call_in_current_scope(zipper, :scim, 1) do
          {:ok, _zipper} -> {:ok, true}
          :error -> :error
        end
      end)
      |> case do
        {:ok, igniter, _module, _value} -> {igniter, true}
        {:error, igniter} -> {igniter, false}
      end
    end

    @doc """
    Adds the `AshScim.Checks.AshScimInteraction` bypass policy to the
    resource. Idempotent — re-running won't duplicate the bypass.
    """
    @spec ensure_scim_bypass(Igniter.t(), module()) :: Igniter.t()
    def ensure_scim_bypass(igniter, resource) do
      case has_scim_bypass?(igniter, resource) do
        {igniter, true} ->
          igniter

        {igniter, false} ->
          Ash.Resource.Igniter.add_bypass(
            igniter,
            resource,
            quote do
              AshScim.Checks.AshScimInteraction
            end,
            quote do
              authorize_if(always())
            end
          )
      end
    end

    defp has_scim_bypass?(igniter, resource) do
      Spark.Igniter.find(igniter, resource, fn _, zipper ->
        with {:ok, zipper} <-
               Igniter.Code.Function.move_to_function_call_in_current_scope(zipper, :policies, 1),
             {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper),
             {:ok, _} <-
               Igniter.Code.Function.move_to_function_call_in_current_scope(
                 zipper,
                 :bypass,
                 [1, 2],
                 fn call ->
                   Igniter.Code.Function.argument_equals?(
                     call,
                     0,
                     AshScim.Checks.AshScimInteraction
                   )
                 end
               ) do
          {:ok, true}
        else
          _ -> :error
        end
      end)
      |> case do
        {:ok, igniter, _module, _value} -> {igniter, true}
        {:error, igniter} -> {igniter, false}
      end
    end

    @doc """
    Adds a `scim do ... end` block with the given body to the resource if
    one isn't already declared. Idempotent — re-running won't duplicate
    the contents.

    Uses `Spark.Igniter.update_dsl/5` to handle section creation: if
    `scim do ... end` doesn't exist, Spark adds an empty one and walks
    inside it; we then drop our parsed `body` AST in. If it already
    exists, the existence check up front short-circuits, so we don't
    risk appending duplicates.
    """
    @spec add_scim_section(Igniter.t(), module(), String.t()) :: Igniter.t()
    def add_scim_section(igniter, resource, body) do
      case has_scim_section?(igniter, resource) do
        {igniter, true} ->
          igniter

        {igniter, false} ->
          Spark.Igniter.update_dsl(
            igniter,
            resource,
            [{:section, :scim}],
            Sourceror.parse_string!(body),
            fn zipper ->
              # Reachable when the section's do-block somehow already had
              # content but our `has_scim_section?` check missed it. Append
              # rather than replace to be conservative.
              {:ok, Igniter.Code.Common.add_code(zipper, body)}
            end
          )
      end
    end
  end
end
