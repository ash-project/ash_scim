# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Group do
  @moduledoc """
  Marks an Ash resource as a SCIM `Group` resource per RFC 7643 §4.2.

  Add to your group resource:

      defmodule MyApp.Accounts.Group do
        use Ash.Resource,
          domain: MyApp.Accounts,
          extensions: [AshScim.Group]

        scim do
          map :displayName, attribute: :name

          multivalued :members do
            map :value, attribute: :user_id
          end
        end

        # ... attributes, actions, relationships, etc.
      end

  See `AshScim.Dsl.Map`, `AshScim.Dsl.Complex`, and `AshScim.Dsl.Multivalued`
  for the per-entity options.
  """

  use Spark.Dsl.Extension,
    sections: [AshScim.Dsl.section(type: :group)],
    verifiers: [AshScim.Verifiers.Relationship]
end
