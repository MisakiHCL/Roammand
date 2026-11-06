// SPDX-License-Identifier: MPL-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:roammand/desktop/pairing/desktop_controller_pairing_identity.dart';
import 'package:roammand/desktop/remote/remote_desktop_controller.dart';
import 'package:roammand/identity/device_identity_copy.dart';
import 'package:roammand/pairing/controller_pairing_models.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

void main() {
  test('identity copies detach bytes and preserve unknown protobuf fields', () {
    final identity = DeviceIdentity.fromBuffer(<int>[
      ..._identity().writeToBuffer(),
      0xa0, 0x06, 0x01, // Unknown varint field 100.
    ]);
    final originalBytes = identity.writeToBuffer();
    final copy = copyDeviceIdentity(identity);
    expect(copy.writeToBuffer(), originalBytes);

    _mutate(copy);

    expect(identity.writeToBuffer(), originalBytes);
  });

  final snapshots =
      <String, DeviceIdentity Function() Function(DeviceIdentity)>{
        'desktop pairing': (identity) {
          final adapter = DesktopControllerPairingIdentity(
            identity: identity,
            signTranscript: (_, _) => throw UnimplementedError(),
          );
          return () => adapter.publicIdentity;
        },
        'pairing state': (identity) {
          final snapshot = ControllerPairingSnapshot(
            state: ControllerPairingState.verifyingHost,
            hostIdentity: identity,
          );
          return () => snapshot.hostIdentity!;
        },
        'remote target': (identity) {
          final target = RemoteDesktopTarget(
            hostIdentity: identity,
            signalingEndpoint: Uri.parse('wss://signal.example.test/v1/ws'),
          );
          return () => target.hostIdentity;
        },
      };
  for (final entry in snapshots.entries) {
    test('${entry.key} snapshots own their identity byte fields', () {
      final identity = _identity();
      final originalBytes = identity.writeToBuffer();
      final read = entry.value(identity);

      _mutate(identity);
      expect(read().writeToBuffer(), originalBytes);

      _mutate(read());
      expect(read().writeToBuffer(), originalBytes);
    });
  }
}

DeviceIdentity _identity() {
  final publicKey = List<int>.generate(32, (index) => index + 1);
  return DeviceIdentity(
    deviceId: deriveDeviceIdV1(publicKey),
    publicKeyAlgorithm: PublicKeyAlgorithm.PUBLIC_KEY_ALGORITHM_ED25519,
    publicKey: publicKey,
    displayName: 'Mac',
    platform: DevicePlatform.DEVICE_PLATFORM_MACOS,
  );
}

void _mutate(DeviceIdentity identity) {
  identity
    ..displayName = 'Changed'
    ..publicKey[0] ^= 0xff
    ..deviceId[0] ^= 0xff;
}
