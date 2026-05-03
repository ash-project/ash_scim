# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.MixProject do
  @moduledoc false
  use Mix.Project

  @description """
  A SCIM 2.0 server extension for the Ash Framework.
  """

  @version "0.1.0"

  def project do
    [
      app: :ash_scim,
      version: @version,
      elixir: "~> 1.15",
      consolidate_protocols: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ],
      docs: &docs/0,
      aliases: aliases(),
      description: @description
    ]
  end

  def package do
    [
      maintainers: [
        "Zach Daniel <zach@zachdaniel.dev>"
      ],
      licenses: ["MIT"],
      links: %{
        "Source" => "https://github.com/ash-project/ash_scim",
        "Changelog" => "https://github.com/ash-project/ash_scim/blob/main/CHANGELOG.md",
        "REUSE Compliance" => "https://api.reuse.software/info/github.com/ash-project/ash_scim"
      },
      source_url: "https://github.com/ash-project/ash_scim",
      files:
        ~w[lib .formatter.exs mix.exs README* LICENSE* CHANGELOG* documentation usage-rules.md]
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extra_section: ["GUIDES"],
      extras: [
        {"README.md", name: "Home"},
        "CHANGELOG.md",
        "documentation/tutorials/get-started.md",
        "documentation/topics/multi-valued-attributes.md",
        "documentation/topics/filters.md",
        "documentation/topics/patch-operations.md",
        "documentation/topics/authentication.md",
        "documentation/topics/policies.md",
        "documentation/topics/multitenancy.md",
        "documentation/topics/limitations.md",
        {"documentation/dsls/DSL-AshScim.User.md",
         search_data: Spark.Docs.search_data_for(AshScim.User)},
        {"documentation/dsls/DSL-AshScim.Group.md",
         search_data: Spark.Docs.search_data_for(AshScim.Group)}
      ],
      groups_for_extras: [
        Tutorials: ~r"documentation/tutorials",
        Topics: ~r"documentation/topics",
        Reference: ~r"documentation/dsls"
      ],
      skip_undefined_reference_warnings_on: [
        "CHANGELOG.md"
      ],
      nest_modules_by_prefix: [],
      before_closing_head_tag: fn type ->
        if type == :html do
          """
          <script>
            if (location.hostname === "hexdocs.pm") {
              var script = document.createElement("script");
              script.src = "https://plausible.io/js/script.js";
              script.setAttribute("defer", "defer")
              script.setAttribute("data-domain", "ashhexdocs")
              document.head.appendChild(script);
            }
          </script>
          """
        end
      end,
      filter_modules: fn mod, _ ->
        String.starts_with?(inspect(mod), "AshScim") ||
          String.starts_with?(inspect(mod), "Mix.Task")
      end,
      source_url_pattern: "https://github.com/ash-project/ash_scim/blob/main/%{path}#L%{line}",
      groups_for_modules: [
        Internals: ~r/.*/
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, ash_version("~> 3.7")},
      {:igniter, "~> 0.6", optional: true},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.13"},
      {:spark, "~> 2.0"},
      {:splode, "~> 0.2"},

      # Optional: pulled in by AshScim.Auth.AshAuthenticationToken. Leaving
      # this `optional: true` lets host apps that don't use AshAuthentication
      # depend on AshScim without a transitive pull.
      {:ash_authentication, "~> 4.0 or ~> 5.0", optional: true},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.2", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.18", only: [:dev, :test]},
      {:ex_check, "~> 0.15", only: [:dev, :test]},
      {:ex_doc, "~> 0.39", only: [:dev, :test]},
      {:git_ops, "~> 2.4", only: [:dev, :test], runtime: false},
      {:mimic, "~> 2.0", only: [:dev, :test]},
      {:mix_audit, "~> 2.1", only: [:dev, :test]},
      {:plug_cowboy, "~> 2.5", only: [:dev, :test]},
      {:picosat_elixir, "~> 0.2", only: [:dev, :test]},
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      {:sobelow, "~> 0.12", only: [:dev, :test]},
      {:sourceror, "~> 1.8"},
      {:usage_rules, "~> 1.2", only: [:dev]}
    ]
  end

  defp aliases do
    extensions = [
      "AshScim.User",
      "AshScim.Group"
    ]

    [
      ci: [
        "format --check-formatted",
        "doctor --full --raise",
        "credo --strict",
        "dialyzer",
        "hex.audit",
        "test"
      ],
      "spark.formatter": "spark.formatter --extensions #{Enum.join(extensions, ",")}",
      "spark.cheat_sheets": "spark.cheat_sheets --extensions #{Enum.join(extensions, ",")}",
      docs: [
        "spark.cheat_sheets",
        "docs",
        "spark.replace_doc_links"
      ],
      credo: ["credo --strict"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp ash_version(default_version) do
    case System.get_env("ASH_VERSION") do
      nil -> default_version
      "local" -> [path: "../ash", override: true]
      "main" -> [git: "https://github.com/ash-project/ash.git", override: true]
      version -> "~> #{version}"
    end
  end
end
