<!-- SPDX-License-Identifier: Apache-2.0 -->

# Roammand downstream patch

This directory vendors the production sources from `flutter_webrtc` 1.5.2.

- Upstream version: `1.5.2`
- Original pub archive SHA-256:
  `0f89dee7f4c35dab5611f351c3897a3bfe9f7057720cc7da209b52455af4316e`
- Upstream project: <https://github.com/cloudwebrtc/flutter-webrtc>
- Local iOS/macOS podspec version: `1.5.2-roammand.1`

The SHA-256 above identifies the unmodified pub archive used as the source. It
does not identify this modified downstream tree.

The local podspec version distinguishes the patched CocoaPods wrapper in both
Apple lockfiles. It does not change the Dart package's upstream-based `1.5.2`
version.

## Private ReplayKit selector removal

Upstream's Darwin desktop capturer created an `RPSystemBroadcastPickerView` and
invoked its undocumented `buttonPressed:` selector through
`NSSelectorFromString` and `performSelector`. Apple scans statically linked code
even when the application never calls `getDisplayMedia`, so merely linking that
implementation can trigger App Store private-API rejection.

Roammand's iOS client only receives remote video and has no Broadcast Extension.
The automatic picker-presentation code has therefore been removed from all
three upstream copies of `FlutterRTCDesktopCapturer.m` (`ios`, `macos`, and
`common/darwin`). The public/manual capture foundations remain intact:

- ReplayKit in-app capture can still use `FlutterRPScreenRecorder`.
- A caller that supplies a `broadcast` device ID can still use
  `FlutterBroadcastScreenCapturer`, but the plugin no longer attempts to present
  or activate the system broadcast picker through a private selector.

Keep these three source copies synchronized when rebasing this vendored package.

## Supplemental third-party license texts

The upstream pub archive omits license files referenced by some bundled
Flutter and WebRTC source headers. Roammand retains the corresponding license
and patent-grant texts under `third_party_licenses/`; see that directory's
`README.md` for pinned sources and checksums. These supplemental files are not
part of the original pub archive identified above.
