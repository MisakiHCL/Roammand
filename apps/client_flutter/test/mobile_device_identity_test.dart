// SPDX-License-Identifier: MPL-2.0

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roammand/mobile/identity/mobile_device_identity.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

void main() {
  test(
    'derives a stable Ed25519 device identity and signs without exposing seed',
    () async {
      final seed = List<int>.generate(
        mobileIdentitySeedBytes,
        (index) => index,
      );
      final identity = await MobileDeviceIdentity.fromSeed(
        seed: seed,
        displayName: 'Alice’s iPhone',
        platform: DevicePlatform.DEVICE_PLATFORM_IOS,
      );
      final expectedKeyPair = await Ed25519().newKeyPairFromSeed(seed);
      final expectedPublicKey = await expectedKeyPair.extractPublicKey();

      expect(identity.publicIdentity.publicKey, expectedPublicKey.bytes);
      expect(
        identity.publicIdentity.deviceId,
        deriveDeviceIdV1(expectedPublicKey.bytes),
      );
      expect(
        identity.publicIdentity.publicKeyAlgorithm,
        PublicKeyAlgorithm.PUBLIC_KEY_ALGORITHM_ED25519,
      );
      expect(identity.publicIdentity.displayName, 'Alice’s iPhone');
      expect(
        identity.publicIdentity.platform,
        DevicePlatform.DEVICE_PLATFORM_IOS,
      );

      final message = utf8.encode('pairing transcript');
      final signature = await identity.sign(message);
      expect(signature, hasLength(64));
      expect(
        await Ed25519().verify(
          message,
          signature: Signature(signature, publicKey: expectedPublicKey),
        ),
        isTrue,
      );

      final originalBytes = identity.publicIdentity.writeToBuffer();
      final mutableCopy = identity.publicIdentity
        ..displayName = 'Changed'
        ..publicKey[0] ^= 0xff
        ..deviceId[0] ^= 0xff;
      expect(mutableCopy.displayName, 'Changed');
      expect(identity.publicIdentity.writeToBuffer(), originalBytes);
      expect(identity.publicIdentity.displayName, 'Alice’s iPhone');
      final deviceIdHex = identity.publicIdentity.deviceId
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(identity.toString(), isNot(contains(deviceIdHex.substring(0, 8))));
      expect(identity.toString(), isNot(contains(base64UrlEncode(seed))));
      expect(identity.toString(), isNot(contains(base64UrlEncode(signature))));
    },
  );

  test(
    'rejects unconfirmed names, wrong seeds, and non-mobile platforms',
    () async {
      for (final name in <String>[
        '',
        '   ',
        List<String>.filled(129, 'x').join(),
      ]) {
        await expectLater(
          MobileDeviceIdentity.fromSeed(
            seed: List<int>.filled(mobileIdentitySeedBytes, 1),
            displayName: name,
            platform: DevicePlatform.DEVICE_PLATFORM_ANDROID,
          ),
          throwsArgumentError,
        );
      }
      await expectLater(
        MobileDeviceIdentity.fromSeed(
          seed: List<int>.filled(mobileIdentitySeedBytes - 1, 1),
          displayName: 'Phone',
          platform: DevicePlatform.DEVICE_PLATFORM_IOS,
        ),
        throwsArgumentError,
      );
      await expectLater(
        MobileDeviceIdentity.fromSeed(
          seed: List<int>.filled(mobileIdentitySeedBytes, 1),
          displayName: 'Phone',
          platform: DevicePlatform.DEVICE_PLATFORM_MACOS,
        ),
        throwsArgumentError,
      );
    },
  );
}
