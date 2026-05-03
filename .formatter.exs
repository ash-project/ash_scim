# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

spark_locals_without_parens = [
  attribute: 1,
  case_exact?: 1,
  complex: 1,
  complex: 2,
  create_action: 1,
  destroy_action: 1,
  map: 1,
  map: 2,
  meta?: 1,
  mirror_primary_to: 1,
  multivalued: 1,
  multivalued: 2,
  mutability: 1,
  path: 1,
  read_action: 1,
  relationship: 1,
  returned: 1,
  schema: 1,
  uniqueness: 1,
  update_action: 1,
  value: 1
]

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
