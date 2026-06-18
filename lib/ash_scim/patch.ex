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
    * `add path: "emails" value: [...]` — append-style relationship op.
    * `replace path: "emails" value: [...]` — full-replace relationship op.
    * `remove path: "emails[value eq \"x\"]"` — load-and-destroy op against
      the related resource matching the bracket filter.

  When the multivalued declares `mirror_primary_to:`, the patch result also
  carries a `:mirror_sync` post-op (or a synchronously-computed attr write
  for replace) that keeps the parent's mirrored scalar in sync with the
  primary entry's value.
  """

  alias AshScim.Decoder
  alias AshScim.Dsl.{Complex, Extension, Map, Multivalued}
  alias AshScim.Patch.Path

  @schema "urn:ietf:params:scim:api:messages:2.0:PatchOp"

  @type op :: :add | :remove | :replace
  @type rel_op ::
          {:append, atom(), [%{atom() => term()}]}
          | {:replace_all, atom(), [%{atom() => term()}]}
          | {:remove_where, atom(), %{atom() => term()}}
          | {:mirror_sync, atom(), atom(), atom()}

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
    if is_map(value) do
      decoded = Decoder.decode(resource, value)
      # Path-less ops only carry attribute changes for now.
      {:ok, %{attrs: decoded.attrs, relationships: []}}
    else
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

  # Extension-scoped paths (e.g. `urn:…:enterprise:2.0:User:manager.value`).
  defp apply_parsed_op(op, %Path{extension: urn} = parsed, value, resource, path)
       when is_binary(urn) do
    apply_extension_op(op, find_extension(urn, resource), parsed, value, path)
  end

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
        # `remove path: "emails"` with no filter clears the relationship.
        # If `mirror_primary_to:` is set, also nil the mirror attr unless
        # it's `allow_nil?: false` — in that case we leave it alone but
        # still report success, since SCIM doesn't model "this scalar is
        # required because it's also the user's identity column".
        attrs = mirror_clear_attrs(multivalued, resource)
        {:ok, %{attrs: attrs, relationships: [{:replace_all, rel, []}]}}

      {:remove, %{} = filter, nil} ->
        ops = [{:remove_where, rel, filter} | mirror_sync_ops(multivalued)]
        {:ok, %{attrs: %{}, relationships: ops}}

      _ ->
        {:error, {:invalid_path, path}}
    end
  end

  # Bare path that resolves to a Complex — `add path: "name" value: {givenName: ...}`.
  defp apply_parsed_op(
         op,
         %Path{attribute: attr_str, sub_attribute: nil, filter: nil} = parsed,
         value,
         resource,
         path
       ) do
    cond do
      complex = find_complex(attr_str, resource) ->
        apply_complex_op(op, complex, value)

      mv = find_mirror_only_multivalued(attr_str, resource) ->
        apply_mirror_only_op(op, mv, value, resource)

      true ->
        apply_simple_op(op, parsed, value, resource, path)
    end
  end

  # Scalar attribute path.
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

  defp find_extension(urn, resource) do
    Enum.find(AshScim.Info.scim_mappings(resource), fn
      %Extension{urn: u} -> u == urn
      _ -> false
    end)
  end

  defp apply_extension_op(_op, nil, _parsed, _value, path), do: {:error, {:invalid_path, path}}

  # `<urn>:manager` — the attribute is a complex within the extension.
  defp apply_extension_op(
         op,
         %Extension{} = ext,
         %Path{attribute: attr, sub_attribute: nil},
         value,
         path
       ) do
    map =
      Enum.find(ext.maps, fn m ->
        match?(%Map{attribute: a} when not is_nil(a), m) and Atom.to_string(m.name) == attr
      end)

    cond do
      complex = Enum.find(ext.complexes, &(Atom.to_string(&1.name) == attr)) ->
        apply_complex_op(op, complex, value)

      map ->
        {:ok, %{attrs: %{map.attribute => value_for(op, value)}, relationships: []}}

      true ->
        {:error, {:invalid_path, path}}
    end
  end

  # `<urn>:manager.value` — a sub-attribute of a complex within the extension.
  defp apply_extension_op(
         op,
         %Extension{} = ext,
         %Path{attribute: attr, sub_attribute: sub},
         value,
         path
       ) do
    with %Complex{maps: maps} <- Enum.find(ext.complexes, &(Atom.to_string(&1.name) == attr)),
         %Map{attribute: attribute} when not is_nil(attribute) <-
           Enum.find(maps, &(Atom.to_string(&1.name) == sub)) do
      {:ok, %{attrs: %{attribute => value_for(op, value)}, relationships: []}}
    else
      _ -> {:error, {:invalid_path, path}}
    end
  end

  defp find_multivalued(attr_string, resource) do
    Enum.find(AshScim.Info.scim_mappings(resource), fn
      %Multivalued{name: name} -> Atom.to_string(name) == attr_string
      _ -> false
    end)
  end

  defp find_mirror_only_multivalued(attr_string, resource) do
    Enum.find(AshScim.Info.scim_mappings(resource), fn
      %Multivalued{name: name, relationship: nil, mirror_primary_to: m}
      when not is_nil(m) ->
        Atom.to_string(name) == attr_string

      _ ->
        false
    end)
  end

  # Mode B (no relationship, mirror_primary_to only): writes funnel through
  # the parent's mirror attribute. Picks primary from the value list, sets
  # `attrs[mirror_primary_to] = primary.value`.
  defp apply_mirror_only_op(:remove, %Multivalued{} = mv, _value, resource) do
    {:ok, %{attrs: mirror_clear_attrs(mv, resource), relationships: []}}
  end

  defp apply_mirror_only_op(_op, %Multivalued{mirror_primary_to: mirror_attr}, value, _resource)
       when is_list(value) do
    objects = Enum.filter(value, &is_map/1)

    case Decoder.pick_primary(objects) do
      nil ->
        {:ok, %{attrs: %{}, relationships: []}}

      chosen ->
        case Elixir.Map.fetch(chosen, "value") do
          {:ok, v} -> {:ok, %{attrs: %{mirror_attr => v}, relationships: []}}
          :error -> {:ok, %{attrs: %{}, relationships: []}}
        end
    end
  end

  # Some IdPs send a scalar instead of an array — `replace path: "emails"
  # value: "alice@example.com"`. Treat that as a direct write to the
  # mirror attr.
  defp apply_mirror_only_op(_op, %Multivalued{mirror_primary_to: mirror_attr}, value, _resource)
       when not is_list(value) do
    {:ok, %{attrs: %{mirror_attr => value}, relationships: []}}
  end

  defp relationship_inputs(value, %Multivalued{maps: maps} = mv, op_kind, rel, path)
       when is_list(value) do
    inputs = Enum.map(value, &decode_relationship_element(&1, maps))

    if Enum.any?(inputs, &(&1 == :error)) do
      {:error, {:invalid_path, path}}
    else
      {:ok, build_relationship_result(mv, op_kind, rel, inputs, value)}
    end
  end

  defp relationship_inputs(_value, _mv, _op_kind, _rel, path),
    do: {:error, {:invalid_path, path}}

  # `replace_all` with a non-empty list: we know the new primary
  # synchronously, so write the mirror attr inline. Empty replace clears
  # the relationship; mirror is left alone (parent's identity column can't
  # be nilled).
  defp build_relationship_result(
         %Multivalued{mirror_primary_to: mirror_attr, maps: maps},
         :replace_all,
         rel,
         inputs,
         raw
       )
       when not is_nil(mirror_attr) and inputs != [] do
    case mirror_attr_for(mirror_attr, maps, raw) do
      {:ok, attr_map} ->
        %{attrs: attr_map, relationships: [{:replace_all, rel, inputs}]}

      :none ->
        %{attrs: %{}, relationships: [{:replace_all, rel, inputs}]}
    end
  end

  defp build_relationship_result(
         %Multivalued{mirror_primary_to: mirror_attr} = mv,
         op_kind,
         rel,
         inputs,
         _raw
       )
       when not is_nil(mirror_attr) and op_kind == :append do
    %{attrs: %{}, relationships: [{op_kind, rel, inputs} | mirror_sync_ops(mv)]}
  end

  defp build_relationship_result(_mv, op_kind, rel, inputs, _raw) do
    %{attrs: %{}, relationships: [{op_kind, rel, inputs}]}
  end

  # Pick primary from raw SCIM input list, then map its `value` SCIM
  # sub-attribute to the parent's mirror attribute.
  defp mirror_attr_for(mirror_attr, maps, raw_list) do
    objects = Enum.filter(raw_list, &is_map/1)

    case Decoder.pick_primary(objects) do
      nil ->
        :none

      chosen ->
        case Elixir.Map.fetch(chosen, "value") do
          {:ok, value} ->
            _ = maps
            {:ok, %{mirror_attr => value}}

          :error ->
            :none
        end
    end
  end

  defp mirror_sync_ops(%Multivalued{mirror_primary_to: nil}), do: []

  defp mirror_sync_ops(%Multivalued{
         relationship: rel,
         mirror_primary_to: mirror_attr,
         maps: maps
       }) do
    case Enum.find(maps, &match?(%Map{name: :value, attribute: a} when not is_nil(a), &1)) do
      %Map{attribute: value_attr} -> [{:mirror_sync, rel, mirror_attr, value_attr}]
      _ -> []
    end
  end

  defp mirror_clear_attrs(nil, _resource), do: %{}
  defp mirror_clear_attrs(%Multivalued{mirror_primary_to: nil}, _resource), do: %{}

  defp mirror_clear_attrs(%Multivalued{mirror_primary_to: attr}, resource) do
    case Ash.Resource.Info.attribute(resource, attr) do
      %{allow_nil?: true} -> %{attr => nil}
      _ -> %{}
    end
  end

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
end
