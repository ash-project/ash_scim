# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

defmodule AshScim.Test.PolicyExample.Domain do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshScim.Test.PolicyExample.User
  end
end
