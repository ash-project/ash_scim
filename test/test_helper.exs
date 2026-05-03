# SPDX-FileCopyrightText: 2026 Zach Daniel
#
# SPDX-License-Identifier: MIT

# Register the auth-example domain under a test OTP app so
# `AshAuthentication.authenticated_resources/1` can resolve it.
Application.put_env(:ash_scim_test, :ash_domains, [AshScim.Test.AuthExample.Domain])

ExUnit.start()
