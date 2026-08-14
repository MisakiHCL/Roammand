# SPDX-License-Identifier: Apache-2.0

param(
  [string]$Package = "",
  [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Package)) {
  $Package = Join-Path $Root "dist\windows"
}

if ($WhatIf) {
  & (Join-Path $PSScriptRoot "install_m8_windows.ps1") -Package $Package -WhatIf
} else {
  & (Join-Path $PSScriptRoot "install_m8_windows.ps1") -Package $Package
}
