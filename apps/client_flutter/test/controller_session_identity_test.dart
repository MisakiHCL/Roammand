// SPDX-License-Identifier: MPL-2.0

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roammand/controller/session/controller_session_identity.dart';
import 'package:roammand/desktop/host_agent/host_agent_models.dart';
import 'package:roammand/desktop/remote/host_agent_controller_session_identity.dart';
import 'package:roammand/mobile/identity/mobile_device_identity.dart';
import 'package:roammand/mobile/remote/mobile_controller_session_identity.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

void main() {
  test(
    'mobile session identity signs locally and closes idempotently',
    () async {
      final identity = await MobileDeviceIdentity.fromSeed(
        seed: List<int>.generate(32, (index) => index),
        displayName: 'Phone',
        platform: DevicePlatform.DEVICE_PLATFORM_IOS,
      );
      final adapter = MobileControllerSessionIdentity(identity);
      final transcript = Uint8List.fromList(<int>[1, 3, 3, 7]);

      final opened = await adapter.open();
      final signature = await adapter.signOffer(transcript);
      await adapter.close();
      await adapter.close();

      expect(opened, identity.publicIdentity);
      expect(signature, hasLength(signatureBytes));
      expect(
        await Ed25519().verify(
          transcript,
          signature: Signature(
            signature,
            publicKey: SimplePublicKey(
              opened.publicKey,
              type: KeyPairType.ed25519,
            ),
          ),
        ),
        isTrue,
      );
    },
  );

  test('Host Agent session identity validates every signed field', () async {
    final keyPair = await Ed25519().newKeyPairFromSeed(
      List<int>.filled(32, 0x31),
    );
    final publicKey = await keyPair.extractPublicKey();
    final identity = DeviceIdentity(
      deviceId: deriveDeviceIdV1(publicKey.bytes),
      publicKeyAlgorithm: PublicKeyAlgorithm.PUBLIC_KEY_ALGORITHM_ED25519,
      publicKey: publicKey.bytes,
      displayName: 'Controller',
      platform: DevicePlatform.DEVICE_PLATFORM_MACOS,
    );
    final transcript = Uint8List.fromList(<int>[9, 8, 7, 6]);
    final validSignature = await Ed25519().sign(transcript, keyPair: keyPair);

    for (final mutation in _SignatureMutation.values) {
      final port = _FakeSessionIdentityPort(
        identity,
        (bytes) async => _signedResponse(
          identity: identity,
          transcript: bytes,
          signature: validSignature.bytes,
          mutation: mutation,
        ),
      );
      final adapter = HostAgentControllerSessionIdentity(port);
      final opened = await adapter.open();
      expect(opened, identity);
      opened
        ..publicKey[0] ^= 0xff
        ..deviceId[0] ^= 0xff;

      if (mutation == _SignatureMutation.none) {
        expect(await adapter.signOffer(transcript), validSignature.bytes);
      } else {
        await expectLater(
          adapter.signOffer(transcript),
          throwsA(isA<ControllerSessionIdentityException>()),
          reason: mutation.name,
        );
      }
      await adapter.close();
      await adapter.close();
      expect(port.connectCount, 1);
      expect(port.closeCount, 1);
    }
  });
}

enum _SignatureMutation { none, deviceId, publicKey, hash, length, signature }

SessionOfferSignature _signedResponse({
  required DeviceIdentity identity,
  required List<int> transcript,
  required List<int> signature,
  required _SignatureMutation mutation,
}) {
  final response = SessionOfferSignature(
    controllerDeviceId: identity.deviceId,
    controllerPublicKey: identity.publicKey,
    transcriptSha256: sha256.convert(transcript).bytes,
    signature: signature,
  );
  switch (mutation) {
    case _SignatureMutation.none:
      break;
    case _SignatureMutation.deviceId:
      response.controllerDeviceId = _flipFirst(response.controllerDeviceId);
    case _SignatureMutation.publicKey:
      response.controllerPublicKey = _flipFirst(response.controllerPublicKey);
    case _SignatureMutation.hash:
      response.transcriptSha256 = _flipFirst(response.transcriptSha256);
    case _SignatureMutation.length:
      response.signature = response.signature.sublist(
        0,
        response.signature.length - 1,
      );
    case _SignatureMutation.signature:
      response.signature = _flipFirst(response.signature);
  }
  return response;
}

List<int> _flipFirst(List<int> value) => <int>[
  value.first ^ 0xff,
  ...value.skip(1),
];

final class _FakeSessionIdentityPort implements HostAgentSessionIdentityPort {
  _FakeSessionIdentityPort(this.identity, this.signer);

  final DeviceIdentity identity;
  final Future<SessionOfferSignature> Function(List<int>) signer;
  int connectCount = 0;
  int closeCount = 0;

  @override
  Future<void> connect() async {
    connectCount += 1;
  }

  @override
  Future<HostStatus> getHostStatus() async => HostStatus(identity: identity);

  @override
  Future<SessionOfferSignature> signSessionOffer(
    List<int> canonicalTranscript,
  ) => signer(canonicalTranscript);

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}
