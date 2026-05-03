# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

spark_locals_without_parens = []

[
  import_deps: [:ash, :spark],
  inputs: [
    "*.{ex,exs}",
    "{config,lib,test}/**/*.{ex,exs}"
  ],
  plugins: [Spark.Formatter],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ]
]
