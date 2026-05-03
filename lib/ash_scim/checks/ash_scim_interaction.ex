# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Checks.AshScimInteraction do
  @moduledoc """
  Returns `true` when the changeset/query has `context.private.ash_scim?`
  set, which `AshScim.Router` does for every internal Ash call.

  Add a bypass for this check on any resource exposed via SCIM so the
  router's internal queries (read, get, create, update, destroy, load,
  bulk_destroy) aren't blocked by your application's user-facing policies:

      policies do
        bypass AshScim.Checks.AshScimInteraction do
          authorize_if always()
        end

        # ...your normal policies...
      end

  This mirrors the
  `AshAuthentication.Checks.AshAuthenticationInteraction` pattern and serves
  the same purpose: keep user-facing policies in charge of user-facing
  actions, while letting the extension's plumbing run unimpeded.
  """

  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(_), do: "AshScim is performing this interaction"

  @impl Ash.Policy.SimpleCheck
  def match?(_, %{subject: %{context: %{private: %{ash_scim?: true}}}}, _), do: true
  def match?(_, _, _), do: false
end
