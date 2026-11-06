// SPDX-License-Identifier: MPL-2.0

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roammand/desktop/remote/session_authenticator.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

const _nowUnixMs = 1900000000000;
const _answerSdp = 'v=0\r\na=fingerprint:sha-256 CC:DD\r\n';

void main() {
  test('verifies a Host answer bound to the signed Controller offer', () async {
    final fixture = await _Fixture.create();
    final answer = await fixture.signedAnswer();

    final verified = await fixture.verifier.verify(
      offer: fixture.offer,
      answer: answer,
      answerSdp: _answerSdp,
      hostDtlsFingerprintSha256: fixture.hostFingerprint,
      nowUnixMs: _nowUnixMs,
    );

    expect(verified.sessionId, fixture.offer.sessionId);
    expect(verified.hostIdentity.deviceId, fixture.hostIdentity.deviceId);
    expect(verified.permissions, <SessionPermission>[
      SessionPermission.SESSION_PERMISSION_VIEW_SCREEN,
      SessionPermission.SESSION_PERMISSION_CONTROL_INPUT,
    ]);
  });

  test('rejects every mismatched or invalid answer binding', () async {
    for (final failure in _Failure.values) {
      final fixture = await _Fixture.create();
      final answer = await fixture.signedAnswer();
      var answerSdp = _answerSdp;
      var fingerprint = fixture.hostFingerprint;
      var nowUnixMs = _nowUnixMs;
      switch (failure) {
        case _Failure.invalidSignature:
          answer.signature[0] ^= 0xff;
        case _Failure.hostMismatch:
          answer.hostDeviceId = List<int>.filled(32, 0x99);
          await fixture.resign(answer);
        case _Failure.answerHashMismatch:
          answerSdp = 'v=0\r\nchanged\r\n';
        case _Failure.fingerprintMismatch:
          fingerprint = List<int>.filled(32, 0x55);
        case _Failure.nonceMismatch:
          answer.nonce = List<int>.filled(32, 0x56);
          await fixture.resign(answer);
        case _Failure.permissionMismatch:
          answer.requestedPermissions.removeLast();
          await fixture.resign(answer);
        case _Failure.expired:
          nowUnixMs = answer.expiresAtUnixMs.toInt() + 1;
      }

      await expectLater(
        fixture.verifier.verify(
          offer: fixture.offer,
          answer: answer,
          answerSdp: answerSdp,
          hostDtlsFingerprintSha256: fingerprint,
          nowUnixMs: nowUnixMs,
        ),
        throwsA(
          isA<SessionAnswerAuthenticationException>().having(
            (error) => error.code,
            'code',
            failure.expected,
          ),
        ),
        reason: failure.name,
      );
    }
  });

  test(
    'answer verification owns its expected and exported Host identity',
    () async {
      final fixture = await _Fixture.create();
      final offer = SessionOfferAuthentication.fromBuffer(
        fixture.offer.writeToBuffer(),
      );
      final answer = SessionAnswerAuthentication.fromBuffer(
        (await fixture.signedAnswer()).writeToBuffer(),
      );
      final originalBytes = fixture.hostIdentity.writeToBuffer();
      final verifier = fixture.verifier;
      fixture.hostIdentity
        ..publicKey[0] ^= 0xff
        ..deviceId[0] ^= 0xff;

      Future<VerifiedSessionAnswer> verify() => verifier.verify(
        offer: offer,
        answer: answer,
        answerSdp: _answerSdp,
        hostDtlsFingerprintSha256: fixture.hostFingerprint,
        nowUnixMs: _nowUnixMs,
      );
      final verified = await verify();
      expect(verified.hostIdentity.writeToBuffer(), originalBytes);
      verified.hostIdentity
        ..publicKey[0] ^= 0xff
        ..deviceId[0] ^= 0xff;
      expect((await verify()).hostIdentity.writeToBuffer(), originalBytes);
    },
  );

  test(
    'reconnect verification owns its expected Host identity bytes',
    () async {
      final fixture = await _Fixture.create();
      final offer = SessionOfferAuthentication.fromBuffer(
        fixture.offer.writeToBuffer(),
      );
      final reconnect = SessionReconnectAuthentication.fromBuffer(
        (await fixture.signedReconnect()).writeToBuffer(),
      );
      fixture.hostIdentity
        ..publicKey[0] ^= 0xff
        ..deviceId[0] ^= 0xff;

      final verified = await fixture.reconnectVerifier.verify(
        offer: offer,
        reconnect: reconnect,
        answerSdp: _answerSdp,
        hostDtlsFingerprintSha256: fixture.hostFingerprint,
        previousGeneration: 6,
        nowUnixMs: _nowUnixMs,
      );
      expect(verified.generation, 7);
    },
  );

  test(
    'verifies a signed reconnect bound to the fresh Controller offer',
    () async {
      final fixture = await _Fixture.create();
      final reconnect = await fixture.signedReconnect();

      final verified = await fixture.reconnectVerifier.verify(
        offer: fixture.offer,
        reconnect: reconnect,
        answerSdp: _answerSdp,
        hostDtlsFingerprintSha256: fixture.hostFingerprint,
        previousGeneration: 6,
        nowUnixMs: _nowUnixMs,
      );

      expect(verified.sessionId, fixture.offer.sessionId);
      expect(verified.generation, 7);
      expect(verified.permissions, <SessionPermission>[
        SessionPermission.SESSION_PERMISSION_VIEW_SCREEN,
        SessionPermission.SESSION_PERMISSION_CONTROL_INPUT,
      ]);
    },
  );

  test(
    'accepts a signed reconnect generation newer than a lost response',
    () async {
      final fixture = await _Fixture.create();
      final reconnect = await fixture.signedReconnect();
      reconnect.reconnectGeneration = 9;
      await fixture.resignReconnect(reconnect);

      final verified = await fixture.reconnectVerifier.verify(
        offer: fixture.offer,
        reconnect: reconnect,
        answerSdp: _answerSdp,
        hostDtlsFingerprintSha256: fixture.hostFingerprint,
        previousGeneration: 6,
        nowUnixMs: _nowUnixMs,
      );

      expect(verified.generation, 9);
    },
  );

  test('rejects every mismatched reconnect binding and generation', () async {
    for (final failure in _ReconnectFailure.values) {
      final fixture = await _Fixture.create();
      final reconnect = await fixture.signedReconnect();
      var answerSdp = _answerSdp;
      var hostFingerprint = fixture.hostFingerprint;
      var nowUnixMs = _nowUnixMs;
      switch (failure) {
        case _ReconnectFailure.invalidSignature:
          reconnect.signature[0] ^= 0xff;
        case _ReconnectFailure.hostMismatch:
          reconnect.hostDeviceId = List<int>.filled(32, 0x91);
          await fixture.resignReconnect(reconnect);
        case _ReconnectFailure.controllerMismatch:
          reconnect.controllerDeviceId = List<int>.filled(32, 0x92);
          await fixture.resignReconnect(reconnect);
        case _ReconnectFailure.sessionMismatch:
          reconnect.sessionId = List<int>.filled(16, 0x93);
          await fixture.resignReconnect(reconnect);
        case _ReconnectFailure.nonceMismatch:
          reconnect.nonce = List<int>.filled(32, 0x94);
          await fixture.resignReconnect(reconnect);
        case _ReconnectFailure.offerHashMismatch:
          reconnect.offerSha256 = List<int>.filled(32, 0x95);
          await fixture.resignReconnect(reconnect);
        case _ReconnectFailure.controllerFingerprintMismatch:
          reconnect.controllerDtlsFingerprintSha256 = List<int>.filled(
            32,
            0x96,
          );
          await fixture.resignReconnect(reconnect);
        case _ReconnectFailure.answerHashMismatch:
          answerSdp = 'v=0\r\nchanged\r\n';
        case _ReconnectFailure.hostFingerprintMismatch:
          hostFingerprint = List<int>.filled(32, 0x97);
        case _ReconnectFailure.permissionMismatch:
          reconnect.requestedPermissions.removeLast();
          await fixture.resignReconnect(reconnect);
        case _ReconnectFailure.expired:
          nowUnixMs = reconnect.expiresAtUnixMs.toInt() + 1;
        case _ReconnectFailure.generationMismatch:
          reconnect.reconnectGeneration = 6;
          await fixture.resignReconnect(reconnect);
      }

      await expectLater(
        fixture.reconnectVerifier.verify(
          offer: fixture.offer,
          reconnect: reconnect,
          answerSdp: answerSdp,
          hostDtlsFingerprintSha256: hostFingerprint,
          previousGeneration: 6,
          nowUnixMs: nowUnixMs,
        ),
        throwsA(
          isA<SessionReconnectAuthenticationException>().having(
            (error) => error.code,
            'code',
            failure.expected,
          ),
        ),
        reason: failure.name,
      );
    }
  });

  test('bounds ICE candidates until answer authentication succeeds', () {
    final pending = PendingIceCandidates(maxCandidates: 2, maxBytes: 16);
    pending.add(IceCandidate(candidate: '1234', sdpMid: '0'));
    pending.add(IceCandidate(candidate: '5678', sdpMid: '0'));

    expect(
      () => pending.add(IceCandidate(candidate: '9', sdpMid: '0')),
      throwsA(isA<PendingIceLimitException>()),
    );
    expect(pending.drain(), hasLength(2));
    expect(pending.drain(), isEmpty);
  });
}

enum _Failure {
  invalidSignature(SessionAnswerAuthenticationErrorCode.invalidSignature),
  hostMismatch(SessionAnswerAuthenticationErrorCode.hostMismatch),
  answerHashMismatch(SessionAnswerAuthenticationErrorCode.answerHashMismatch),
  fingerprintMismatch(SessionAnswerAuthenticationErrorCode.fingerprintMismatch),
  nonceMismatch(SessionAnswerAuthenticationErrorCode.offerBindingMismatch),
  permissionMismatch(SessionAnswerAuthenticationErrorCode.offerBindingMismatch),
  expired(SessionAnswerAuthenticationErrorCode.expired);

  const _Failure(this.expected);

  final SessionAnswerAuthenticationErrorCode expected;
}

enum _ReconnectFailure {
  invalidSignature(SessionReconnectAuthenticationErrorCode.invalidSignature),
  hostMismatch(SessionReconnectAuthenticationErrorCode.hostMismatch),
  controllerMismatch(
    SessionReconnectAuthenticationErrorCode.offerBindingMismatch,
  ),
  sessionMismatch(SessionReconnectAuthenticationErrorCode.offerBindingMismatch),
  nonceMismatch(SessionReconnectAuthenticationErrorCode.offerBindingMismatch),
  offerHashMismatch(
    SessionReconnectAuthenticationErrorCode.offerBindingMismatch,
  ),
  controllerFingerprintMismatch(
    SessionReconnectAuthenticationErrorCode.offerBindingMismatch,
  ),
  answerHashMismatch(
    SessionReconnectAuthenticationErrorCode.answerHashMismatch,
  ),
  hostFingerprintMismatch(
    SessionReconnectAuthenticationErrorCode.fingerprintMismatch,
  ),
  permissionMismatch(
    SessionReconnectAuthenticationErrorCode.offerBindingMismatch,
  ),
  expired(SessionReconnectAuthenticationErrorCode.expired),
  generationMismatch(
    SessionReconnectAuthenticationErrorCode.generationMismatch,
  );

  const _ReconnectFailure(this.expected);

  final SessionReconnectAuthenticationErrorCode expected;
}

final class _Fixture {
  const _Fixture({
    required this.hostKeyPair,
    required this.hostIdentity,
    required this.offer,
    required this.hostFingerprint,
    required this.verifier,
    required this.reconnectVerifier,
  });

  final SimpleKeyPair hostKeyPair;
  final DeviceIdentity hostIdentity;
  final SessionOfferAuthentication offer;
  final List<int> hostFingerprint;
  final SessionAnswerVerifier verifier;
  final SessionReconnectVerifier reconnectVerifier;

  static Future<_Fixture> create() async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(
      List<int>.filled(32, 0x42),
    );
    final publicKey = await keyPair.extractPublicKey();
    final hostIdentity = DeviceIdentity(
      deviceId: deriveDeviceIdV1(publicKey.bytes),
      publicKeyAlgorithm: PublicKeyAlgorithm.PUBLIC_KEY_ALGORITHM_ED25519,
      publicKey: publicKey.bytes,
      displayName: 'Host',
      platform: DevicePlatform.DEVICE_PLATFORM_MACOS,
    );
    final offer = SessionOfferAuthentication(
      controllerDeviceId: List<int>.filled(32, 0x31),
      hostDeviceId: hostIdentity.deviceId,
      sessionId: List<int>.filled(16, 0x71),
      nonce: List<int>.filled(32, 0x72),
      issuedAtUnixMs: Int64(_nowUnixMs - 5000),
      expiresAtUnixMs: Int64(_nowUnixMs + 5000),
      requestedPermissions: <SessionPermission>[
        SessionPermission.SESSION_PERMISSION_VIEW_SCREEN,
        SessionPermission.SESSION_PERMISSION_CONTROL_INPUT,
      ],
      offerSha256: List<int>.filled(32, 0x73),
      controllerDtlsFingerprintSha256: List<int>.filled(32, 0x74),
      signature: List<int>.filled(64, 0x75),
    );
    final hostFingerprint = List<int>.filled(32, 0x76);
    return _Fixture(
      hostKeyPair: keyPair,
      hostIdentity: hostIdentity,
      offer: offer,
      hostFingerprint: hostFingerprint,
      verifier: SessionAnswerVerifier(expectedHost: hostIdentity),
      reconnectVerifier: SessionReconnectVerifier(expectedHost: hostIdentity),
    );
  }

  Future<SessionAnswerAuthentication> signedAnswer() async {
    final answer = SessionAnswerAuthentication(
      controllerDeviceId: offer.controllerDeviceId,
      hostDeviceId: offer.hostDeviceId,
      sessionId: offer.sessionId,
      nonce: offer.nonce,
      issuedAtUnixMs: offer.issuedAtUnixMs,
      expiresAtUnixMs: offer.expiresAtUnixMs,
      requestedPermissions: offer.requestedPermissions,
      offerSha256: offer.offerSha256,
      controllerDtlsFingerprintSha256: offer.controllerDtlsFingerprintSha256,
      answerSha256: sha256.convert(_answerSdp.codeUnits).bytes,
      hostDtlsFingerprintSha256: hostFingerprint,
    );
    await resign(answer);
    return answer;
  }

  Future<void> resign(SessionAnswerAuthentication answer) async {
    final signature = await Ed25519().sign(
      encodeSessionAnswerTranscript(answer),
      keyPair: hostKeyPair,
    );
    answer.signature = signature.bytes;
  }

  Future<SessionReconnectAuthentication> signedReconnect() async {
    final reconnect = SessionReconnectAuthentication(
      controllerDeviceId: offer.controllerDeviceId,
      hostDeviceId: offer.hostDeviceId,
      sessionId: offer.sessionId,
      nonce: offer.nonce,
      issuedAtUnixMs: offer.issuedAtUnixMs,
      expiresAtUnixMs: offer.expiresAtUnixMs,
      requestedPermissions: offer.requestedPermissions,
      offerSha256: offer.offerSha256,
      controllerDtlsFingerprintSha256: offer.controllerDtlsFingerprintSha256,
      answerSha256: sha256.convert(_answerSdp.codeUnits).bytes,
      hostDtlsFingerprintSha256: hostFingerprint,
      reconnectGeneration: 7,
    );
    await resignReconnect(reconnect);
    return reconnect;
  }

  Future<void> resignReconnect(SessionReconnectAuthentication reconnect) async {
    final signature = await Ed25519().sign(
      encodeSessionReconnectTranscript(reconnect),
      keyPair: hostKeyPair,
    );
    reconnect.signature = signature.bytes;
  }
}
