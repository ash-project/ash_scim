# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Projection do
  @moduledoc """
  Applies the SCIM `attributes` / `excludedAttributes` query parameters to an
  encoded resource map (RFC 7644 §3.4.2.5).

  * `attributes=a,b,c` — only the named attributes are returned, plus the
    always-required `id`, `schemas`, and `meta`.
  * `excludedAttributes=a,b,c` — the named attributes are stripped, but
    `id`, `schemas`, and `meta` always come through.

  Dotted paths address sub-attributes of complex objects, e.g.
  `attributes=name.givenName` returns only `name: {givenName: ...}`.
  """

  @always_returned ~w(id schemas meta)

  @doc """
  Project an encoded SCIM resource map according to the request's selection
  query params.

  Pass the parsed query-param map (as `Plug.Conn.fetch_query_params/1` would
  produce) so that empty/missing values become a no-op.
  """
  @spec apply(%{String.t() => term()}, %{String.t() => term()}) :: %{String.t() => term()}
  def apply(resource, query_params) when is_map(resource) and is_map(query_params) do
    cond do
      paths = parse_list(query_params["attributes"]) ->
        keep_only(resource, paths)

      paths = parse_list(query_params["excludedAttributes"]) ->
        remove(resource, paths)

      true ->
        resource
    end
  end

  defp parse_list(nil), do: nil
  defp parse_list(""), do: nil

  defp parse_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      list -> list
    end
  end

  defp keep_only(resource, paths) do
    top_level_keep =
      paths
      |> Enum.map(&hd(String.split(&1, ".")))
      |> MapSet.new()
      |> MapSet.union(MapSet.new(@always_returned))

    resource
    |> Map.take(MapSet.to_list(top_level_keep))
    |> apply_complex_filters(paths)
  end

  defp apply_complex_filters(resource, paths) do
    Enum.reduce(paths, resource, fn path, acc ->
      case String.split(path, ".") do
        [_top] ->
          acc

        [top, sub | _] ->
          case Map.get(acc, top) do
            inner when is_map(inner) ->
              kept = Map.take(inner, [sub])
              if map_size(kept) == 0, do: acc, else: Map.put(acc, top, kept)

            _ ->
              acc
          end
      end
    end)
  end

  defp remove(resource, paths) do
    Enum.reduce(paths, resource, fn path, acc ->
      case String.split(path, ".") do
        [top] when top in @always_returned ->
          acc

        [top] ->
          Map.delete(acc, top)

        [top, sub | _] ->
          case Map.get(acc, top) do
            inner when is_map(inner) -> Map.put(acc, top, Map.delete(inner, sub))
            _ -> acc
          end
      end
    end)
  end
end
