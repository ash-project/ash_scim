# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Encoder do
  @moduledoc """
  Encodes Ash records into SCIM 2.0 JSON-shaped maps using the mappings
  declared in the resource's `scim` section.

  The result is a plain map suitable for `Jason.encode!/1`. List-response
  envelopes are the responsibility of the router; this module concerns itself
  only with single-resource encoding.
  """

  alias AshScim.Dsl.{Complex, Map, Multivalued}

  @list_response_schema "urn:ietf:params:scim:api:messages:2.0:ListResponse"

  @type opts :: [base_url: String.t()]

  @doc """
  Encode a single Ash record as a SCIM resource.

  Options:

    * `:base_url` — used to build `meta.location`. If omitted, `meta.location`
      is not emitted.
  """
  @spec encode(Ash.Resource.record(), opts()) :: %{String.t() => term()}
  def encode(record, opts \\ []) when is_struct(record) do
    resource = record.__struct__

    mappings = AshScim.Info.scim_mappings(resource)
    schema = AshScim.Info.scim_schema!(resource)
    id = primary_key_string(record)

    base = %{
      "schemas" => [schema],
      "id" => id
    }

    body =
      Enum.reduce(mappings, base, fn mapping, acc ->
        case encode_mapping(mapping, record) do
          :skip -> acc
          {key, value} -> Elixir.Map.put(acc, key, value)
        end
      end)

    if AshScim.Info.scim_meta?(resource) do
      Elixir.Map.put(body, "meta", build_meta(record, id, opts))
    else
      body
    end
  end

  @doc """
  Wrap a list of encoded resources in a SCIM `ListResponse` envelope.

  `total_results` should reflect the unfiltered/unpaginated count when
  pagination is in play; for the simple case, pass `length(resources)`.
  """
  @spec list_response([%{String.t() => term()}], keyword()) :: %{String.t() => term()}
  def list_response(resources, opts \\ []) do
    total = Keyword.get(opts, :total_results, length(resources))
    start_index = Keyword.get(opts, :start_index, 1)
    items_per_page = Keyword.get(opts, :items_per_page, length(resources))

    %{
      "schemas" => [@list_response_schema],
      "totalResults" => total,
      "startIndex" => start_index,
      "itemsPerPage" => items_per_page,
      "Resources" => resources
    }
  end

  defp encode_mapping(%Map{value: value, name: name}, _record) when not is_nil(value) do
    {to_string(name), value}
  end

  defp encode_mapping(%Map{attribute: nil}, _record), do: :skip

  defp encode_mapping(%Map{name: name, attribute: attr}, record) do
    case fetch_attribute(record, attr) do
      :skip -> :skip
      {:ok, value} -> {to_string(name), value}
    end
  end

  defp encode_mapping(%Complex{name: name, maps: maps}, record) do
    inner =
      maps
      |> Enum.reduce(%{}, fn map, acc ->
        case encode_mapping(map, record) do
          :skip -> acc
          {k, v} -> Elixir.Map.put(acc, k, v)
        end
      end)

    if inner == %{} do
      :skip
    else
      {to_string(name), inner}
    end
  end

  defp encode_mapping(%Multivalued{relationship: rel, name: name, maps: maps}, record)
       when not is_nil(rel) do
    case load_relationship(record, rel) do
      {:ok, related_records} ->
        items =
          related_records
          |> Enum.map(&encode_related_element(&1, maps))
          |> Enum.reject(&(&1 == %{}))

        if items == [] do
          :skip
        else
          {to_string(name), items}
        end

      :error ->
        :skip
    end
  end

  # Mode B: no relationship, only `mirror_primary_to:`. Emit a single-
  # element array using the parent's mirror attribute as `value` and any
  # static `value:`-decorator sub-maps as the rest. Skip entirely if the
  # mirror attr is nil/empty so we don't emit `emails: [{value: nil}]`.
  defp encode_mapping(
         %Multivalued{
           relationship: nil,
           mirror_primary_to: mirror_attr,
           name: name,
           maps: maps
         },
         record
       )
       when not is_nil(mirror_attr) do
    case Elixir.Map.get(record, mirror_attr) do
      nil ->
        :skip

      "" ->
        :skip

      value ->
        decorators =
          maps
          |> Enum.filter(&match?(%Map{value: v} when not is_nil(v), &1))
          |> Enum.reduce(%{}, fn %Map{name: sub_name, value: v}, acc ->
            Elixir.Map.put(acc, to_string(sub_name), v)
          end)

        item = Elixir.Map.put(decorators, "value", scalarize(value))
        {to_string(name), [item]}
    end
  end

  defp load_relationship(record, rel) do
    case Elixir.Map.get(record, rel) do
      %Ash.NotLoaded{} ->
        case Ash.load(record, [rel]) do
          {:ok, loaded} -> {:ok, Elixir.Map.get(loaded, rel) || []}
          {:error, _} -> :error
        end

      nil ->
        {:ok, []}

      list when is_list(list) ->
        {:ok, list}

      _ ->
        :error
    end
  end

  defp encode_related_element(related_record, maps) do
    Enum.reduce(maps, %{}, fn map, acc ->
      case encode_mapping(map, related_record) do
        :skip -> acc
        {k, v} -> Elixir.Map.put(acc, k, v)
      end
    end)
  end

  defp fetch_attribute(record, attr) do
    case Elixir.Map.fetch(record, attr) do
      {:ok, nil} -> :skip
      {:ok, value} -> {:ok, scalarize(value)}
      :error -> :skip
    end
  end

  defp scalarize(%Ash.CiString{} = ci), do: to_string(ci)
  defp scalarize(value), do: value

  defp primary_key_string(record) do
    [pk | _] = Ash.Resource.Info.primary_key(record.__struct__)
    record |> Elixir.Map.fetch!(pk) |> to_string()
  end

  defp build_meta(record, id, opts) do
    resource = record.__struct__
    type = AshScim.Info.scim_type(record.__struct__) |> resource_type_string()
    path = AshScim.Info.scim_path!(resource)

    meta = %{"resourceType" => type}

    meta =
      case opts[:base_url] do
        nil -> meta
        base -> Elixir.Map.put(meta, "location", build_location(base, path, id))
      end

    meta
    |> maybe_put_timestamp("created", Elixir.Map.get(record, :inserted_at))
    |> maybe_put_timestamp("lastModified", Elixir.Map.get(record, :updated_at))
  end

  defp resource_type_string(:user), do: "User"
  defp resource_type_string(:group), do: "Group"

  defp build_location(base_url, path, id) do
    String.trim_trailing(base_url, "/") <> path <> "/" <> id
  end

  defp maybe_put_timestamp(meta, _key, nil), do: meta

  defp maybe_put_timestamp(meta, key, %DateTime{} = dt),
    do: Elixir.Map.put(meta, key, DateTime.to_iso8601(dt))

  defp maybe_put_timestamp(meta, key, %NaiveDateTime{} = ndt),
    do: Elixir.Map.put(meta, key, NaiveDateTime.to_iso8601(ndt))

  defp maybe_put_timestamp(meta, _, _), do: meta
end
