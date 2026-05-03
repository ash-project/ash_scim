# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Test.AuthExample.Secrets do
  @moduledoc false

  use AshAuthentication.Secret

  @impl true
  def secret_for([:authentication, :tokens, :signing_secret], _resource, _opts, _context),
    do: {:ok, "test-secret-test-secret-test-secret-test-secret"}
end
