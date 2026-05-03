defmodule AshScimDemoWeb.ScimRouter do
  @moduledoc """
  SCIM 2.0 server entry point. Mounted at `/scim/v2` from the Phoenix router.

  Bearer tokens are JWTs issued by AshAuthentication with `purpose: "scim"`,
  stored in the `Token` resource so they can be revoked.
  """

  use AshScim.Router,
    domains: [AshScimDemo.Accounts],
    auth: {AshScim.Auth.AshAuthenticationToken, otp_app: :ash_scim_demo},
    base_url: "http://localhost:4002/scim/v2"
end
