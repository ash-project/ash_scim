# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Patch do
  @moduledoc """
  Translates a SCIM 2.0 PATCH request body (RFC 7644 §3.5.2) into a
  structured input describing both attribute updates and relationship-level
  operations:

      %{
        attrs: %{first_name: "Alicia"},
        relationships: [
          {:append, :memberships, [%{user_id: "u1"}]},
          {:remove_where, :memberships, %{user_id: %{eq: "u2"}}}
        ]
      }

  The router applies `attrs` via the resource's update action and each
  relationship op as either a `manage_relationship/4` call or a custom
  load+destroy/update step.

  ## Supported operations

    * `add` / `replace` with no path — value is treated as a partial SCIM
      resource and decoded via `AshScim.Decoder`. Only attribute changes are
      applied (relationship arrays in path-less ops are ignored, since the
      semantics of "add a partial resource that includes a member list"
      aren't well-defined).
    * `add` / `replace` / `remove` with a simple path (e.g. `active`,
      `name.givenName`) — maps to the corresponding Ash attribute.
    * `add path: "members" value: [...]` — append-style relationship op.
    * `replace path: "members" value: [...]` — full-replace relationship op.
    * `remove path: "members[value eq \"x\"]"` — load-and-destroy op against
      the related resource matching the bracket filter.
    * Bracket-filter paths on single-attribute multivalueds — filter is
      informational, op applies to the underlying attribute.
  """

  alias AshScim.Decoder
  alias AshScim.Dsl.{Complex, Map, Multivalued}
  alias AshScim.Patch.Path

  @schema "urn:ietf:params:scim:api:messages:2.0:PatchOp"

  @type op :: :add | :remove | :replace
  @type rel_op ::
          {:append, atom(), [%{atom() => term()}]}
          | {:replace_all, atom(), [%{atom() => term()}]}
          | {:remove_where, atom(), %{atom() => term()}}

  @type result :: %{
          attrs: %{atom() => term()},
          relationships: [rel_op()]
        }

  @doc """
  Build the structured patch input from a PATCH body. Returns
  `{:ok, %{attrs: …, relationships: …}}` or `{:error, reason}`.
  """
  @spec to_params(%{String.t() => term()}, module()) :: {:ok, result()} | {:error, term()}
  def to_params(%{"Operations" => ops}, resource) when is_list(ops) do
    Enum.reduce_while(ops, {:ok, %{attrs: %{}, relationships: []}}, fn op, {:ok, acc} ->
      case op_to_params(op, resource) do
        {:ok, %{attrs: a, relationships: r}} ->
          {:cont,
           {:ok,
            %{
              attrs: Elixir.Map.merge(acc.attrs, a),
              relationships: acc.relationships ++ r
            }}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  def to_params(_body, _resource), do: {:error, "PATCH body must include `Operations`"}

  @doc "Public schema URN for the PatchOp message."
  def schema, do: @schema

  defp op_to_params(%{"op" => op_str} = operation, resource) do
    with {:ok, op} <- normalize_op(op_str) do
      path = operation["path"]
      value = operation["value"]
      do_op(op, path, value, resource)
    end
  end

  defp op_to_params(_, _), do: {:error, "operation is missing `op`"}

  defp normalize_op(op) when is_binary(op) do
    case String.downcase(op) do
      "add" -> {:ok, :add}
      "remove" -> {:ok, :remove}
      "replace" -> {:ok, :replace}
      _ -> {:error, "unknown op `#{op}`"}
    end
  end

  defp normalize_op(_), do: {:error, "op must be a string"}

  # add/replace with no path → decode value as a partial SCIM resource.
  defp do_op(op, nil, value, resource) when op in [:add, :replace] do
    cond do
      is_map(value) ->
        decoded = Decoder.decode(resource, value)
        # Path-less ops only carry attribute changes for now.
        {:ok, %{attrs: decoded.attrs, relationships: []}}

      true ->
        {:error, "#{op} without a path requires an object value"}
    end
  end

  defp do_op(:remove, nil, _value, _resource) do
    {:error, "remove operations require a path"}
  end

  # add/replace/remove with a path (possibly containing a bracket filter).
  defp do_op(op, path, value, resource) when is_binary(path) do
    case Path.parse(path, resource) do
      {:ok, parsed} -> apply_parsed_op(op, parsed, value, resource, path)
      {:error, _} -> {:error, {:invalid_path, path}}
    end
  end

  defp do_op(_, _, _, _), do: {:error, "path must be a string"}

  # Relationship-backed multivalued ops.
  defp apply_parsed_op(op, %Path{relationship: rel} = parsed, value, resource, path)
       when is_atom(rel) and not is_nil(rel) do
    multivalued = find_multivalued(parsed.attribute, resource)

    case {op, parsed.filter, parsed.sub_attribute} do
      {:add, nil, nil} ->
        relationship_inputs(value, multivalued, :append, rel, path)

      {:replace, nil, nil} ->
        relationship_inputs(value, multivalued, :replace_all, rel, path)

      {:remove, nil, nil} ->
        # `remove path: "members"` with no filter clears the relationship.
        {:ok, %{attrs: %{}, relationships: [{:replace_all, rel, []}]}}

      {:remove, %{} = filter, nil} ->
        {:ok, %{attrs: %{}, relationships: [{:remove_where, rel, filter}]}}

      _ ->
        {:error, {:invalid_path, path}}
    end
  end

  # Bare path that resolves to a Complex — `add path: "name" value: {givenName: ...}`.
  defp apply_parsed_op(
         op,
         %Path{attribute: attr_str, sub_attribute: nil} = _parsed,
         value,
         resource,
         path
       ) do
    case find_complex(attr_str, resource) do
      %Complex{} = c ->
        apply_complex_op(op, c, value)

      nil ->
        apply_simple_op(op, %Path{attribute: attr_str, sub_attribute: nil}, value, resource, path)
    end
  end

  # Single-attribute multivalued or scalar attribute path.
  defp apply_parsed_op(op, parsed, value, resource, path) do
    apply_simple_op(op, parsed, value, resource, path)
  end

  defp apply_simple_op(op, parsed, value, resource, path) do
    case lookup_parsed_path(parsed, resource) do
      {:ok, attr} ->
        {:ok, %{attrs: %{attr => value_for(op, value)}, relationships: []}}

      {:error, _} ->
        {:error, {:invalid_path, path}}
    end
  end

  defp apply_complex_op(:remove, %Complex{maps: maps}, _value) do
    attrs =
      maps
      |> Enum.filter(&match?(%Map{attribute: a} when not is_nil(a), &1))
      |> Enum.map(&{&1.attribute, nil})
      |> Enum.into(%{})

    {:ok, %{attrs: attrs, relationships: []}}
  end

  defp apply_complex_op(_op, %Complex{maps: maps}, value) when is_map(value) do
    attrs =
      Enum.reduce(maps, %{}, fn
        %Map{attribute: nil}, acc ->
          acc

        %Map{name: name, attribute: attr}, acc ->
          case Elixir.Map.fetch(value, to_string(name)) do
            {:ok, v} -> Elixir.Map.put(acc, attr, v)
            :error -> acc
          end

        _, acc ->
          acc
      end)

    {:ok, %{attrs: attrs, relationships: []}}
  end

  defp apply_complex_op(_op, _complex, _value),
    do: {:error, "expected an object value for complex attribute"}

  defp find_complex(attr_string, resource) do
    Enum.find(AshScim.Info.scim_mappings(resource), fn
      %Complex{name: name} -> Atom.to_string(name) == attr_string
      _ -> false
    end)
  end

  defp find_multivalued(attr_string, resource) do
    Enum.find(AshScim.Info.scim_mappings(resource), fn
      %Multivalued{name: name} -> Atom.to_string(name) == attr_string
      _ -> false
    end)
  end

  defp relationship_inputs(value, %Multivalued{maps: maps}, op_kind, rel, path)
       when is_list(value) do
    inputs = Enum.map(value, &decode_relationship_element(&1, maps))

    if Enum.any?(inputs, &(&1 == :error)) do
      {:error, {:invalid_path, path}}
    else
      {:ok, %{attrs: %{}, relationships: [{op_kind, rel, inputs}]}}
    end
  end

  defp relationship_inputs(_value, _mv, _op_kind, _rel, path),
    do: {:error, {:invalid_path, path}}

  defp decode_relationship_element(element, maps) when is_map(element) do
    Enum.reduce(maps, %{}, fn
      %Map{attribute: nil}, acc ->
        acc

      %Map{name: name, attribute: attr}, acc ->
        case Elixir.Map.fetch(element, to_string(name)) do
          {:ok, value} -> Elixir.Map.put(acc, attr, value)
          :error -> acc
        end

      _, acc ->
        acc
    end)
  end

  defp decode_relationship_element(_element, _maps), do: :error

  defp value_for(:remove, _), do: nil
  defp value_for(_, value), do: unwrap_array(value)

  # When IdPs send `replace path: "name.givenName" value: ["Alice"]`, take the first.
  defp unwrap_array([single]), do: single
  defp unwrap_array(other), do: other

  defp lookup_parsed_path(%Path{attribute: attr, sub_attribute: nil}, resource) do
    do_lookup_or_error([attr], resource)
  end

  defp lookup_parsed_path(%Path{attribute: attr, sub_attribute: sub}, resource) do
    do_lookup_or_error([attr, sub], resource)
  end

  defp do_lookup_or_error(segments, resource) do
    mappings = AshScim.Info.scim_mappings(resource)

    case do_lookup(segments, mappings) do
      {:ok, attr} -> {:ok, attr}
      :error -> {:error, {:invalid_path, Enum.join(segments, ".")}}
    end
  end

  defp do_lookup([single], mappings) do
    Enum.find_value(mappings, :error, fn
      %Map{name: name, attribute: attr} when not is_nil(attr) ->
        if to_string(name) == single, do: {:ok, attr}, else: nil

      %Multivalued{name: name, maps: sub_maps} ->
        if to_string(name) == single, do: lookup_default_sub(sub_maps), else: nil

      _ ->
        nil
    end)
  end

  defp do_lookup([outer, inner], mappings) do
    Enum.find_value(mappings, :error, fn
      %Complex{name: name, maps: sub_maps} ->
        if to_string(name) == outer, do: do_lookup_sub([inner], sub_maps), else: nil

      %Multivalued{name: name, maps: sub_maps} ->
        if to_string(name) == outer, do: do_lookup_sub([inner], sub_maps), else: nil

      _ ->
        nil
    end)
  end

  defp do_lookup(_, _), do: :error

  defp do_lookup_sub([inner], sub_maps) do
    Enum.find_value(sub_maps, :error, fn
      %Map{name: name, attribute: attr} when not is_nil(attr) ->
        if to_string(name) == inner, do: {:ok, attr}, else: nil

      _ ->
        nil
    end)
  end

  defp lookup_default_sub(sub_maps) do
    Enum.find_value(sub_maps, :error, fn
      %Map{name: :value, attribute: attr} when not is_nil(attr) -> {:ok, attr}
      _ -> nil
    end)
    |> case do
      :error ->
        Enum.find_value(sub_maps, :error, fn
          %Map{attribute: attr} when not is_nil(attr) -> {:ok, attr}
          _ -> nil
        end)

      ok ->
        ok
    end
  end
end
