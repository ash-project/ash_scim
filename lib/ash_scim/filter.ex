# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Filter do
  @moduledoc """
  Parses a SCIM 2.0 filter expression (RFC 7644 §3.4.2.2) directly into the
  map-shaped filter input accepted by `Ash.Query.filter/2` and
  `Ash.Filter.parse_input/2`.

  Performs the security-critical resolution in the same pass: every attribute
  path mentioned in the filter must be declared in the resource's `scim`
  mappings, otherwise the parse fails. Unmapped fields can never reach Ash.

  ## Output shape

    * Simple comparison: `%{email: %{eq: "alice"}}`
    * Presence: `%{email: %{is_nil: false}}`
    * Complex sub-attribute: flattens to the underlying scalar attribute,
      e.g. `name.givenName` → `%{first_name: %{eq: "Alice"}}`.
    * Single-attribute multivalued: same flattening.
    * **Relationship-backed multivalued**: emits Ash's native nested filter
      form, e.g. `members.value eq "u1"` →
      `%{memberships: %{user_id: %{eq: "u1"}}}`.
    * Boolean composition: `%{and: [filter, …]}` / `%{or: [filter, …]}` /
      `%{not: filter}`. Chained `and`/`or` flatten to a single list.

  ## Operator support

  | SCIM | Ash |
  | ---- | --- |
  | `eq` | `eq` |
  | `ne` | `not_eq` |
  | `co` | `contains` |
  | `sw` | `string_starts_with?` |
  | `ew` | `string_ends_with?` |
  | `pr` | `is_nil: false` |
  | `gt` | `greater_than` |
  | `ge` | `greater_than_or_equal` |
  | `lt` | `less_than` |
  | `le` | `less_than_or_equal` |
  """

  alias AshScim.Dsl.{Complex, Map, Multivalued}

  @comp_ops ~w(eq ne co sw ew gt ge lt le)
  @op_translation %{
    eq: :eq,
    ne: :not_eq,
    co: :contains,
    sw: :string_starts_with?,
    ew: :string_ends_with?,
    gt: :greater_than,
    ge: :greater_than_or_equal,
    lt: :less_than,
    le: :less_than_or_equal
  }

  @type opts :: [prefix: [String.t()]]

  @doc """
  Parse a SCIM filter string against `resource`'s SCIM mappings.

  ## Options

    * `:prefix` — a list of SCIM attribute names to virtually prepend to every
      attribute path inside the filter. Used by the PATCH bracket-filter
      parser: a filter `value eq "x"` written inside `members[…]` is parsed
      with `prefix: ["members"]` so it resolves as if it were
      `members.value eq "x"`.

  Returns `{:ok, filter}` where `filter` is a map suitable for
  `Ash.Query.filter_input/2`, or `{:error, reason}`.
  """
  @spec parse(String.t(), module(), opts()) :: {:ok, map()} | {:error, term()}
  def parse(input, resource, opts \\ [])
      when is_binary(input) and is_atom(resource) and not is_nil(resource) do
    mappings = AshScim.Info.scim_mappings(resource)
    prefix = Keyword.get(opts, :prefix, [])

    with {:ok, tokens} <- tokenize(input),
         {:ok, filter, []} <- parse_or(tokens, %{mappings: mappings, prefix: prefix}) do
      {:ok, filter}
    else
      {:ok, _filter, [{type, _} | _]} ->
        {:error, "unexpected #{type} token after expression"}

      {:error, _} = err ->
        err
    end
  end

  # ───────────────────────────── tokenizer ───────────────────────────── #

  defp tokenize(input), do: tokenize(input, [])

  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r],
    do: tokenize(rest, acc)

  defp tokenize("(" <> rest, acc), do: tokenize(rest, [{:lparen, "("} | acc])
  defp tokenize(")" <> rest, acc), do: tokenize(rest, [{:rparen, ")"} | acc])

  defp tokenize(<<?", rest::binary>>, acc) do
    case read_string(rest, []) do
      {:ok, str, rest2} -> tokenize(rest2, [{:string, str} | acc])
      {:error, _} = err -> err
    end
  end

  defp tokenize(input, acc) do
    case read_word(input) do
      {:ok, word, rest} -> tokenize(rest, [classify(word) | acc])
      {:error, _} = err -> err
    end
  end

  defp read_string(<<?\\, c, rest::binary>>, acc), do: read_string(rest, [c | acc])

  defp read_string(<<?", rest::binary>>, acc),
    do: {:ok, acc |> Enum.reverse() |> List.to_string(), rest}

  defp read_string(<<c, rest::binary>>, acc), do: read_string(rest, [c | acc])
  defp read_string("", _acc), do: {:error, "unterminated string literal"}

  defp read_word(input) do
    case do_read_word(input, []) do
      {[], _rest} -> {:error, "unexpected character: #{String.first(input)}"}
      {chars, rest} -> {:ok, chars |> Enum.reverse() |> List.to_string(), rest}
    end
  end

  defp do_read_word(<<c, rest::binary>>, acc) when c in ?a..?z or c in ?A..?Z or c == ?_,
    do: do_read_word(rest, [c | acc])

  defp do_read_word(<<c, rest::binary>>, [_ | _] = acc)
       when c in ?0..?9 or c == ?. or c == ?- or c == ?_ or c == ?:,
       do: do_read_word(rest, [c | acc])

  defp do_read_word(<<c, rest::binary>>, []) when c in ?0..?9 or c == ?-,
    do: do_read_number(rest, [c])

  defp do_read_word(rest, acc), do: {acc, rest}

  defp do_read_number(<<c, rest::binary>>, acc) when c in ?0..?9 or c == ?.,
    do: do_read_number(rest, [c | acc])

  defp do_read_number(rest, acc), do: {acc, rest}

  defp classify(word) do
    lower = String.downcase(word)

    cond do
      lower in @comp_ops -> {:comp_op, String.to_atom(lower)}
      lower == "pr" -> {:pr, :pr}
      lower == "and" -> {:and, :and}
      lower == "or" -> {:or, :or}
      lower == "not" -> {:not, :not}
      lower == "true" -> {:bool, true}
      lower == "false" -> {:bool, false}
      lower == "null" -> {:null, nil}
      number?(word) -> {:number, parse_number(word)}
      true -> {:ident, word}
    end
  end

  defp number?(<<?-, rest::binary>>), do: number?(rest)
  defp number?(""), do: false

  defp number?(str) do
    case Float.parse(str) do
      {_, ""} -> true
      _ -> match?({_, ""}, Integer.parse(str))
    end
  end

  defp parse_number(str) do
    if String.contains?(str, ".") do
      String.to_float(str)
    else
      String.to_integer(str)
    end
  end

  # ───────────────────────────── parser ───────────────────────────── #
  #
  # Boolean parsers accumulate operands so chained ands/ors flatten:
  # `a or b or c` → %{or: [a, b, c]} rather than the right-recursive form.

  defp parse_or(tokens, ctx) do
    with {:ok, first, rest} <- parse_and(tokens, ctx) do
      collect_or([first], rest, ctx)
    end
  end

  defp collect_or(acc, [{:or, _} | rest], ctx) do
    case parse_and(rest, ctx) do
      {:ok, next, rest2} -> collect_or([next | acc], rest2, ctx)
      err -> err
    end
  end

  defp collect_or([single], rest, _ctx), do: {:ok, single, rest}
  defp collect_or(acc, rest, _ctx), do: {:ok, %{or: Enum.reverse(acc)}, rest}

  defp parse_and(tokens, ctx) do
    with {:ok, first, rest} <- parse_unary(tokens, ctx) do
      collect_and([first], rest, ctx)
    end
  end

  defp collect_and(acc, [{:and, _} | rest], ctx) do
    case parse_unary(rest, ctx) do
      {:ok, next, rest2} -> collect_and([next | acc], rest2, ctx)
      err -> err
    end
  end

  defp collect_and([single], rest, _ctx), do: {:ok, single, rest}
  defp collect_and(acc, rest, _ctx), do: {:ok, %{and: Enum.reverse(acc)}, rest}

  defp parse_unary([{:not, _}, {:lparen, _} | rest], ctx) do
    with {:ok, inner, [{:rparen, _} | rest2]} <- parse_or(rest, ctx) do
      {:ok, %{not: inner}, rest2}
    else
      {:ok, _, _} -> {:error, "expected `)` after `not (...`"}
      err -> err
    end
  end

  defp parse_unary([{:not, _} | _], _), do: {:error, "expected `(` after `not`"}

  defp parse_unary([{:lparen, _} | rest], ctx) do
    with {:ok, inner, [{:rparen, _} | rest2]} <- parse_or(rest, ctx) do
      {:ok, inner, rest2}
    else
      {:ok, _, _} -> {:error, "expected `)`"}
      err -> err
    end
  end

  defp parse_unary(tokens, ctx), do: parse_atom(tokens, ctx)

  defp parse_atom([{:ident, ident} | rest], ctx) do
    path = ctx.prefix ++ String.split(ident, ".")

    with {:ok, target} <- lookup_attribute(path, ctx.mappings),
         {:ok, predicate, rest2} <- parse_predicate(rest) do
      {:ok, build_filter(target, predicate), rest2}
    end
  end

  defp parse_atom([{type, _} | _], _), do: {:error, "expected attribute path, got #{type}"}
  defp parse_atom([], _), do: {:error, "unexpected end of input"}

  defp parse_predicate([{:pr, _} | rest]),
    do: {:ok, %{is_nil: false}, rest}

  defp parse_predicate([{:comp_op, op}, value_token | rest]) do
    with {:ok, value} <- token_to_value(value_token),
         {:ok, ash_op} <- translate_op(op) do
      {:ok, %{ash_op => value}, rest}
    end
  end

  defp parse_predicate([{:comp_op, _} | _]),
    do: {:error, "expected literal after comparison operator"}

  defp parse_predicate(_),
    do: {:error, "expected `pr` or comparison operator after attribute path"}

  defp translate_op(op) do
    case Elixir.Map.fetch(@op_translation, op) do
      {:ok, ash_op} -> {:ok, ash_op}
      :error -> {:error, "operator `#{op}` is not currently supported"}
    end
  end

  defp token_to_value({:string, s}), do: {:ok, s}
  defp token_to_value({:number, n}), do: {:ok, n}
  defp token_to_value({:bool, b}), do: {:ok, b}
  defp token_to_value({:null, _}), do: {:ok, nil}
  defp token_to_value({type, _}), do: {:error, "expected literal, got #{type}"}

  # build_filter wraps a resolved target with its predicate into the right
  # nesting depth.
  defp build_filter(attr, predicate) when is_atom(attr), do: %{attr => predicate}

  defp build_filter([rel, attr], predicate),
    do: %{rel => %{attr => predicate}}

  # ────────────────────────── attribute resolution ────────────────────── #

  defp lookup_attribute([single], mappings) do
    Enum.find_value(mappings, {:error, {:unknown_attribute, [single]}}, fn
      %Map{name: name, attribute: attr} when not is_nil(attr) ->
        if to_string(name) == single, do: {:ok, attr}, else: nil

      _ ->
        nil
    end)
  end

  defp lookup_attribute([outer, _inner] = full, mappings) do
    Enum.find_value(mappings, {:error, {:unknown_attribute, full}}, fn
      %Complex{name: name, maps: sub_maps} ->
        if to_string(name) == outer, do: do_inner_lookup(sub_maps, full), else: nil

      %Multivalued{name: name, relationship: rel, maps: sub_maps}
      when is_atom(rel) and not is_nil(rel) ->
        if to_string(name) == outer do
          case do_inner_lookup(sub_maps, full) do
            {:ok, attr} -> {:ok, [rel, attr]}
            err -> err
          end
        else
          nil
        end

      %Multivalued{name: name, maps: sub_maps} ->
        if to_string(name) == outer, do: do_inner_lookup(sub_maps, full), else: nil

      _ ->
        nil
    end)
  end

  defp lookup_attribute(path, _mappings),
    do: {:error, {:unknown_attribute, path}}

  defp do_inner_lookup(sub_maps, [_, inner] = full_path) do
    Enum.find_value(sub_maps, {:error, {:unknown_attribute, full_path}}, fn
      %Map{name: name, attribute: attr} when not is_nil(attr) ->
        if to_string(name) == inner, do: {:ok, attr}, else: nil

      _ ->
        nil
    end)
  end
end
