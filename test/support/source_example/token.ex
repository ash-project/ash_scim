# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Test.SourceExample.Token do
  @moduledoc false

  use Ash.Resource,
    domain: AshScim.Test.SourceExample.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshAuthentication.TokenResource]

  token do
    domain AshScim.Test.SourceExample.Domain
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
