# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.FilterTest do
  use ExUnit.Case, async: true

  alias AshScim.Filter
  alias AshScim.Test.Example.User

  describe "comparisons" do
    test "translates `eq` to Ash :eq" do
      assert {:ok, %{email: %{eq: "alice"}}} =
               Filter.parse(~S/userName eq "alice"/, User)
    end

    test "translates `ne`/`co`/`gt`/`ge`/`lt`/`le`" do
      assert {:ok, %{email: %{not_eq: "x"}}} = Filter.parse(~S/userName ne "x"/, User)
      assert {:ok, %{email: %{contains: "li"}}} = Filter.parse(~S/userName co "li"/, User)
      assert {:ok, %{active: %{greater_than: true}}} = Filter.parse(~S/active gt true/, User)

      assert {:ok, %{active: %{greater_than_or_equal: true}}} =
               Filter.parse(~S/active ge true/, User)

      assert {:ok, %{active: %{less_than: false}}} = Filter.parse(~S/active lt false/, User)

      assert {:ok, %{active: %{less_than_or_equal: false}}} =
               Filter.parse(~S/active le false/, User)
    end

    test "translates `pr` to is_nil: false" do
      assert {:ok, %{email: %{is_nil: false}}} = Filter.parse(~S/userName pr/, User)
    end

    test "translates sw/ew to string_starts_with?/string_ends_with?" do
      assert {:ok, %{email: %{string_starts_with?: "a"}}} =
               Filter.parse(~S/userName sw "a"/, User)

      assert {:ok, %{email: %{string_ends_with?: "z"}}} =
               Filter.parse(~S/userName ew "z"/, User)
    end

    test "is case-insensitive on operators" do
      assert {:ok, %{email: %{eq: "alice"}}} = Filter.parse(~S/userName EQ "alice"/, User)
    end

    test "resolves dotted paths through complex/multivalued mappings" do
      assert {:ok, %{first_name: %{eq: "Alice"}}} =
               Filter.parse(~S/name.givenName eq "Alice"/, User)

      # Relationship-backed multivalueds resolve to a nested map rooted at
      # the relationship name, with the SCIM sub-attribute mapped to the
      # related resource's attribute.
      assert {:ok, %{emails: %{value: %{eq: "alice@example.com"}}}} =
               Filter.parse(~S/emails.value eq "alice@example.com"/, User)
    end

    test "literal types: string, integer, float, bool, null" do
      assert {:ok, %{email: %{eq: "x"}}} = Filter.parse(~S/userName eq "x"/, User)
      # Numeric/null/bool are accepted on any mapped field; the value is just plumbed through.
      assert {:ok, %{active: %{eq: true}}} = Filter.parse(~S/active eq true/, User)
      assert {:ok, %{active: %{eq: false}}} = Filter.parse(~S/active eq false/, User)
      assert {:ok, %{active: %{eq: nil}}} = Filter.parse(~S/active eq null/, User)
    end
  end

  describe "boolean composition" do
    test "and binds tighter than or" do
      input = ~S/userName eq "a" or active eq true and active eq false/

      assert {:ok,
              %{
                or: [
                  %{email: %{eq: "a"}},
                  %{
                    and: [
                      %{active: %{eq: true}},
                      %{active: %{eq: false}}
                    ]
                  }
                ]
              }} = Filter.parse(input, User)
    end

    test "parens override precedence" do
      input = ~S/(userName eq "a" or active eq true) and active eq false/

      assert {:ok,
              %{
                and: [
                  %{or: [%{email: %{eq: "a"}}, %{active: %{eq: true}}]},
                  %{active: %{eq: false}}
                ]
              }} = Filter.parse(input, User)
    end

    test "not (...) wraps in :not" do
      assert {:ok, %{not: %{active: %{eq: true}}}} =
               Filter.parse(~S/not (active eq true)/, User)
    end

    test "rejects `not` without parens" do
      assert {:error, _} = Filter.parse("not active eq true", User)
    end
  end

  describe "security" do
    test "rejects unmapped top-level attribute paths" do
      assert {:error, {:unknown_attribute, ["password"]}} =
               Filter.parse(~S/password eq "hunter2"/, User)
    end

    test "rejects unmapped complex sub-paths" do
      assert {:error, {:unknown_attribute, ["name", "middleName"]}} =
               Filter.parse(~S/name.middleName eq "Q"/, User)
    end

    test "rejects deep paths beyond two segments" do
      assert {:error, {:unknown_attribute, ["a", "b", "c"]}} =
               Filter.parse(~S/a.b.c eq "x"/, User)
    end

    test "resolves boolean sub-attributes on relationship-backed multivalueds" do
      assert {:ok, %{emails: %{primary: %{eq: true}}}} =
               Filter.parse(~S/emails.primary eq true/, User)
    end
  end

  describe "errors" do
    test "rejects trailing junk" do
      assert {:error, _} = Filter.parse(~S/userName eq "alice" foo/, User)
    end

    test "rejects unterminated strings" do
      assert {:error, _} = Filter.parse(~S/userName eq "alice/, User)
    end

    test "rejects empty input" do
      assert {:error, _} = Filter.parse("", User)
    end
  end

  describe "relationship-backed multivalued sub-paths" do
    alias AshScim.Test.Example.Group

    test "emit Ash's nested-map form so the filter traverses the relationship" do
      assert {:ok, %{memberships: %{user_id: %{eq: "u1"}}}} =
               Filter.parse(~S/members.value eq "u1"/, Group)
    end

    test "compose with boolean operators" do
      input = ~S/displayName eq "engineering" and members.value eq "u1"/

      assert {:ok,
              %{
                and: [
                  %{name: %{eq: "engineering"}},
                  %{memberships: %{user_id: %{eq: "u1"}}}
                ]
              }} = Filter.parse(input, Group)
    end

    test "are usable directly with Ash.Query.filter_input/2 against the parent resource" do
      {:ok, filter} = Filter.parse(~S/members.value eq "u1"/, Group)

      query =
        Group
        |> Ash.Query.new()
        |> Ash.Query.filter_input(filter)

      assert query.valid?
    end
  end

  describe "prefix option" do
    alias AshScim.Test.Example.Group

    test "treats the bracket filter as if it were dotted from the multivalued name" do
      # `value eq "u1"` parsed with prefix ["members"] is equivalent to
      # `members.value eq "u1"` parsed at the top level.
      assert {:ok, %{memberships: %{user_id: %{eq: "u1"}}}} =
               Filter.parse(~S/value eq "u1"/, Group, prefix: ["members"])
    end
  end

  describe "Ash integration" do
    test "the parsed filter is usable with Ash.Query.filter/2 against the resource" do
      {:ok, filter} = Filter.parse(~S/userName eq "alice@example.com"/, User)

      query =
        User
        |> Ash.Query.new()
        |> Ash.Query.filter_input(filter)

      assert query.valid?
    end

    test "boolean composition is consumable end-to-end" do
      {:ok, filter} =
        Filter.parse(~S/userName eq "a@x.com" and active eq true/, User)

      query =
        User
        |> Ash.Query.new()
        |> Ash.Query.filter_input(filter)

      assert query.valid?
    end
  end
end
