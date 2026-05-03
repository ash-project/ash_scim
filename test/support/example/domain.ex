# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Test.Example.Domain do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshScim.Test.Example.User
    resource AshScim.Test.Example.Group
    resource AshScim.Test.Example.Membership
  end
end
