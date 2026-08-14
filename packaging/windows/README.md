<!-- SPDX-License-Identifier: Apache-2.0 -->

# Windows privileged Host package

> Installing system components requires administrator approval. Validate the
> complete protected-desktop behavior on the target Windows version before use.

The staged package contains the Flutter application, current-user Host Agent,
LocalSystem bridge service, desktop Helper, licenses, a fixed service descriptor,
and a sorted SHA-256 manifest.

Installation requires explicit administrator consent. Program files are placed
under `C:\Program Files\Roammand`; the install-only secret and manifest are
placed under `C:\ProgramData\Roammand` with a
restricted ACL. The service is automatic, non-interactive, and configured with
a restart recovery policy.

Run the install and uninstall scripts with `-WhatIf` first. Uninstall removes
program and service data while preserving each user's device identity and
Controller grants.

```powershell
pwsh -NoProfile -File scripts/package_windows.ps1
pwsh -NoProfile -File scripts/check_windows_package.ps1
pwsh -NoProfile -File scripts/install_windows.ps1 -WhatIf
pwsh -NoProfile -File scripts/install_windows.ps1
pwsh -NoProfile -File scripts/uninstall_windows.ps1 -WhatIf
```
