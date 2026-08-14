# SPDX-License-Identifier: Apache-2.0

param([switch]$WhatIf)

$ErrorActionPreference = "Stop"
if ($WhatIf) {
  & (Join-Path $PSScriptRoot "uninstall_m8_windows.ps1") -WhatIf
} else {
  & (Join-Path $PSScriptRoot "uninstall_m8_windows.ps1")
}
