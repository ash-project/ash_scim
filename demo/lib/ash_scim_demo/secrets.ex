defmodule AshScimDemo.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        AshScimDemo.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:ash_scim_demo, :token_signing_secret)
  end
end
