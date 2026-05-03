# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.EncoderTest do
  use ExUnit.Case, async: true

  alias AshScim.Encoder
  alias AshScim.Test.Example.User

  defp build_user(overrides \\ []) do
    attrs =
      [
        email: "alice@example.com",
        active: true,
        first_name: "Alice",
        last_name: "Anderson",
        scim_external_id: "okta-abc-123"
      ]
      |> Keyword.merge(overrides)
      |> Enum.into(%{})

    User
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end

  describe "encode/2" do
    test "emits the SCIM schema and id" do
      user = build_user()

      encoded = Encoder.encode(user)

      assert encoded["schemas"] == ["urn:ietf:params:scim:schemas:core:2.0:User"]
      assert encoded["id"] == to_string(user.id)
    end

    test "applies simple maps using the SCIM attribute name" do
      user = build_user()

      encoded = Encoder.encode(user)

      assert encoded["userName"] == "alice@example.com"
      assert encoded["active"] == true
      assert encoded["externalId"] == "okta-abc-123"
    end

    test "encodes complex (object) attributes from sub-maps" do
      user = build_user()

      assert %{"name" => %{"givenName" => "Alice", "familyName" => "Anderson"}} =
               Encoder.encode(user)
    end

    test "encodes multivalued attributes as a single-element array" do
      user = build_user()

      assert %{"emails" => [%{"value" => "alice@example.com", "primary" => true}]} =
               Encoder.encode(user)
    end

    test "omits keys whose backing attribute is nil" do
      user = build_user(first_name: nil, last_name: nil)

      encoded = Encoder.encode(user)

      refute Map.has_key?(encoded, "name")
    end

    test "emits meta.resourceType and (with base_url) location" do
      user = build_user()

      assert %{"meta" => %{"resourceType" => "User", "location" => location}} =
               Encoder.encode(user, base_url: "https://example.com/scim/v2")

      assert location == "https://example.com/scim/v2/Users/" <> to_string(user.id)
    end

    test "omits meta.location when no base_url is given" do
      user = build_user()

      assert %{"meta" => meta} = Encoder.encode(user)
      refute Map.has_key?(meta, "location")
    end
  end

  describe "list_response/2" do
    test "wraps resources in the SCIM ListResponse envelope" do
      user = build_user()
      one = Encoder.encode(user)

      envelope = Encoder.list_response([one])

      assert envelope["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:ListResponse"]
      assert envelope["totalResults"] == 1
      assert envelope["startIndex"] == 1
      assert envelope["itemsPerPage"] == 1
      assert envelope["Resources"] == [one]
    end

    test "respects passed-in pagination metadata" do
      envelope =
        Encoder.list_response([%{"id" => "1"}, %{"id" => "2"}],
          total_results: 100,
          start_index: 21,
          items_per_page: 2
        )

      assert envelope["totalResults"] == 100
      assert envelope["startIndex"] == 21
      assert envelope["itemsPerPage"] == 2
    end
  end
end
