# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

# credo:disable-for-this-file Credo.Check.Design.AliasUsage
if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshScim.Install do
    @example "mix igniter.install ash_scim"
    @example_custom "mix igniter.install ash_scim --user MyApp.Accounts.User --router MyAppWeb.ScimRouter"

    @shortdoc "Installs AshScim. Invoke with `mix igniter.install ash_scim`"

    @moduledoc """
    #{@shortdoc}

    Wires `AshScim.User` onto your user resource, adds the standard SCIM
    mapping defaults, ensures the router-bypass policy is present, and
    generates a SCIM router module. The installer is idempotent — re-running
    it on a partially-installed app picks up where it left off.

    The endpoint plug that forwards `/scim/v2/*` to the generated router
    isn't auto-wired — SCIM URLs include `:` in schema IDs which Phoenix's
    `Plug.Static` rejects, so the dispatch needs to live above
    `Plug.Static` in the endpoint pipeline. The installer prints the exact
    snippet to paste into your `Endpoint` module after it runs.

    ## Examples

    ```bash
    #{@example}
    ```

    ```bash
    #{@example_custom}
    ```

    ## Options

    * `--accounts` or `-a` — the domain that contains your user resource.
      Defaults to `YourApp.Accounts`.
    * `--user` or `-u` — the user resource. Defaults to `<accounts>.User`.
    * `--router` or `-r` — the SCIM router module to generate.
      Defaults to `<web_module>.ScimRouter`, falling back to
      `<accounts>.ScimRouter` when no Phoenix web module is present.
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        schema: [
          accounts: :string,
          user: :string,
          router: :string,
          yes: :boolean
        ],
        aliases: [
          a: :accounts,
          u: :user,
          r: :router,
          y: :yes
        ]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = parse_options(igniter)

      user_resource = options[:user]
      accounts_domain = options[:accounts]
      router_module = options[:router]
      otp_app = Igniter.Project.Application.app_name(igniter)

      igniter
      |> Igniter.Project.Formatter.import_dep(:ash_scim)
      |> Spark.Igniter.prepend_to_section_order(:"Ash.Resource", [:scim])
      |> ensure_user_exists(user_resource)
      |> extend_user_with_ash_scim(user_resource)
      |> add_default_attributes(user_resource)
      |> add_scim_block(user_resource)
      |> ensure_bypass_policy(user_resource)
      |> generate_scim_router(router_module, accounts_domain, otp_app)
      |> Ash.Igniter.codegen("add_scim_to_user_resource")
      |> add_endpoint_wiring_notice(router_module, otp_app)
      |> add_token_minting_notice(user_resource)
    end

    # ────────────────────────────── option parsing ────────────────────────────── #

    defp parse_options(igniter) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)

      igniter.args.options
      |> Keyword.put_new_lazy(:accounts, fn ->
        Igniter.Project.Module.module_name(igniter, "Accounts")
      end)
      |> parse_module_option(:accounts)
      |> then(fn opts ->
        opts
        |> Keyword.put_new(:user, Module.concat(opts[:accounts], User))
        |> Keyword.put_new(:router, default_router_module(web_module, opts[:accounts]))
      end)
      |> parse_module_option(:user)
      |> parse_module_option(:router)
    end

    defp parse_module_option(opts, key) do
      Keyword.update(opts, key, nil, fn value ->
        if is_binary(value) do
          Igniter.Project.Module.parse(value)
        else
          value
        end
      end)
    end

    defp default_router_module(nil, accounts), do: Module.concat(accounts, ScimRouter)
    defp default_router_module(web, _accounts), do: Module.concat(web, ScimRouter)

    # ────────────────────────────── user resource ────────────────────────────── #

    defp ensure_user_exists(igniter, user_resource) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, user_resource)

      if exists? do
        igniter
      else
        Igniter.add_issue(igniter, """
        User resource `#{inspect(user_resource)}` was not found.

        AshScim's installer expects an existing user resource — typically
        the one your app authenticates against. If you haven't created one
        yet, install AshAuthentication first:

            mix igniter.install ash_authentication

        Or pass `--user MyApp.Accounts.User` to point at the resource you
        want to expose via SCIM.
        """)
      end
    end

    defp extend_user_with_ash_scim(igniter, user_resource) do
      Igniter.compose_task(
        igniter,
        "ash.extend",
        [inspect(user_resource), "AshScim.User"]
      )
    end

    defp add_default_attributes(igniter, user_resource) do
      igniter
      |> Ash.Resource.Igniter.add_new_attribute(user_resource, :scim_external_id, """
      attribute :scim_external_id, :string do
        public? true
        description "External ID assigned by the IdP. Required for SCIM client-server reconciliation."
      end
      """)
      |> Ash.Resource.Igniter.add_new_attribute(user_resource, :active, """
      attribute :active, :boolean do
        public? true
        default true
        allow_nil? false
        description "Whether the user is active. SCIM clients flip this to deactivate."
      end
      """)
    end

    defp add_scim_block(igniter, user_resource) do
      AshScim.Igniter.add_scim_section(igniter, user_resource, """
      map :userName,   attribute: :email
      map :active,     attribute: :active
      map :externalId, attribute: :scim_external_id

      multivalued :emails do
        map :value,   attribute: :email
        map :primary, value: true
        map :type,    value: "work"
      end
      """)
    end

    defp ensure_bypass_policy(igniter, user_resource) do
      AshScim.Igniter.ensure_scim_bypass(igniter, user_resource)
    end

    # ──────────────────────────────── router module ────────────────────────────── #

    defp generate_scim_router(igniter, router_module, accounts_domain, otp_app) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, router_module)

      if exists? do
        Igniter.add_notice(
          igniter,
          "SCIM router `#{inspect(router_module)}` already exists; skipping generation."
        )
      else
        auth_block = router_auth_block(igniter, otp_app)

        contents =
          """
          @moduledoc \"\"\"
          SCIM 2.0 server entry point. Mount under `/scim/v2` from your
          Phoenix endpoint. See `mix ash_scim.install` notices and the
          AshScim Get Started guide for the endpoint dispatch snippet.
          \"\"\"

          use AshScim.Router,
            domains: [#{inspect(accounts_domain)}],
            auth: #{auth_block}
          """

        Igniter.Project.Module.create_module(igniter, router_module, contents)
      end
    end

    # Pick the auth implementation based on whether the **user's project**
    # depends on AshAuthentication. We read the user's `mix.exs` via
    # `Igniter.Project.Deps.has_dep?/2` rather than `Code.ensure_loaded?`
    # — at install time, the installer's BEAM doesn't reflect the user's
    # dependency tree.
    defp router_auth_block(igniter, otp_app) do
      if Igniter.Project.Deps.has_dep?(igniter, :ash_authentication) do
        """
        {AshScim.Auth.AshAuthenticationToken, otp_app: #{inspect(otp_app)}}\
        """
      else
        """
        {AshScim.Auth.StaticBearer, tokens: {:env, "SCIM_BEARER_TOKEN"}}\
        """
      end
    end

    # ────────────────────────────── notices ────────────────────────────── #

    defp add_endpoint_wiring_notice(igniter, router_module, otp_app) do
      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      endpoint_module = web_module && Module.concat(web_module, Endpoint)

      target =
        if endpoint_module do
          "in `#{inspect(endpoint_module)}`"
        else
          "in your Phoenix endpoint"
        end

      Igniter.add_notice(igniter, """
      Mount the SCIM router #{target}, **above** `Plug.Static` (SCIM URLs
      include `:` in schema IDs and `Plug.Static` rejects those):

          plug :scim_dispatch

          defp scim_dispatch(%Plug.Conn{path_info: ["scim", "v2" | rest]} = conn, _opts) do
            conn = %{conn | path_info: rest, script_name: conn.script_name ++ ["scim", "v2"]}

            conn
            |> #{inspect(router_module)}.call(#{inspect(router_module)}.init([]))
            |> Plug.Conn.halt()
          end

          defp scim_dispatch(conn, _opts), do: conn

      The `:#{otp_app}` config + endpoint module above can stay as-is —
      this is purely a routing concern.
      """)
    end

    defp add_token_minting_notice(igniter, user_resource) do
      if Igniter.Project.Deps.has_dep?(igniter, :ash_authentication) do
        Igniter.add_notice(igniter, """
        Mint a SCIM bearer token for your IdP from an `iex` console:

            email = "scim-service@your-app.local"

            user =
              case #{inspect(user_resource)}
                   |> Ash.Query.filter(email == ^email)
                   |> Ash.read_one(authorize?: false) do
                {:ok, %#{inspect(user_resource)}{} = u} -> u
                {:ok, nil} ->
                  #{inspect(user_resource)}
                  |> Ash.Changeset.for_create(:create, %{email: email, active: true})
                  |> Ash.create!(authorize?: false)
              end

            {:ok, jwt, _} =
              AshAuthentication.Jwt.token_for_user(user, %{"purpose" => "scim"})

            IO.puts(jwt)

        Paste the printed JWT into your IdP's SCIM provisioning configuration.
        Tokens stored in the `TokenResource` can be revoked at any time via
        `AshAuthentication.TokenResource.revoke/2`.
        """)
      else
        Igniter.add_notice(igniter, """
        SCIM auth defaulted to `AshScim.Auth.StaticBearer` reading from the
        `SCIM_BEARER_TOKEN` env var (AshAuthentication isn't installed).

        Set the env var before starting your app:

            export SCIM_BEARER_TOKEN="$(openssl rand -base64 32)"

        Paste the same value into your IdP's SCIM provisioning
        configuration. To switch to revocable JWTs later, install
        `ash_authentication` and update your router's `auth:` to
        `{AshScim.Auth.AshAuthenticationToken, otp_app: …}`.
        """)
      end
    end
  end
else
  defmodule Mix.Tasks.AshScim.Install do
    @shortdoc "Installs AshScim. Invoke with `mix igniter.install ash_scim`"

    @moduledoc @shortdoc

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task `ash_scim.install` requires Igniter to be installed.

      Run `mix igniter.install ash_scim` to install Igniter and AshScim
      together. See https://hexdocs.pm/igniter for details.
      """)

      exit({:shutdown, 1})
    end
  end
end
