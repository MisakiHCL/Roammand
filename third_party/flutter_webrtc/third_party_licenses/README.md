<!-- SPDX-License-Identifier: Apache-2.0 -->

# Supplemental license provenance

The `flutter_webrtc` 1.5.2 pub archive omits license files referenced by some
of its bundled production source headers. These files preserve the missing
terms without representing them as content from the original pub archive:

- `LICENSE-FLUTTER` is the Flutter BSD-style license from Flutter 3.44.0,
  revision `559ffa3f75e7402d65a8def9c28389a9b2e6fe42`. Its SHA-256 is
  `a598db94b6290ffbe10b5ecf911057b6a943351c727fdda9e5f2891d68700a20`.
- `LICENSE-WEBRTC` and `NOTICE-WEBRTC-PATENTS` are from the official WebRTC
  `refs/branch-heads/7559` source branch corresponding to the locked
  WebRTC-SDK 144.7559.09 line. Their SHA-256 values are
  `ab00a482b6a3902e40211b43c5d0441962ea99b6cc7c25c0f243fa270b78d482`
  and `01462e2068d1a04c2274f3389773014c14ed9bc3446b28303543bd3e3c064145`,
  respectively. The WebRTC license also matches the `LICENSE` embedded in the
  resolved WebRTC-SDK XCFramework byte-for-byte.

Pinned upstream sources:

- <https://github.com/flutter/flutter/blob/559ffa3f75e7402d65a8def9c28389a9b2e6fe42/LICENSE>
- <https://webrtc.googlesource.com/src/+/refs/branch-heads/7559/LICENSE>
- <https://webrtc.googlesource.com/src/+/refs/branch-heads/7559/PATENTS>

The package also retains its original root `LICENSE` and `NOTICE`, plus
`third_party/svpng/LICENSE` from the upstream pub archive.
