# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Patch.Path do
  @moduledoc """
  Parser for SCIM 2.0 PATCH `path` expressions (RFC 7644 §3.5.2).

  A PATCH path is one of:

    * `attr` — a top-level attribute (e.g. `userName`)
    * `attr.sub` — a complex sub-attribute (e.g. `name.givenName`)
    * `attr[filter]` — a filter against a multivalued attribute
      (e.g. `emails[type eq "work"]`, `members[value eq "abc-123"]`)
    * `attr[filter].sub` — a sub-attribute of a filter-matched element
      (e.g. `emails[type eq "work"].value`)

  The parser returns a struct describing the parts so callers can decide how
  to apply each kind. The bracket filter is parsed via `AshScim.Filter` to
  validate its syntax.

  Note: `AshScim.Filter.parse/2` does both *parse* and *resolve*. The
  resolver requires a resource so it can map SCIM names to Ash attributes.
  We accept the resource here too, so any attribute names referenced inside
  the bracket filter are validated against the resource's mappings.
  """

  defstruct [:attribute, :sub_attribute, :filter, :relationship]

  @type t :: %__MODULE__{
          attribute: String.t(),
          sub_attribute: String.t() | nil,
          filter: %{} | nil,
          relationship: atom() | nil
        }

  @doc """
  Parse `path` against the resource's SCIM mappings.

  Returns `{:ok, %#{inspect(__MODULE__)}{}}` or `{:error, reason}`.
  """
  @spec parse(String.t(), module()) :: {:ok, t()} | {:error, term()}
  def parse(path, resource) when is_binary(path) and is_atom(resource) do
    with {:ok, attr, filter_string, sub} <- do_split(path) do
      relationship = relationship_backing(attr, resource)

      case maybe_parse_filter(filter_string, resource, attr, relationship) do
        {:ok, filter} ->
          {:ok,
           %__MODULE__{
             attribute: attr,
             sub_attribute: sub,
             filter: filter,
             relationship: relationship
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  # Returns the Ash relationship atom backing this multivalued, or nil for
  # non-relationship multivalueds and non-multivalued paths.
  defp relationship_backing(attr, resource) do
    Enum.find_value(AshScim.Info.scim_mappings(resource), fn
      %AshScim.Dsl.Multivalued{name: name, relationship: rel}
      when is_atom(rel) and not is_nil(rel) ->
        if Atom.to_string(name) == attr, do: rel

      _ ->
        nil
    end)
  end

  defp maybe_parse_filter(nil, _resource, _attr, _rel), do: {:ok, nil}

  # Relationship-backed multivalued: parse the bracket filter as if it were
  # `<multivalued>.<filter>` against the parent resource. AshScim.Filter
  # then emits Ash's nested map form (`%{rel => %{ash_attr => predicate}}`)
  # which we unwrap to the inner sub-filter for application against the
  # related resource.
  defp maybe_parse_filter(filter_string, resource, attr, rel) when is_atom(rel) and not is_nil(rel) do
    with {:ok, filter} <- AshScim.Filter.parse(filter_string, resource, prefix: [attr]) do
      {:ok, Elixir.Map.get(filter, rel)}
    end
  end

  # Single-attribute multivalued (or scalar/complex bare path): filter is
  # informational. Syntax errors fail fast, unknown attributes inside the
  # filter are dropped silently.
  defp maybe_parse_filter(filter_string, resource, attr, nil) do
    case AshScim.Filter.parse(filter_string, resource, prefix: [attr]) do
      {:ok, filter} -> {:ok, filter}
      {:error, {:unknown_attribute, _}} -> {:ok, nil}
      {:error, _} = err -> err
    end
  end

  # ──────────────────────────── splitter ──────────────────────────── #
  #
  # The path is parsed without recursion since the grammar is small. We walk
  # forward, accumulating characters, branching when we see `[` or `.`.

  defp do_split(input) do
    case extract_attribute(input) do
      {:ok, attr, ""} ->
        {:ok, attr, nil, nil}

      {:ok, attr, "[" <> rest} ->
        with {:ok, filter, rest_after_bracket} <- extract_until(rest, "]"),
             {:ok, sub} <- maybe_sub_attribute(rest_after_bracket) do
          {:ok, attr, filter, sub}
        end

      {:ok, attr, "." <> rest} ->
        with {:ok, sub} <- attribute_only(rest) do
          {:ok, attr, nil, sub}
        end

      {:ok, _, _other} ->
        {:error, "invalid path"}

      {:error, _} = err ->
        err
    end
  end

  defp extract_attribute(input) do
    case Regex.run(~r/^([A-Za-z][A-Za-z0-9_-]*)(.*)/s, input) do
      [_, attr, rest] -> {:ok, attr, rest}
      _ -> {:error, "expected attribute name"}
    end
  end

  defp extract_until(input, terminator) do
    case String.split(input, terminator, parts: 2) do
      [content, rest] -> {:ok, content, rest}
      _ -> {:error, "missing `#{terminator}` in path"}
    end
  end

  defp maybe_sub_attribute(""), do: {:ok, nil}

  defp maybe_sub_attribute("." <> rest), do: attribute_only(rest) |> then(&wrap_ok/1)

  defp maybe_sub_attribute(_), do: {:error, "unexpected characters after `]`"}

  defp wrap_ok({:ok, _} = result), do: result
  defp wrap_ok({:error, _} = err), do: err

  defp attribute_only(input) do
    case extract_attribute(input) do
      {:ok, attr, ""} -> {:ok, attr}
      {:ok, _, _} -> {:error, "trailing characters after sub-attribute"}
      {:error, _} = err -> err
    end
  end
end
