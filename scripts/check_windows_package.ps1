# SPDX-License-Identifier: Apache-2.0

param([string]$Package = "")

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Package)) {
  $Package = Join-Path $Root "dist\windows"
}

& (Join-Path $PSScriptRoot "check_m8_windows_package.ps1") -Package $Package
