# Seeds: ensure a service-account user exists and mint a SCIM bearer token
# for use with compliance testers. Idempotent — safe to re-run.

require Ash.Query

alias AshScimDemo.Accounts.User
alias AshAuthentication.Jwt

email = "scim-service@ash-scim-demo.local"

user =
  case User |> Ash.Query.filter(email == ^email) |> Ash.read_one() do
    {:ok, %User{} = u} ->
      u

    {:ok, nil} ->
      User
      |> Ash.Changeset.for_create(:create, %{
        email: email,
        active: true,
        first_name: "SCIM",
        last_name: "Service"
      })
      |> Ash.create!()
  end

{:ok, jwt, _claims} = Jwt.token_for_user(user, %{"purpose" => "scim"})

IO.puts("\n==========================================================")
IO.puts("Service-account user id : #{user.id}")
IO.puts("SCIM bearer token       :")
IO.puts(jwt)
IO.puts("==========================================================\n")
