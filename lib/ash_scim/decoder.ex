# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Decoder do
  @moduledoc """
  Decodes inbound SCIM 2.0 JSON payloads into Ash action input.

  The decoded result has two parts:

    * `:attrs` — a flat `%{atom => value}` map suitable for
      `Ash.Changeset.for_create/3` or `for_update/3`.
    * `:relationships` — a `%{atom => [%{atom => value}]}` map of
      relationship-management input for relationship-backed multivalued
      attributes (full-replace semantics for top-level body inclusion).

  Per RFC 7644 §3.1, unknown attributes are silently dropped. Emit-only
  static-value mappings are skipped on the way in.

  When a multivalued attribute is *not* relationship-backed, the decoder
  collapses the array to a single element by picking the entry marked
  `primary: true` if one exists, falling back to the first entry otherwise.
  """

  require Logger

  alias AshScim.Dsl.{Complex, Map, Multivalued}

  @type decoded :: %{
          attrs: %{atom() => term()},
          relationships: %{atom() => [%{atom() => term()}]}
        }

  @doc """
  Decode a SCIM resource JSON map into structured Ash action input.
  """
  @spec decode(module(), %{String.t() => term()}) :: decoded()
  def decode(resource, %{} = body) do
    resource
    |> AshScim.Info.scim_mappings()
    |> Enum.reduce(%{attrs: %{}, relationships: %{}}, fn mapping, acc ->
      apply_mapping(mapping, body, acc)
    end)
  end

  defp apply_mapping(%Map{} = m, body, acc) do
    case decode_simple_map(m, body) do
      addition when addition == %{} -> acc
      addition -> %{acc | attrs: Elixir.Map.merge(acc.attrs, addition)}
    end
  end

  defp apply_mapping(%Complex{name: name, maps: maps}, body, acc) do
    case Elixir.Map.fetch(body, to_string(name)) do
      {:ok, %{} = inner} ->
        addition =
          Enum.reduce(maps, %{}, fn sub_map, sub_acc ->
            sub_map |> decode_simple_map(inner) |> merge_attrs(sub_acc)
          end)

        %{acc | attrs: Elixir.Map.merge(acc.attrs, addition)}

      _ ->
        acc
    end
  end

  defp apply_mapping(%Multivalued{relationship: rel, maps: maps} = mv, body, acc)
       when is_atom(rel) and not is_nil(rel) do
    case Elixir.Map.fetch(body, to_string(mv.name)) do
      {:ok, list} when is_list(list) ->
        rel_inputs =
          list
          |> Enum.filter(&is_map/1)
          |> Enum.map(&decode_relationship_element(&1, maps))
          |> Enum.reject(&(&1 == %{}))

        if rel_inputs == [] do
          acc
        else
          %{acc | relationships: Elixir.Map.put(acc.relationships, rel, rel_inputs)}
        end

      _ ->
        acc
    end
  end

  defp apply_mapping(%Multivalued{name: name, maps: maps}, body, acc) do
    case Elixir.Map.fetch(body, to_string(name)) do
      {:ok, list} when is_list(list) ->
        case pick_primary_element(list) do
          %{} = chosen ->
            warn_if_lossy(name, list, chosen)

            addition =
              Enum.reduce(maps, %{}, fn sub_map, sub_acc ->
                sub_map |> decode_simple_map(chosen) |> merge_attrs(sub_acc)
              end)

            %{acc | attrs: Elixir.Map.merge(acc.attrs, addition)}

          _ ->
            acc
        end

      _ ->
        acc
    end
  end

  defp decode_simple_map(%Map{attribute: nil}, _body), do: %{}

  defp decode_simple_map(%Map{name: name, attribute: attr}, body) do
    case Elixir.Map.fetch(body, to_string(name)) do
      {:ok, value} -> %{attr => value}
      :error -> %{}
    end
  end

  defp decode_relationship_element(element, maps) do
    Enum.reduce(maps, %{}, fn sub_map, acc ->
      sub_map |> decode_simple_map(element) |> merge_attrs(acc)
    end)
  end

  defp merge_attrs(addition, acc) when addition == %{}, do: acc
  defp merge_attrs(addition, acc), do: Elixir.Map.merge(acc, addition)

  defp warn_if_lossy(name, list, chosen) do
    objects = Enum.filter(list, &is_map/1)

    if length(objects) > 1 do
      dropped = Enum.reject(objects, &(&1 == chosen))

      Logger.warning(fn ->
        "[AshScim.Decoder] single-attribute multivalued :#{name} received " <>
          "#{length(objects)} entries; kept #{inspect(chosen)} and dropped " <>
          "#{inspect(dropped)}. To preserve all entries, declare the multivalued " <>
          "with `relationship:` so each entry maps to a separate row."
      end)
    end
  end

  defp pick_primary_element(list) do
    case Enum.find(list, &(is_map(&1) and Elixir.Map.get(&1, "primary") == true)) do
      nil ->
        case Enum.find(list, &is_map/1) do
          nil -> nil
          element -> element
        end

      element ->
        element
    end
  end
end
