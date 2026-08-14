<!-- SPDX-License-Identifier: Apache-2.0 -->

# macOS privileged Host package

> Installing system components requires administrator approval. Validate the
> complete protected-session behavior on the target macOS version before use.

The staged package contains the Universal Flutter application, Universal
current-user Host Agent, root bridge daemon, Aqua/LoginWindow session agent,
fixed launchd definitions, licenses, a protected uninstaller, and a sorted
SHA-256 manifest.

Installation requires explicit administrator consent. It installs only under
`/Applications`, `/Library/PrivilegedHelperTools`, `/Library/LaunchDaemons`,
`/Library/LaunchAgents`, and `/Library/Application Support/Roammand`.
The installed GUI exposes the protected uninstaller under **Settings → Advanced**.
It removes the program, device identity, Controller grants, saved Hosts,
preferences, caches, and Roammand-specific Screen Recording and Accessibility
decisions. It never resets another app's privacy decisions. The repository
script remains the terminal fallback and supports `--dry-run`.

Use the repository scripts to stage, verify, install, or uninstall. Run the
install and uninstall scripts with `--dry-run` first to inspect every action.

```bash
make package-macos
sudo ./scripts/install_macos.sh --dry-run
sudo ./scripts/install_macos.sh
sudo ./scripts/uninstall_macos.sh --dry-run
```

Direct website distribution uses `make package-macos-signed` to sign all code
with Developer ID Application and Hardened Runtime, regenerate the manifest,
and create a Developer ID Installer-signed `dist/apple-release/Roammand.pkg`.
`make release-macos` submits that package with the configured notarytool
Keychain profile, staples the accepted ticket, and performs Gatekeeper
assessment. See [BUILDING.md](../../docs/BUILDING.md) for the privacy-safe
credential and release workflow.

## Release compliance artifacts

Every published macOS version must provide all of the following from the exact
final `.pkg` and its resolved dependency graph:

- `SBOM.spdx.json`, an artifact-level SPDX 2.3 SBOM;
- `THIRD_PARTY_NOTICES.md`, with every required license, notice, and
  attribution; and
- `SOURCE_CODE.md`, with the exact public release tag and immutable commit.

Attach these files to the GitHub Release or link to a stable public location
from that release. The sorted SHA-256 install manifest verifies package
integrity; it is not an SBOM or a third-party notice inventory. Missing or
invalid compliance material blocks publication of that macOS version. The
package gate validates the complete record set, and CI additionally validates
the SPDX document with pinned `spdx-tools` 0.8.5.

`make package-macos` places all three files under
`Library/Application Support/Roammand/licenses` before producing the install
manifest. The Developer ID signing workflow regenerates them after signing and
before the final manifest, so the SPDX file inventory describes the signed
payload. Set `ROAMMAND_MACOS_SOURCE_URL` only when a release tag URL should
replace the default immutable commit URL; keep
`ROAMMAND_MACOS_SOURCE_REVISION` pinned to the corresponding full commit.
The records use their actual UTC generation time by default. A controlled
reproducible build may set `SOURCE_DATE_EPOCH` explicitly.

For an already signed and notarized package, generate the same files from its
expanded payload and attach them to the GitHub Release. Do not insert files
into that existing package: changing its payload invalidates its signatures
and requires rebuilding, signing, and notarizing it again.

iOS and signaling/server releases require their own artifact-level compliance
materials and review. Do not reuse the macOS SBOM or notices as evidence for
those independently shipped artifacts.
