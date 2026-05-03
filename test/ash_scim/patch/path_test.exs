# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Patch.PathTest do
  use ExUnit.Case, async: true

  alias AshScim.Patch.Path
  alias AshScim.Test.Example.User

  describe "simple paths" do
    test "parses a top-level attribute" do
      assert {:ok, %Path{attribute: "userName", sub_attribute: nil, filter: nil}} =
               Path.parse("userName", User)
    end

    test "parses a complex sub-attribute" do
      assert {:ok, %Path{attribute: "name", sub_attribute: "givenName", filter: nil}} =
               Path.parse("name.givenName", User)
    end
  end

  describe "bracket-filter paths" do
    test "extracts the filter and leaves no sub-attribute" do
      # `type` is currently a static-value mapping on `:emails`, so the filter
      # resolver drops it (no backing Ash attribute to filter against). We
      # still get a clean parse with `filter: nil` and the rest intact.
      assert {:ok, %Path{attribute: "emails", sub_attribute: nil, filter: nil}} =
               Path.parse(~S(emails[type eq "work"]), User)
    end

    test "extracts the filter and the sub-attribute" do
      assert {:ok, %Path{attribute: "emails", sub_attribute: "value", filter: nil}} =
               Path.parse(~S(emails[type eq "work"].value), User)
    end

    test "tolerates unknown attribute names inside the filter" do
      assert {:ok, %Path{filter: nil}} =
               Path.parse(~S(emails[notARealField eq "work"].value), User)
    end
  end

  describe "errors" do
    test "rejects an unterminated bracket" do
      assert {:error, _} = Path.parse(~S(emails[type eq "work"), User)
    end

    test "rejects malformed filter content" do
      assert {:error, _} = Path.parse(~S(emails[not a filter].value), User)
    end

    test "rejects garbage after a sub-attribute" do
      assert {:error, _} = Path.parse("name.givenName.deeper", User)
    end

    test "rejects an empty path" do
      assert {:error, _} = Path.parse("", User)
    end
  end
end
