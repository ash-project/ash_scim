# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Checks.AshScimInteractionTest do
  # Async-unsafe: we register a fixture resource and exercise the live ETS
  # data layer via the router.
  use ExUnit.Case, async: false

  use Plug.Test

  alias AshScim.Test.PolicyExample

  @opts AshScim.Router.init(
          domains: [PolicyExample.Domain],
          auth: {AshScim.Auth.StaticBearer, tokens: ["secret"]},
          base_url: "https://example.com/scim/v2"
        )

  setup do
    for record <- Ash.read!(PolicyExample.User, authorize?: false),
        do: Ash.destroy!(record, authorize?: false)

    :ok
  end

  defp request(method, path, body \\ nil) do
    conn(method, path, body)
    |> put_req_header("authorization", "Bearer secret")
    |> then(fn c ->
      if body, do: put_req_header(c, "content-type", "application/scim+json"), else: c
    end)
    |> AshScim.Router.call(@opts)
  end

  test "the router can read records on a resource whose policies forbid reads, via the bypass" do
    # The resource has `policy always() do; forbid_if always(); end`, so any
    # caller without the bypass can't read. The router uses the bypass.
    {:ok, _user} =
      PolicyExample.User
      |> Ash.Changeset.for_create(:create, %{
        email: "alice@example.com",
        scim_external_id: "okta-1"
      })
      |> Ash.create(authorize?: false)

    conn = request("GET", "/Users")

    assert conn.status == 200
    decoded = Jason.decode!(conn.resp_body)
    assert decoded["totalResults"] == 1
  end

  test "the router can create on a forbid-all resource via the bypass" do
    body =
      Jason.encode!(%{
        "userName" => "bob@example.com",
        "externalId" => "okta-2"
      })

    conn = request("POST", "/Users", body)

    assert conn.status == 201
  end
end
