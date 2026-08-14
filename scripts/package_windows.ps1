# SPDX-License-Identifier: Apache-2.0

param(
  [string]$Output = "",
  [string]$AppDirectory = "",
  [string]$HostAgent = "",
  [string]$Bridge = "",
  [string]$SessionHelper = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Output)) {
  $Output = Join-Path $Root "dist\windows"
}

& (Join-Path $PSScriptRoot "package_m8_windows.ps1") `
  -Output $Output `
  -AppDirectory $AppDirectory `
  -HostAgent $HostAgent `
  -Bridge $Bridge `
  -SessionHelper $SessionHelper
