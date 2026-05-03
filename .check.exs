# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

[
  ## don't run tools concurrently
  # parallel: false,

  ## don't print info about skipped tools
  # skipped: false,

  ## always run tools in fix mode (put it in ~/.check.exs locally, not in project config)
  # fix: true,

  ## don't retry automatically even if last run resulted in failures
  # retry: false,

  ## list of tools (see `mix check` docs for a list of default curated tools)
  tools: [
    {:sobelow, "mix sobelow --config"},
    {:credo, "mix credo --strict"},
    {:spark_formatter, "mix spark.formatter --check"},
    {:spark_cheat_sheets, "mix spark.cheat_sheets --check"},
    {:reuse, command: ["pipx", "run", "reuse", "lint", "-q"]}
  ]
]
