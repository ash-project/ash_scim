# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.User do
  @moduledoc """
  Marks an Ash resource as a SCIM `User` resource per RFC 7643 §4.1.

  Add to your user resource:

      defmodule MyApp.Accounts.User do
        use Ash.Resource,
          domain: MyApp.Accounts,
          extensions: [AshAuthentication, AshScim.User]

        scim do
          map :userName, attribute: :email
          map :active, attribute: :active

          complex :name do
            map :givenName, attribute: :first_name
            map :familyName, attribute: :last_name
          end

          multivalued :emails do
            map :value, attribute: :email
            map :primary, value: true
          end
        end

        # ... attributes, actions, etc.
      end

  See `AshScim.Dsl.Map`, `AshScim.Dsl.Complex`, and `AshScim.Dsl.Multivalued`
  for the per-entity options.
  """

  use Spark.Dsl.Extension,
    sections: [AshScim.Dsl.section(type: :user)],
    verifiers: [AshScim.Verifiers.Relationship]
end
