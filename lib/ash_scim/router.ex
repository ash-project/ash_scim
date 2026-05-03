# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Router do
  @moduledoc """
  A `Plug` that exposes Ash resources as a SCIM 2.0 server.

  ## Quick start

  Either plug it directly into a pipeline:

      plug AshScim.Router,
        domains: [MyApp.Accounts],
        auth: {AshScim.Auth.StaticBearer, tokens: ["dev-secret"]}

  Or wrap it in your own module so config lives next to your app:

      defmodule MyApp.Scim do
        use AshScim.Router,
          domains: [MyApp.Accounts],
          auth: {AshScim.Auth.StaticBearer, tokens: {:env, "SCIM_TOKEN"}}
      end

      # in your endpoint/router
      forward "/scim/v2", MyApp.Scim

  ## Options

    * `:domains` — list of Ash domains to scan for resources carrying the
      `AshScim.User` or `AshScim.Group` extensions.
    * `:resources` — alternative to `:domains` if you want to enumerate
      resources explicitly.
    * `:auth` — `{module, opts}` implementing `AshScim.Auth`.
    * `:base_url` — used to populate `meta.location` in encoded resources.
      If omitted, `meta.location` is not emitted.

  ## Endpoints

    * `GET    /<type>` — list (supports `?filter=…` and `?count=…&startIndex=…`)
    * `GET    /<type>/:id`
    * `POST   /<type>`
    * `PUT    /<type>/:id` — full replace
    * `DELETE /<type>/:id`
    * `GET    /ServiceProviderConfig`

  `<type>` is the configured `path` from each resource's `scim` section
  (defaults: `Users`, `Groups`).

  PATCH support and the `/Schemas` & `/ResourceTypes` discovery endpoints
  are forthcoming.
  """

  @behaviour Plug

  alias AshScim.{Decoder, Discovery, Encoder, Error, Filter, Patch, Projection}

  @scim_content_type "application/scim+json"
  @scim_context %{private: %{ash_scim?: true}}

  # Tag every Ash query/changeset the router builds with a private context
  # flag. `AshScim.Checks.AshScimInteraction` matches on this flag, so users
  # can add `bypass AshScim.Checks.AshScimInteraction` to their resource
  # policies to keep router-internal Ash calls from hitting user-facing
  # authorisation.
  defp scim_query(query), do: Ash.Query.set_context(query, @scim_context)
  defp scim_changeset(cs), do: Ash.Changeset.set_context(cs, @scim_context)

  defp scim_opts(opts \\ []), do: Keyword.put(opts, :context, @scim_context)

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Plug

      @ash_scim_router_opts opts

      @impl Plug
      def init(extra), do: AshScim.Router.init(Keyword.merge(@ash_scim_router_opts, extra))

      @impl Plug
      def call(conn, opts), do: AshScim.Router.call(conn, opts)
    end
  end

  @impl Plug
  def init(opts) do
    auth = Keyword.fetch!(opts, :auth)
    base_url = Keyword.get(opts, :base_url)
    resources = collect_resources(opts)

    routing_table =
      Enum.reduce(resources, %{}, fn resource, acc ->
        path = resource |> AshScim.Info.scim_path!() |> String.trim_leading("/")

        if Elixir.Map.has_key?(acc, path) do
          raise ArgumentError,
                "two resources are configured at SCIM path /#{path}: " <>
                  "#{inspect(acc[path])} and #{inspect(resource)}"
        end

        Elixir.Map.put(acc, path, resource)
      end)

    %{
      auth: auth,
      base_url: base_url,
      routing_table: routing_table
    }
  end

  @impl Plug
  def call(conn, %{auth: {auth_mod, auth_opts}} = opts) do
    case auth_mod.authenticate(conn, auth_opts) do
      {:ok, conn, actor} ->
        conn |> put_actor(actor) |> dispatch(opts)

      {:error, reason} ->
        send_error(conn, 401, reason)
    end
  end

  defp put_actor(conn, actor), do: Plug.Conn.assign(conn, :ash_scim_actor, actor)

  # ───────────────────────────── dispatch ───────────────────────────── #

  defp dispatch(%Plug.Conn{method: "GET", path_info: ["ServiceProviderConfig"]} = conn, _opts) do
    send_json(conn, 200, service_provider_config())
  end

  defp dispatch(%Plug.Conn{method: "POST", path_info: [".search"]} = conn, opts) do
    cross_resource_search(conn, opts)
  end

  defp dispatch(%Plug.Conn{method: "GET", path_info: ["Schemas"]} = conn, opts) do
    send_json(conn, 200, Discovery.schemas(resources(opts)))
  end

  defp dispatch(%Plug.Conn{method: "GET", path_info: ["Schemas", id]} = conn, opts) do
    case Enum.find(resources(opts), &(AshScim.Info.scim_schema!(&1) == id)) do
      nil -> send_error(conn, 404, "no schema with id `#{id}`")
      resource -> send_json(conn, 200, Discovery.schema(resource))
    end
  end

  defp dispatch(%Plug.Conn{method: "GET", path_info: ["ResourceTypes"]} = conn, opts) do
    send_json(conn, 200, Discovery.resource_types(resources(opts)))
  end

  defp dispatch(%Plug.Conn{method: "GET", path_info: ["ResourceTypes", name]} = conn, opts) do
    case Enum.find(resources(opts), &(resource_type_name(&1) == name)) do
      nil -> send_error(conn, 404, "no resource type named `#{name}`")
      resource -> send_json(conn, 200, Discovery.resource_type(resource))
    end
  end

  defp dispatch(%Plug.Conn{method: method, path_info: [type | rest]} = conn, opts) do
    case Elixir.Map.fetch(opts.routing_table, type) do
      {:ok, resource} -> dispatch_resource(method, rest, resource, conn, opts)
      :error -> send_error(conn, 404, "no SCIM resource configured at /#{type}")
    end
  end

  defp dispatch(conn, _opts), do: send_error(conn, 404, "not found")

  defp resources(%{routing_table: table}), do: Elixir.Map.values(table)

  defp resource_type_name(resource) do
    case AshScim.Info.scim_type(resource) do
      :user -> "User"
      :group -> "Group"
      _ -> nil
    end
  end

  defp dispatch_resource("GET", [], resource, conn, opts), do: index(conn, resource, opts)
  defp dispatch_resource("GET", [id], resource, conn, opts), do: show(conn, resource, id, opts)

  defp dispatch_resource("POST", [".search"], resource, conn, opts),
    do: search(conn, resource, opts)

  defp dispatch_resource("POST", [], resource, conn, opts), do: create(conn, resource, opts)
  defp dispatch_resource("PUT", [id], resource, conn, opts), do: replace(conn, resource, id, opts)
  defp dispatch_resource("PATCH", [id], resource, conn, opts), do: patch(conn, resource, id, opts)

  defp dispatch_resource("DELETE", [id], resource, conn, opts),
    do: destroy(conn, resource, id, opts)

  defp dispatch_resource(_method, _rest, _resource, conn, _opts) do
    send_error(conn, 405, "method not allowed")
  end

  # ───────────────────────────── handlers ───────────────────────────── #

  # Top-level POST /.search: read each configured resource and merge into
  # a single ListResponse. We honour the body's `filter` per-resource —
  # filters that don't parse against a given resource (e.g. they reference
  # an attribute that resource doesn't have) skip that resource silently.
  defp cross_resource_search(conn, opts) do
    case read_json_body(conn) do
      {:ok, body, conn} ->
        actor = conn.assigns[:ash_scim_actor]
        filter_string = body["filter"]

        # Promote body-level projection params onto query_params so
        # `encode_and_project` honours them.
        projection_conn =
          %{
            conn
            | query_params:
                %{}
                |> maybe_put("attributes", join_csv(body["attributes"]))
                |> maybe_put("excludedAttributes", join_csv(body["excludedAttributes"]))
          }

        encoded =
          opts
          |> resources()
          |> Enum.flat_map(&search_resource(&1, filter_string, actor, projection_conn, opts))

        send_json(
          conn,
          200,
          Encoder.list_response(encoded, total_results: length(encoded))
        )

      {:halted, conn} ->
        conn
    end
  end

  defp search_resource(resource, filter_string, actor, conn, opts) do
    base = resource |> Ash.Query.for_read(read_action(resource)) |> scim_query()

    query =
      case filter_string do
        nil ->
          base

        "" ->
          base

        s when is_binary(s) ->
          case Filter.parse(s, resource) do
            {:ok, f} -> Ash.Query.filter_input(base, f)
            {:error, _} -> nil
          end
      end

    case query do
      nil ->
        []

      q ->
        case Ash.read(q, actor: actor) do
          {:ok, records} -> Enum.map(records, &encode_and_project(conn, &1, opts))
          {:error, _} -> []
        end
    end
  end

  defp search(conn, resource, opts) do
    case read_json_body(conn) do
      {:ok, body, conn} ->
        # Translate the SCIM SearchRequest body into query params and run the
        # same flow as GET <type>. Per RFC 7644 §3.4.3 the body keys mirror
        # the standard URL parameters one-for-one.
        query_params =
          %{}
          |> maybe_put("filter", body["filter"])
          |> maybe_put("count", body["count"])
          |> maybe_put("startIndex", body["startIndex"])
          |> maybe_put("sortBy", body["sortBy"])
          |> maybe_put("sortOrder", body["sortOrder"])
          |> maybe_put("attributes", join_csv(body["attributes"]))
          |> maybe_put("excludedAttributes", join_csv(body["excludedAttributes"]))

        index(%{conn | query_params: query_params, params: query_params}, resource, opts)

      {:halted, conn} ->
        conn
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, _k, ""), do: map
  defp maybe_put(map, k, v) when is_integer(v), do: Elixir.Map.put(map, k, Integer.to_string(v))
  defp maybe_put(map, k, v) when is_binary(v), do: Elixir.Map.put(map, k, v)
  defp maybe_put(map, _k, _v), do: map

  defp join_csv(list) when is_list(list), do: Enum.join(list, ",")
  defp join_csv(other), do: other

  defp index(conn, resource, opts) do
    conn = Plug.Conn.fetch_query_params(conn)
    actor = conn.assigns[:ash_scim_actor]

    with {:ok, query, page} <- build_index_query(conn, resource) do
      total =
        case Ash.count(query, actor: actor) do
          {:ok, count} -> count
          {:error, _} -> nil
        end

      paged_query = query |> Ash.Query.offset(page.offset) |> Ash.Query.limit(page.limit)

      case Ash.read(paged_query, actor: actor) do
        {:ok, records} ->
          encoded = Enum.map(records, &encode_and_project(conn, &1, opts))

          send_json(
            conn,
            200,
            Encoder.list_response(encoded,
              total_results: total || length(encoded),
              start_index: page.start_index,
              items_per_page: length(encoded)
            )
          )

        {:error, error} ->
          send_error(conn, 500, Exception.message(error))
      end
    else
      {:error, {:invalid_filter, reason}} ->
        send_error(conn, 400, "invalid filter: #{reason}", :invalidFilter)

      {:error, {:invalid_sort, reason}} ->
        send_error(conn, 400, "invalid sort: #{reason}", :invalidValue)

      {:error, {:invalid_pagination, reason}} ->
        send_error(conn, 400, "invalid pagination: #{reason}", :invalidValue)
    end
  end

  defp show(conn, resource, id, opts) do
    actor = conn.assigns[:ash_scim_actor]
    read_action = read_action(resource)

    case Ash.get(resource, id, scim_opts(action: read_action, actor: actor)) do
      {:ok, record} ->
        send_json(conn, 200, encode_and_project(conn, record, opts))

      {:error, error} ->
        send_get_error(conn, error)
    end
  end

  defp create(conn, resource, opts) do
    case read_json_body(conn) do
      {:ok, body, conn} ->
        decoded = Decoder.decode(resource, body)
        action = create_action(resource)
        actor = conn.assigns[:ash_scim_actor]

        resource
        |> Ash.Changeset.for_create(action, decoded.attrs)
        |> scim_changeset()
        |> apply_relationship_inputs(decoded.relationships)
        |> Ash.create(actor: actor)
        |> case do
          {:ok, record} ->
            reloaded = reload_for_relationships(record, decoded.relationships, actor)
            send_json(conn, 201, encode_and_project(conn, reloaded, opts))

          {:error, error} ->
            send_changeset_error(conn, error)
        end

      {:halted, conn} ->
        conn
    end
  end

  defp replace(conn, resource, id, opts) do
    case read_json_body(conn) do
      {:ok, body, conn} ->
        decoded = Decoder.decode(resource, body)
        actor = conn.assigns[:ash_scim_actor]

        case Ash.get(resource, id, scim_opts(actor: actor)) do
          {:ok, record} ->
            record
            |> Ash.Changeset.for_update(update_action(resource), decoded.attrs)
            |> scim_changeset()
            |> apply_relationship_inputs(decoded.relationships)
            |> Ash.update(actor: actor)
            |> case do
              {:ok, updated} ->
                reloaded = reload_for_relationships(updated, decoded.relationships, actor)
                send_json(conn, 200, encode_and_project(conn, reloaded, opts))

              {:error, error} ->
                send_changeset_error(conn, error)
            end

          {:error, error} ->
            send_get_error(conn, error)
        end

      {:halted, conn} ->
        conn
    end
  end

  defp patch(conn, resource, id, opts) do
    case read_json_body(conn) do
      {:ok, body, conn} ->
        actor = conn.assigns[:ash_scim_actor]

        case Patch.to_params(body, resource) do
          {:ok, %{attrs: attrs, relationships: rel_ops}} ->
            # Wrap the read + update + manage_relationship + remove_where
            # post-step in one transaction so a failure in any step rolls
            # back the rest. On data layers that support row-level locking,
            # also lock the parent record FOR UPDATE so concurrent SCIM
            # PATCHes against the same resource serialize cleanly.
            result =
              [resource]
              |> Ash.transact(fn ->
                apply_patch_in_transaction(resource, id, attrs, rel_ops, actor)
              end)
              |> normalise_transact_result()

            case result do
              {:ok, updated} ->
                send_json(conn, 200, encode_and_project(conn, updated, opts))

              {:error, error} ->
                send_patch_error(conn, error)
            end

          {:error, {:invalid_path, path}} ->
            send_error(conn, 400, "invalid PATCH path: `#{path}`", :invalidPath)

          {:error, reason} when is_binary(reason) ->
            send_error(conn, 400, reason, :invalidSyntax)

          {:error, reason} ->
            send_error(conn, 400, inspect(reason), :invalidSyntax)
        end

      {:halted, conn} ->
        conn
    end
  end

  # Inner function runs inside `Ash.transact`; that wrapper already wraps the
  # return value in `{:ok, ...}` and rolls back on `{:error, _}`. So we
  # return the record directly on success, and `{:error, _}` to abort.
  defp apply_patch_in_transaction(resource, id, attrs, rel_ops, actor) do
    case fetch_for_patch(resource, id, actor) do
      {:ok, record} ->
        {manage_ops, post_update_ops} = split_relationship_ops(rel_ops)

        record
        |> Ash.Changeset.for_update(update_action(resource), attrs)
        |> scim_changeset()
        |> apply_manage_ops(manage_ops)
        |> Ash.update(actor: actor)
        |> case do
          {:ok, updated} ->
            case apply_post_update_ops(updated, post_update_ops, actor) do
              :ok -> reload_for_response(updated, manage_ops ++ post_update_ops, actor)
              {:error, _} = err -> err
            end

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  # Fetch the parent record for PATCH application. Adds a `FOR UPDATE` row
  # lock when the data layer supports it so concurrent PATCHes serialize.
  # On data layers without lock support (e.g. ETS), this is a normal read.
  defp fetch_for_patch(resource, id, actor) do
    [pk | _] = Ash.Resource.Info.primary_key(resource)

    query =
      resource
      |> Ash.Query.new()
      |> Ash.Query.filter_input(%{pk => %{eq: id}})
      |> maybe_lock_for_update(resource)
      |> scim_query()

    Ash.read_one(query, scim_opts(actor: actor, not_found_error?: true))
  end

  defp maybe_lock_for_update(query, resource) do
    if Ash.DataLayer.data_layer_can?(resource, {:lock, :for_update}) do
      Ash.Query.lock(query, :for_update)
    else
      query
    end
  end

  # `Ash.transact` returns `{:ok, fn_result}` for both success and failure
  # when the data layer doesn't support transactions (e.g. ETS) — i.e., an
  # `{:error, _}` from the inner function comes back as `{:ok, {:error, _}}`.
  # On data layers that do transact (Postgres), errors come back as
  # `{:error, _}` directly. Normalise both to `{:ok, value} | {:error, _}`.
  defp normalise_transact_result({:ok, {:error, _} = err}), do: err
  defp normalise_transact_result(other), do: other

  # PATCH errors come from any of the steps inside the transaction. Map them
  # to the right SCIM error envelope.
  defp send_patch_error(conn, error) do
    cond do
      not_found_error?(error) ->
        send_error(conn, 404, "resource not found")

      match?(%Ash.Error.Invalid{}, error) ->
        send_changeset_error(conn, error)

      true ->
        send_changeset_error(conn, error)
    end
  end

  # Relationship ops fall into two buckets: those that can be expressed via
  # Ash.Changeset.manage_relationship (append, replace_all) and run inside
  # the same update transaction; and those that need a separate
  # load+bulk_destroy step after the main update (remove_where).
  defp split_relationship_ops(rel_ops) do
    Enum.split_with(rel_ops, fn
      {:append, _, _} -> true
      {:replace_all, _, _} -> true
      _ -> false
    end)
  end

  defp apply_manage_ops(changeset, ops) do
    Enum.reduce(ops, changeset, fn
      {:append, rel, inputs}, cs ->
        Ash.Changeset.manage_relationship(cs, rel, inputs, append_options())

      {:replace_all, rel, inputs}, cs ->
        Ash.Changeset.manage_relationship(cs, rel, inputs, full_replace_options())
    end)
  end

  defp apply_post_update_ops(_record, [], _actor), do: :ok

  defp apply_post_update_ops(record, ops, actor) do
    Enum.reduce_while(ops, :ok, fn
      {:remove_where, rel, filter}, _acc ->
        case do_remove_where(record, rel, filter, actor) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
    end)
  end

  # Two strategies for `:remove_where`:
  #
  # 1. **Direct query destroy** — when the relationship is a plain `has_many`
  #    with no relationship-level filter and no `through:`, we can scope the
  #    destroy by the foreign key directly: build one query against the
  #    related resource (`destination_attribute == parent_pk and <user filter>`)
  #    and `Ash.bulk_destroy(query, …)` it. Single round trip.
  #
  # 2. **Load then destroy** — for any other relationship shape (relationship
  #    filter, many_to_many, etc.), fall back to loading through the
  #    relationship and destroying the loaded records, since that path
  #    correctly applies the relationship's own scoping rules.
  defp do_remove_where(record, rel, filter, actor) do
    rel_def = Ash.Resource.Info.relationship(record.__struct__, rel)

    if simple_has_many?(rel_def) do
      direct_remove_where(record, rel_def, filter, actor)
    else
      load_then_remove(record, rel, filter, actor)
    end
  end

  defp simple_has_many?(%{type: :has_many, filter: nil, through: nil}), do: true
  defp simple_has_many?(_), do: false

  defp direct_remove_where(record, rel_def, user_filter, actor) do
    parent_value = Elixir.Map.fetch!(record, rel_def.source_attribute)

    combined_filter = %{
      and: [
        user_filter,
        %{rel_def.destination_attribute => %{eq: parent_value}}
      ]
    }

    query =
      rel_def.destination
      |> Ash.Query.filter_input(combined_filter)
      |> scim_query()

    bulk_destroy_query(query, actor)
  end

  defp load_then_remove(record, rel, filter, actor) do
    related_resource = related_resource_for(record, rel)

    rel_query =
      related_resource |> Ash.Query.filter_input(filter) |> scim_query()

    case Ash.load(record, [{rel, rel_query}], scim_opts(actor: actor)) do
      {:ok, loaded} ->
        matches = Elixir.Map.get(loaded, rel) || []

        if matches == [] do
          :ok
        else
          bulk_destroy_records(matches, actor)
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp bulk_destroy_query(query, actor) do
    handle_bulk_result(
      Ash.bulk_destroy(
        query,
        :destroy,
        %{},
        scim_opts(
          return_errors?: true,
          actor: actor,
          strategy: :atomic_batches
        )
      )
    )
  end

  defp bulk_destroy_records(records, actor) do
    handle_bulk_result(
      Ash.bulk_destroy(
        records,
        :destroy,
        %{},
        scim_opts(
          return_errors?: true,
          actor: actor,
          strategy: :atomic_batches
        )
      )
    )
  end

  defp handle_bulk_result(%Ash.BulkResult{status: :success}), do: :ok

  defp handle_bulk_result(%Ash.BulkResult{errors: errors}),
    do: {:error, List.first(errors) || "bulk destroy failed"}

  defp related_resource_for(%resource{}, rel) do
    Ash.Resource.Info.related(resource, [rel])
  end

  defp reload_for_relationships(record, relationships, _actor) when relationships == %{},
    do: record

  defp reload_for_relationships(record, relationships, actor) do
    rels = Elixir.Map.keys(relationships)

    case Ash.load(record, rels, scim_opts(actor: actor)) do
      {:ok, reloaded} -> reloaded
      _ -> record
    end
  end

  defp reload_for_response(record, ops, actor) do
    rels = ops |> Enum.map(fn {_, rel, _} -> rel end) |> Enum.uniq()

    if rels == [] do
      record
    else
      case Ash.load(record, rels, scim_opts(actor: actor)) do
        {:ok, reloaded} -> reloaded
        _ -> record
      end
    end
  end

  defp destroy(conn, resource, id, _opts) do
    actor = conn.assigns[:ash_scim_actor]

    case Ash.get(resource, id, scim_opts(actor: actor)) do
      {:ok, record} ->
        record
        |> Ash.Changeset.for_destroy(destroy_action(resource))
        |> scim_changeset()
        |> Ash.destroy(actor: actor)
        |> normalise_destroy()
        |> case do
          :ok ->
            conn
            |> Plug.Conn.put_resp_content_type(@scim_content_type)
            |> Plug.Conn.send_resp(204, "")

          {:error, error} ->
            send_changeset_error(conn, error)
        end

      {:error, error} ->
        send_get_error(conn, error)
    end
  end

  defp send_get_error(conn, error) do
    if not_found_error?(error) do
      send_error(conn, 404, "resource not found")
    else
      send_error(conn, 500, Exception.message(error))
    end
  end

  defp not_found_error?(%Ash.Error.Query.NotFound{}), do: true
  defp not_found_error?(%Ash.Error.Invalid{errors: errors}), do: Enum.any?(errors, &not_found_error?/1)
  defp not_found_error?(_), do: false

  defp normalise_destroy(:ok), do: :ok
  defp normalise_destroy({:ok, _}), do: :ok
  defp normalise_destroy({:error, _} = err), do: err

  # ───────────────────────────── query building ───────────────────────────── #

  defp build_index_query(conn, resource) do
    base = resource |> Ash.Query.for_read(read_action(resource)) |> scim_query()

    with {:ok, filtered} <- apply_filter(base, conn, resource),
         {:ok, sorted} <- apply_sort(filtered, conn, resource),
         {:ok, page} <- pagination(conn) do
      {:ok, sorted, page}
    end
  end

  defp apply_filter(query, conn, resource) do
    case Elixir.Map.get(conn.query_params, "filter") do
      nil ->
        {:ok, query}

      "" ->
        {:ok, query}

      filter_string ->
        case Filter.parse(filter_string, resource) do
          {:ok, filter} -> {:ok, Ash.Query.filter_input(query, filter)}
          {:error, reason} -> {:error, {:invalid_filter, format_filter_error(reason)}}
        end
    end
  end

  defp apply_sort(query, conn, resource) do
    case Elixir.Map.get(conn.query_params, "sortBy") do
      nil ->
        {:ok, query}

      "" ->
        {:ok, query}

      sort_by ->
        order = sort_order(Elixir.Map.get(conn.query_params, "sortOrder"))

        case Filter.parse("#{sort_by} pr", resource) do
          {:ok, %{} = filter} ->
            [{attr, _}] = Elixir.Map.to_list(filter)
            {:ok, Ash.Query.sort(query, [{attr, order}])}

          {:error, reason} ->
            {:error, {:invalid_sort, format_filter_error(reason)}}
        end
    end
  end

  defp sort_order("descending"), do: :desc
  defp sort_order("desc"), do: :desc
  defp sort_order(_), do: :asc

  defp pagination(conn) do
    with {:ok, count} <- parse_int(conn, "count", 100, 1, 1000),
         {:ok, start_index} <- parse_int(conn, "startIndex", 1, 1, :infinity) do
      {:ok, %{start_index: start_index, offset: start_index - 1, limit: count}}
    end
  end

  defp parse_int(conn, name, default, min, max) do
    case Elixir.Map.get(conn.query_params, name) do
      nil ->
        {:ok, default}

      value ->
        case Integer.parse(value) do
          {int, ""} when int >= min and (max == :infinity or int <= max) ->
            {:ok, int}

          _ ->
            {:error, {:invalid_pagination, "`#{name}` must be a positive integer"}}
        end
    end
  end

  defp format_filter_error({:unknown_attribute, path}),
    do: "unknown attribute `#{Enum.join(path, ".")}`"

  defp format_filter_error(other) when is_binary(other), do: other
  defp format_filter_error(other), do: inspect(other)

  # ───────────────────────────── action lookup ───────────────────────────── #

  defp read_action(resource),
    do: AshScim.Info.scim_read_action(resource) |> primary_fallback(resource, :read)

  defp create_action(resource),
    do: AshScim.Info.scim_create_action(resource) |> primary_fallback(resource, :create)

  defp update_action(resource),
    do: AshScim.Info.scim_update_action(resource) |> primary_fallback(resource, :update)

  defp destroy_action(resource),
    do: AshScim.Info.scim_destroy_action(resource) |> primary_fallback(resource, :destroy)

  defp primary_fallback({:ok, name}, _resource, _kind) when not is_nil(name), do: name

  defp primary_fallback(_, resource, kind) do
    case Ash.Resource.Info.primary_action(resource, kind) do
      %{name: name} ->
        name

      nil ->
        raise ArgumentError,
              "resource #{inspect(resource)} has no primary `#{kind}` action and the " <>
                "`scim` section did not configure `#{kind}_action`."
    end
  end

  # ───────────────────────────── resource discovery ───────────────────────────── #

  defp collect_resources(opts) do
    explicit = Keyword.get(opts, :resources, [])

    from_domains =
      opts
      |> Keyword.get(:domains, [])
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)

    (explicit ++ from_domains)
    |> Enum.uniq()
    |> Enum.filter(&AshScim.Info.scim_resource?/1)
  end

  # ───────────────────────────── service provider config ───────────────────────────── #

  defp service_provider_config do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"],
      "patch" => %{"supported" => true},
      "bulk" => %{"supported" => false, "maxOperations" => 0, "maxPayloadSize" => 0},
      "filter" => %{"supported" => true, "maxResults" => 200},
      "changePassword" => %{"supported" => false},
      "sort" => %{"supported" => true},
      "etag" => %{"supported" => false},
      "authenticationSchemes" => [
        %{
          "type" => "oauthbearertoken",
          "name" => "OAuth Bearer Token",
          "description" => "Authentication via bearer token in the Authorization header.",
          "primary" => true
        }
      ]
    }
  end

  # ───────────────────────────── response helpers ───────────────────────────── #

  # For inbound POST/PUT bodies that include a relationship-backed
  # multivalued attribute, apply each as a full-replace via manage_relationship.
  defp apply_relationship_inputs(changeset, relationships) when relationships == %{}, do: changeset

  defp apply_relationship_inputs(changeset, relationships) do
    Enum.reduce(relationships, changeset, fn {rel, inputs}, cs ->
      Ash.Changeset.manage_relationship(cs, rel, inputs, full_replace_options())
    end)
  end

  # Manage-relationship semantics:
  #
  # * Inbound members are SCIM identifiers (user_id), not Ash primary keys —
  #   so we don't try to look existing rows up by PK.
  # * `on_no_match: :create` creates a new related row when no existing match.
  # * `on_match: :ignore` leaves existing rows alone (we never need to update
  #   a Membership row in v1 since it has no other attributes worth changing).
  # * `on_missing: :destroy` removes existing rows that aren't in the new
  #   set, giving full-replace semantics.
  defp full_replace_options do
    [
      on_no_match: :create,
      on_match: :ignore,
      on_missing: :destroy
    ]
  end

  defp append_options do
    [
      on_no_match: :create,
      on_match: :ignore
    ]
  end

  defp encode_and_project(conn, record, opts) do
    conn = Plug.Conn.fetch_query_params(conn)

    record
    |> Encoder.encode(base_url: opts.base_url)
    |> Projection.apply(conn.query_params)
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type(@scim_content_type)
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp send_error(conn, status, detail, scim_type \\ nil) do
    send_json(conn, status, Error.build(status, detail, scim_type))
  end

  defp send_changeset_error(conn, error) do
    detail = Exception.message(error)

    cond do
      changeset_has_uniqueness?(error) -> send_error(conn, 409, detail, :uniqueness)
      changeset_invalid?(error) -> send_error(conn, 400, detail, :invalidValue)
      true -> send_error(conn, 500, detail)
    end
  end

  defp changeset_has_uniqueness?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%Ash.Error.Changes.InvalidAttribute{}, &1))

  defp changeset_has_uniqueness?(_), do: false

  defp changeset_invalid?(%Ash.Error.Invalid{}), do: true
  defp changeset_invalid?(_), do: false

  defp read_json_body(conn) do
    case body_params_or_read(conn) do
      {:ok, decoded, conn} when is_map(decoded) and map_size(decoded) > 0 ->
        {:ok, decoded, conn}

      {:ok, _, conn} ->
        # `body_params` is empty (or `%Plug.Conn.Unfetched{}`) — fall through
        # to reading the raw body ourselves.
        case Plug.Conn.read_body(conn) do
          {:ok, "", conn} ->
            {:halted, send_error(conn, 400, "request body was empty", :invalidSyntax)}

          {:ok, raw, conn} ->
            case Jason.decode(raw) do
              {:ok, decoded} when is_map(decoded) ->
                {:ok, decoded, conn}

              {:ok, _} ->
                {:halted, send_error(conn, 400, "expected a JSON object", :invalidSyntax)}

              {:error, _} ->
                {:halted, send_error(conn, 400, "malformed JSON", :invalidSyntax)}
            end

          {:more, _, conn} ->
            {:halted, send_error(conn, 413, "request entity too large")}

          {:error, _} ->
            {:halted, send_error(conn, 400, "could not read request body", :invalidSyntax)}
        end
    end
  end

  # When the host app's pipeline (typically Plug.Parsers in a Phoenix
  # Endpoint) has already parsed the JSON body, `conn.body_params` is a
  # populated map and the underlying body is no longer readable. Detect that
  # case and use the pre-parsed map; otherwise let the caller read raw.
  defp body_params_or_read(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn),
    do: {:ok, %{}, conn}

  defp body_params_or_read(%Plug.Conn{body_params: params} = conn) when is_map(params),
    do: {:ok, params, conn}
end
