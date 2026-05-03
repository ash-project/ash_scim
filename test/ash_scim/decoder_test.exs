# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.DecoderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshScim.Decoder
  alias AshScim.Test.Example.User

  describe "decode/2 — attrs" do
    test "extracts simple top-level mappings into Ash attribute params" do
      decoded =
        Decoder.decode(User, %{
          "userName" => "alice@example.com",
          "active" => false,
          "externalId" => "okta-abc-123"
        })

      assert decoded.attrs == %{
               email: "alice@example.com",
               active: false,
               scim_external_id: "okta-abc-123"
             }

      assert decoded.relationships == %{}
    end

    test "extracts complex sub-attributes into the corresponding Ash attributes" do
      decoded =
        Decoder.decode(User, %{
          "name" => %{"givenName" => "Alice", "familyName" => "Anderson"}
        })

      assert decoded.attrs == %{first_name: "Alice", last_name: "Anderson"}
    end

    test "ignores unknown SCIM attributes silently (RFC 7644 §3.1)" do
      decoded =
        Decoder.decode(User, %{
          "userName" => "alice@example.com",
          "preferredLanguage" => "en-US",
          "title" => "Engineer"
        })

      assert decoded.attrs == %{email: "alice@example.com"}
    end

    test "returns empty attrs and relationships for a body with no mapped fields" do
      assert %{attrs: %{}, relationships: %{}} = Decoder.decode(User, %{})
      assert %{attrs: %{}, relationships: %{}} = Decoder.decode(User, %{"unknown" => 123})
    end

    test "handles missing complex object gracefully" do
      decoded = Decoder.decode(User, %{"userName" => "alice@example.com"})
      assert decoded.attrs == %{email: "alice@example.com"}
    end
  end

  describe "decode/2 — single-attribute multivalued (no relationship)" do
    test "picks the primary element when one is marked" do
      decoded =
        Decoder.decode(User, %{
          "emails" => [
            %{"value" => "alice+alt@example.com", "primary" => false},
            %{"value" => "alice@example.com", "primary" => true}
          ]
        })

      assert decoded.attrs == %{email: "alice@example.com"}
    end

    test "falls back to the first element when none is marked primary" do
      decoded =
        Decoder.decode(User, %{
          "emails" => [
            %{"value" => "alice@example.com"},
            %{"value" => "alice+alt@example.com"}
          ]
        })

      assert decoded.attrs == %{email: "alice@example.com"}
    end

    test "skips emit-only static-value sub-mappings on the way in" do
      decoded = Decoder.decode(User, %{"emails" => [%{"primary" => false}]})

      assert decoded.attrs == %{}
    end

    test "warns when multiple entries are collapsed into a single attribute" do
      log =
        capture_log(fn ->
          Decoder.decode(User, %{
            "emails" => [
              %{"value" => "alice@example.com", "primary" => true},
              %{"value" => "alice+alt@example.com", "primary" => false}
            ]
          })
        end)

      assert log =~ "single-attribute multivalued :emails received 2 entries"
      assert log =~ "alice+alt@example.com"
      assert log =~ "relationship:"
    end

    test "does not warn for a single-entry array" do
      log =
        capture_log(fn ->
          Decoder.decode(User, %{"emails" => [%{"value" => "alice@example.com"}]})
        end)

      refute log =~ "single-attribute multivalued"
    end
  end
end
