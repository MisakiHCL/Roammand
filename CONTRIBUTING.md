<!-- SPDX-License-Identifier: Apache-2.0 -->

# Contributing to Roammand

Roammand welcomes focused, test-backed contributions that preserve its privacy,
authorization, and local-control boundaries. Small fixes can go directly to a
pull request. For a protocol change, new platform role, privileged operation, or
large user-facing feature, open a [design issue](https://github.com/MisakiHCL/roammand/issues)
first so compatibility and threat-model implications can be agreed before a
large implementation is written.

Suspected vulnerabilities do not belong in a public issue or pull request. Use
the private coordination process in [SECURITY.md](SECURITY.md).

## Repository map

| Area | Responsibility |
| --- | --- |
| `apps/client_flutter/` | Windows/macOS desktop UI and iOS/Android Controller UI |
| `crates/host-agent/` | Host identity, grants, pairing, signaling, and session authorization |
| `crates/host-webrtc/` | Native peer, capture, media, and input-channel lifecycle |
| `crates/host-platform/`, `crates/privileged-bridge/`, `crates/ipc/` | OS boundaries, installed bridge/helper runtime, and authenticated local transport |
| `services/signaling/` | Bounded in-memory WebSocket routing service |
| `schema/`, `gen/`, `conformance/` | Versioned protocol source, generated libraries, and cross-language vectors |
| `infra/`, `packaging/`, `scripts/` | Self-hosting, platform packaging, release checks, and developer workflows |
| `docs/`, `README*.md` | Public product, architecture, security, operations, and verification contracts |

Start with the [architecture index](docs/architecture/README.md) and the guide
for the component you plan to change. User-visible release notes belong in the
[changelog](CHANGELOG.md) under **Unreleased** and move to a dated version only
when that version is tagged.

## Set up the workspace

The repository pins Flutter, Go, Rust, and Buf versions. From the repository
root:

```bash
make bootstrap
make app-check
```

`make bootstrap` validates required tools and resolves locked dependencies; it
does not install operating-system packages or signing credentials. Platform
prerequisites, source-run commands, and package workflows are documented in
[Building Roammand from source](docs/BUILDING.md).

## Change requirements

- Add or update tests whenever behavior changes. Keep target-system claims
  separate from deterministic unit, simulator, or packaging evidence.
- Treat every network frame, IPC frame, file, environment value, QR value, and
  platform callback as untrusted. Validate type, state, size, count, lifetime,
  and authorization before use.
- Keep user-visible Flutter text in `lib/l10n/app_en.arb` and
  `lib/l10n/app_zh.arb`; update both languages and regenerate committed
  localization output.
- Give every connection, media track, stream subscription, timer, capture task,
  renderer, temporary secret, and pressed-input state an explicit cleanup path.
- For local persistence, document the cache/storage key, size bound, corruption
  behavior, update lifecycle, account/device isolation, and uninstall behavior.
- Prefer explicit types and narrow interfaces. Avoid `dynamic`/`any`-style escape
  hatches unless the external boundary requires them and validation immediately
  narrows the value.
- Split a very large authored file when a component, state machine, protocol
  adapter, or platform implementation gains a clearer ownership boundary; do
  not split only to satisfy a line count.
- Add the applicable SPDX identifier to new authored files. Do not copy code,
  media, fonts, word lists, or icons whose license and notice obligations are
  unknown or incompatible.

## Protocol and generated code

Edit the versioned Protobuf source under `schema/proto`, not committed generated
files by hand. Protocol V1 changes must remain wire compatible unless a new
versioned package has been agreed.

```bash
make generate
make generate-check
make schema-breaking
make test-conformance
```

Update cross-language Golden Vectors whenever a canonical transcript or
cryptographic interoperability contract changes. Never weaken a validator only
to make a new vector pass.

## Verification

Before opening a pull request, run the smallest relevant checks while iterating,
then the repository gate appropriate to the change:

```bash
make format-check
make test
make test-product
```

Documentation-only changes should at minimum run:

```bash
./scripts/check_readme_contract.sh
./scripts/check_public_boundary.sh
```

Changes to capture, input, OS permissions, installation, UAC/LoginWindow,
camera behavior, backgrounding, or real network traversal also require named
target-device evidence. Use the [testing and verification guide](docs/TESTING.md)
and record what was actually run; leave untested matrix cells unclaimed.

## Pull request checklist

- Explain the user-visible outcome, security/privacy effect, and compatibility
  effect—not only the files changed.
- Link the issue or architecture decision for large or boundary-changing work.
- Include tests and target-system evidence appropriate to the risk.
- Update English and Simplified Chinese entry documentation together when their
  shared product facts change.
- Add a concise changelog entry for a user-visible, compatibility, security,
  operations, or packaging change; omit routine refactoring and test-only work.
- Keep generated output in the same commit as its schema or localization source.
- Confirm that the diff contains no credentials, private keys, pairing material,
  device identifiers, SDP, ICE candidates, typed text, pointer coordinates,
  private diagnostics, signing identities, or operator-specific paths.
- Keep the pull request focused; separate unrelated refactoring or dependency
  upgrades so each change can be reviewed and reverted independently.

## Licensing and dependencies

Contributions are accepted under the license that applies to the destination
path; see [LICENSES.md](LICENSES.md). A dependency change must update its exact
lockfile and identify every direct and transitive license/notice obligation that
affects a distributed app, package, container, generated file, or bundled asset.

`LICENSES.md` is a licensing overview, not a generated, exhaustive third-party
notice report. Before a release, produce and review a complete notice inventory
and software bill of materials from the exact locked dependency graph and
shipped artifacts. Missing notices or an unresolved license must block that
distribution rather than be documented after publication.
