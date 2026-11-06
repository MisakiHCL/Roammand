// SPDX-License-Identifier: MPL-2.0

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:roammand/identity/device_display_name.dart';
import 'package:roammand/identity/device_identity_copy.dart';
import 'package:roammand/pairing/controller_pairing_identity.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

const mobileIdentitySeedBytes = 32;

final class MobileDeviceIdentity implements ControllerPairingIdentity {
  MobileDeviceIdentity._(this._identity, this._keyPair, this._algorithm);

  final DeviceIdentity _identity;
  final KeyPair _keyPair;
  final Ed25519 _algorithm;

  static Future<MobileDeviceIdentity> fromSeed({
    required List<int> seed,
    required String displayName,
    required DevicePlatform platform,
  }) async {
    if (seed.length != mobileIdentitySeedBytes ||
        seed.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError.value(seed, 'seed', 'Invalid Ed25519 seed');
    }
    final confirmedName = validateConfirmedDeviceName(displayName);
    if (platform != DevicePlatform.DEVICE_PLATFORM_IOS &&
        platform != DevicePlatform.DEVICE_PLATFORM_ANDROID) {
      throw ArgumentError.value(platform, 'platform', 'Not a mobile platform');
    }
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    final identity = DeviceIdentity(
      deviceId: deriveDeviceIdV1(publicKey.bytes),
      publicKeyAlgorithm: PublicKeyAlgorithm.PUBLIC_KEY_ALGORITHM_ED25519,
      publicKey: publicKey.bytes,
      displayName: confirmedName,
      platform: platform,
    );
    return MobileDeviceIdentity._(identity, keyPair, algorithm);
  }

  @override
  DeviceIdentity get publicIdentity => copyDeviceIdentity(_identity);

  @override
  Future<Uint8List> sign(List<int> message) async {
    final signature = await _algorithm.sign(message, keyPair: _keyPair);
    return Uint8List.fromList(signature.bytes);
  }

  @override
  String toString() => 'MobileDeviceIdentity([REDACTED])';
}

String validateConfirmedDeviceName(String value) {
  return requireDeviceDisplayName(value);
}

String? normalizeDeviceName(String? value) => normalizeDeviceDisplayName(value);
