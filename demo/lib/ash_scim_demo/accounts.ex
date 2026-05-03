defmodule AshScimDemo.Accounts do
  use Ash.Domain,
    otp_app: :ash_scim_demo

  resources do
    resource AshScimDemo.Accounts.Token
    resource AshScimDemo.Accounts.User
    resource AshScimDemo.Accounts.Email
    resource AshScimDemo.Accounts.Group
    resource AshScimDemo.Accounts.Membership
  end
end
