// SPDX-License-Identifier: MPL-2.0

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:roammand/identity/device_identity_copy.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

const _deviceIdBytes = 32;
const _sessionIdBytes = 16;
const _hashBytes = 32;
const _signatureBytes = 64;
const _maximumAuthenticationLifetimeMs = 30000;
const _futureClockSkewMs = 10000;
const _defaultMaximumPendingCandidates = 64;
const _defaultMaximumPendingCandidateBytes = 65536;

enum SessionAnswerAuthenticationErrorCode {
  invalidAnswer,
  invalidHostIdentity,
  hostMismatch,
  offerBindingMismatch,
  notYetValid,
  expired,
  lifetimeTooLong,
  invalidPermissions,
  answerHashMismatch,
  fingerprintMismatch,
  invalidSignature,
  invalidTranscript,
}

final class SessionAnswerAuthenticationException implements Exception {
  const SessionAnswerAuthenticationException(this.code);

  final SessionAnswerAuthenticationErrorCode code;

  @override
  String toString() => 'SessionAnswerAuthenticationException(${code.name})';
}

final class VerifiedSessionAnswer {
  VerifiedSessionAnswer({
    required this.hostIdentity,
    required List<int> sessionId,
    required List<SessionPermission> permissions,
  }) : sessionId = Uint8List.fromList(sessionId),
       permissions = List<SessionPermission>.unmodifiable(permissions);

  final DeviceIdentity hostIdentity;
  final Uint8List sessionId;
  final List<SessionPermission> permissions;
}

final class SessionAnswerVerifier {
  SessionAnswerVerifier({required DeviceIdentity expectedHost})
    : _expectedHost = copyDeviceIdentity(expectedHost) {
    if (!_isValidHostIdentity(_expectedHost)) {
      throw const SessionAnswerAuthenticationException(
        SessionAnswerAuthenticationErrorCode.invalidHostIdentity,
      );
    }
  }

  final DeviceIdentity _expectedHost;
  final Ed25519 _algorithm = Ed25519();

  Future<VerifiedSessionAnswer> verify({
    required SessionOfferAuthentication offer,
    required SessionAnswerAuthentication answer,
    required String answerSdp,
    required List<int> hostDtlsFingerprintSha256,
    required int nowUnixMs,
  }) async {
    _validateFixedFields(answer);
    if (!_bytesEqual(answer.hostDeviceId, _expectedHost.deviceId)) {
      _fail(SessionAnswerAuthenticationErrorCode.hostMismatch);
    }
    if (!_answerBindsOffer(answer, offer)) {
      _fail(SessionAnswerAuthenticationErrorCode.offerBindingMismatch);
    }
    final permissions = _normalizePermissions(answer.requestedPermissions);
    _validateTime(answer, nowUnixMs);

    final answerHash = hashes.sha256.convert(utf8.encode(answerSdp)).bytes;
    if (!_bytesEqual(answer.answerSha256, answerHash)) {
      _fail(SessionAnswerAuthenticationErrorCode.answerHashMismatch);
    }
    if (!_bytesEqual(
      answer.hostDtlsFingerprintSha256,
      hostDtlsFingerprintSha256,
    )) {
      _fail(SessionAnswerAuthenticationErrorCode.fingerprintMismatch);
    }

    final transcript = encodeSessionAnswerTranscript(answer);
    final publicKey = SimplePublicKey(
      _expectedHost.publicKey,
      type: KeyPairType.ed25519,
    );
    final valid = await _algorithm.verify(
      transcript,
      signature: Signature(answer.signature, publicKey: publicKey),
    );
    if (!valid) {
      _fail(SessionAnswerAuthenticationErrorCode.invalidSignature);
    }
    return VerifiedSessionAnswer(
      hostIdentity: copyDeviceIdentity(_expectedHost),
      sessionId: answer.sessionId,
      permissions: permissions,
    );
  }
}

enum SessionReconnectAuthenticationErrorCode {
  invalidReconnect,
  invalidHostIdentity,
  hostMismatch,
  offerBindingMismatch,
  notYetValid,
  expired,
  lifetimeTooLong,
  invalidPermissions,
  answerHashMismatch,
  fingerprintMismatch,
  generationMismatch,
  invalidSignature,
  invalidTranscript,
}

final class SessionReconnectAuthenticationException implements Exception {
  const SessionReconnectAuthenticationException(this.code);

  final SessionReconnectAuthenticationErrorCode code;

  @override
  String toString() => 'SessionReconnectAuthenticationException(${code.name})';
}

final class VerifiedSessionReconnect {
  VerifiedSessionReconnect({
    required List<int> sessionId,
    required this.generation,
    required List<SessionPermission> permissions,
  }) : sessionId = Uint8List.fromList(sessionId),
       permissions = List<SessionPermission>.unmodifiable(permissions);

  final Uint8List sessionId;
  final int generation;
  final List<SessionPermission> permissions;
}

final class SessionReconnectVerifier {
  SessionReconnectVerifier({required DeviceIdentity expectedHost})
    : _expectedHost = copyDeviceIdentity(expectedHost) {
    if (!_isValidHostIdentity(_expectedHost)) {
      _failReconnect(
        SessionReconnectAuthenticationErrorCode.invalidHostIdentity,
      );
    }
  }

  final DeviceIdentity _expectedHost;
  final Ed25519 _algorithm = Ed25519();

  Future<VerifiedSessionReconnect> verify({
    required SessionOfferAuthentication offer,
    required SessionReconnectAuthentication reconnect,
    required String answerSdp,
    required List<int> hostDtlsFingerprintSha256,
    required int previousGeneration,
    required int nowUnixMs,
  }) async {
    _validateReconnectFixedFields(reconnect);
    if (!_bytesEqual(reconnect.hostDeviceId, _expectedHost.deviceId)) {
      _failReconnect(SessionReconnectAuthenticationErrorCode.hostMismatch);
    }
    if (!_reconnectBindsOffer(reconnect, offer)) {
      _failReconnect(
        SessionReconnectAuthenticationErrorCode.offerBindingMismatch,
      );
    }
    final permissions = _normalizeReconnectPermissions(
      reconnect.requestedPermissions,
    );
    _validateReconnectTime(reconnect, nowUnixMs);
    if (previousGeneration < 0 ||
        previousGeneration >= 0xffffffff ||
        reconnect.reconnectGeneration <= previousGeneration) {
      _failReconnect(
        SessionReconnectAuthenticationErrorCode.generationMismatch,
      );
    }

    final answerHash = hashes.sha256.convert(utf8.encode(answerSdp)).bytes;
    if (!_bytesEqual(reconnect.answerSha256, answerHash)) {
      _failReconnect(
        SessionReconnectAuthenticationErrorCode.answerHashMismatch,
      );
    }
    if (!_bytesEqual(
      reconnect.hostDtlsFingerprintSha256,
      hostDtlsFingerprintSha256,
    )) {
      _failReconnect(
        SessionReconnectAuthenticationErrorCode.fingerprintMismatch,
      );
    }

    final transcript = encodeSessionReconnectTranscript(reconnect);
    final valid = await _algorithm.verify(
      transcript,
      signature: Signature(
        reconnect.signature,
        publicKey: SimplePublicKey(
          _expectedHost.publicKey,
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!valid) {
      _failReconnect(SessionReconnectAuthenticationErrorCode.invalidSignature);
    }
    return VerifiedSessionReconnect(
      sessionId: reconnect.sessionId,
      generation: reconnect.reconnectGeneration,
      permissions: permissions,
    );
  }
}

Uint8List encodeSessionOfferTranscript(SessionOfferAuthentication offer) {
  try {
    final permissionBits = _permissionBits(offer.requestedPermissions);
    return CanonicalTranscriptV1.encode(
      TranscriptPurpose.sessionOffer,
      <TranscriptField>[
        TranscriptField(1, offer.controllerDeviceId),
        TranscriptField(2, offer.hostDeviceId),
        TranscriptField(8, offer.sessionId),
        TranscriptField(9, offer.nonce),
        TranscriptField(10, _uint64(offer.issuedAtUnixMs.toInt())),
        TranscriptField(11, _uint64(offer.expiresAtUnixMs.toInt())),
        TranscriptField(12, _uint32(permissionBits)),
        TranscriptField(13, offer.offerSha256),
        TranscriptField(14, offer.controllerDtlsFingerprintSha256),
      ],
    );
  } on TranscriptException {
    _fail(SessionAnswerAuthenticationErrorCode.invalidTranscript);
  }
}

Uint8List encodeSessionAnswerTranscript(SessionAnswerAuthentication answer) {
  try {
    final permissionBits = _permissionBits(answer.requestedPermissions);
    return CanonicalTranscriptV1.encode(
      TranscriptPurpose.sessionAnswer,
      <TranscriptField>[
        TranscriptField(1, answer.controllerDeviceId),
        TranscriptField(2, answer.hostDeviceId),
        TranscriptField(8, answer.sessionId),
        TranscriptField(9, answer.nonce),
        TranscriptField(10, _uint64(answer.issuedAtUnixMs.toInt())),
        TranscriptField(11, _uint64(answer.expiresAtUnixMs.toInt())),
        TranscriptField(12, _uint32(permissionBits)),
        TranscriptField(13, answer.offerSha256),
        TranscriptField(14, answer.controllerDtlsFingerprintSha256),
        TranscriptField(15, answer.answerSha256),
        TranscriptField(16, answer.hostDtlsFingerprintSha256),
      ],
    );
  } on TranscriptException {
    _fail(SessionAnswerAuthenticationErrorCode.invalidTranscript);
  }
}

Uint8List encodeSessionReconnectTranscript(
  SessionReconnectAuthentication reconnect,
) {
  try {
    final permissionBits = _reconnectPermissionBits(
      reconnect.requestedPermissions,
    );
    return CanonicalTranscriptV1.encode(
      TranscriptPurpose.sessionReconnect,
      <TranscriptField>[
        TranscriptField(1, reconnect.controllerDeviceId),
        TranscriptField(2, reconnect.hostDeviceId),
        TranscriptField(8, reconnect.sessionId),
        TranscriptField(9, reconnect.nonce),
        TranscriptField(10, _uint64(reconnect.issuedAtUnixMs.toInt())),
        TranscriptField(11, _uint64(reconnect.expiresAtUnixMs.toInt())),
        TranscriptField(12, _uint32(permissionBits)),
        TranscriptField(13, reconnect.offerSha256),
        TranscriptField(14, reconnect.controllerDtlsFingerprintSha256),
        TranscriptField(15, reconnect.answerSha256),
        TranscriptField(16, reconnect.hostDtlsFingerprintSha256),
        TranscriptField(17, _uint32(reconnect.reconnectGeneration)),
      ],
    );
  } on TranscriptException {
    _failReconnect(SessionReconnectAuthenticationErrorCode.invalidTranscript);
  }
}

final class PendingIceLimitException implements Exception {
  const PendingIceLimitException();
}

final class PendingIceCandidates {
  PendingIceCandidates({
    this.maxCandidates = _defaultMaximumPendingCandidates,
    this.maxBytes = _defaultMaximumPendingCandidateBytes,
  }) : assert(maxCandidates > 0),
       assert(maxBytes > 0);

  final int maxCandidates;
  final int maxBytes;
  final List<IceCandidate> _candidates = <IceCandidate>[];
  int _encodedBytes = 0;

  void add(IceCandidate candidate) {
    final candidateBytes = utf8.encode(candidate.candidate).length;
    final midBytes = utf8.encode(candidate.sdpMid).length;
    final nextBytes = _encodedBytes + candidateBytes + midBytes;
    if (_candidates.length >= maxCandidates || nextBytes > maxBytes) {
      throw const PendingIceLimitException();
    }
    _candidates.add(candidate.deepCopy());
    _encodedBytes = nextBytes;
  }

  List<IceCandidate> drain() {
    final drained = List<IceCandidate>.unmodifiable(_candidates);
    _candidates.clear();
    _encodedBytes = 0;
    return drained;
  }
}

void _validateFixedFields(SessionAnswerAuthentication answer) {
  if (answer.controllerDeviceId.length != _deviceIdBytes ||
      answer.hostDeviceId.length != _deviceIdBytes ||
      answer.sessionId.length != _sessionIdBytes ||
      answer.nonce.length != _hashBytes ||
      answer.offerSha256.length != _hashBytes ||
      answer.controllerDtlsFingerprintSha256.length != _hashBytes ||
      answer.answerSha256.length != _hashBytes ||
      answer.hostDtlsFingerprintSha256.length != _hashBytes ||
      answer.signature.length != _signatureBytes) {
    _fail(SessionAnswerAuthenticationErrorCode.invalidAnswer);
  }
}

void _validateReconnectFixedFields(SessionReconnectAuthentication reconnect) {
  if (reconnect.controllerDeviceId.length != _deviceIdBytes ||
      reconnect.hostDeviceId.length != _deviceIdBytes ||
      reconnect.sessionId.length != _sessionIdBytes ||
      reconnect.nonce.length != _hashBytes ||
      reconnect.offerSha256.length != _hashBytes ||
      reconnect.controllerDtlsFingerprintSha256.length != _hashBytes ||
      reconnect.answerSha256.length != _hashBytes ||
      reconnect.hostDtlsFingerprintSha256.length != _hashBytes ||
      reconnect.signature.length != _signatureBytes) {
    _failReconnect(SessionReconnectAuthenticationErrorCode.invalidReconnect);
  }
}

void _validateTime(SessionAnswerAuthentication answer, int nowUnixMs) {
  final issuedAt = answer.issuedAtUnixMs.toInt();
  final expiresAt = answer.expiresAtUnixMs.toInt();
  final lifetime = expiresAt - issuedAt;
  if (lifetime < 0) {
    _fail(SessionAnswerAuthenticationErrorCode.expired);
  }
  if (lifetime > _maximumAuthenticationLifetimeMs) {
    _fail(SessionAnswerAuthenticationErrorCode.lifetimeTooLong);
  }
  if (issuedAt > nowUnixMs + _futureClockSkewMs) {
    _fail(SessionAnswerAuthenticationErrorCode.notYetValid);
  }
  if (expiresAt < nowUnixMs) {
    _fail(SessionAnswerAuthenticationErrorCode.expired);
  }
}

void _validateReconnectTime(
  SessionReconnectAuthentication reconnect,
  int nowUnixMs,
) {
  final issuedAt = reconnect.issuedAtUnixMs.toInt();
  final expiresAt = reconnect.expiresAtUnixMs.toInt();
  final lifetime = expiresAt - issuedAt;
  if (lifetime < 0) {
    _failReconnect(SessionReconnectAuthenticationErrorCode.expired);
  }
  if (lifetime > _maximumAuthenticationLifetimeMs) {
    _failReconnect(SessionReconnectAuthenticationErrorCode.lifetimeTooLong);
  }
  if (issuedAt > nowUnixMs + _futureClockSkewMs) {
    _failReconnect(SessionReconnectAuthenticationErrorCode.notYetValid);
  }
  if (expiresAt < nowUnixMs) {
    _failReconnect(SessionReconnectAuthenticationErrorCode.expired);
  }
}

bool _answerBindsOffer(
  SessionAnswerAuthentication answer,
  SessionOfferAuthentication offer,
) =>
    _bytesEqual(answer.controllerDeviceId, offer.controllerDeviceId) &&
    _bytesEqual(answer.hostDeviceId, offer.hostDeviceId) &&
    _bytesEqual(answer.sessionId, offer.sessionId) &&
    _bytesEqual(answer.nonce, offer.nonce) &&
    answer.issuedAtUnixMs == offer.issuedAtUnixMs &&
    answer.expiresAtUnixMs == offer.expiresAtUnixMs &&
    _enumListsEqual(answer.requestedPermissions, offer.requestedPermissions) &&
    _bytesEqual(answer.offerSha256, offer.offerSha256) &&
    _bytesEqual(
      answer.controllerDtlsFingerprintSha256,
      offer.controllerDtlsFingerprintSha256,
    );

bool _reconnectBindsOffer(
  SessionReconnectAuthentication reconnect,
  SessionOfferAuthentication offer,
) =>
    _bytesEqual(reconnect.controllerDeviceId, offer.controllerDeviceId) &&
    _bytesEqual(reconnect.hostDeviceId, offer.hostDeviceId) &&
    _bytesEqual(reconnect.sessionId, offer.sessionId) &&
    _bytesEqual(reconnect.nonce, offer.nonce) &&
    reconnect.issuedAtUnixMs == offer.issuedAtUnixMs &&
    reconnect.expiresAtUnixMs == offer.expiresAtUnixMs &&
    _enumListsEqual(
      reconnect.requestedPermissions,
      offer.requestedPermissions,
    ) &&
    _bytesEqual(reconnect.offerSha256, offer.offerSha256) &&
    _bytesEqual(
      reconnect.controllerDtlsFingerprintSha256,
      offer.controllerDtlsFingerprintSha256,
    );

bool _isValidHostIdentity(DeviceIdentity identity) {
  if (identity.deviceId.length != _deviceIdBytes ||
      identity.publicKey.length != _deviceIdBytes ||
      identity.publicKeyAlgorithm !=
          PublicKeyAlgorithm.PUBLIC_KEY_ALGORITHM_ED25519) {
    return false;
  }
  return _bytesEqual(identity.deviceId, deriveDeviceIdV1(identity.publicKey));
}

List<SessionPermission> _normalizePermissions(List<SessionPermission> values) {
  if (values.isEmpty) {
    _fail(SessionAnswerAuthenticationErrorCode.invalidPermissions);
  }
  final normalized = <SessionPermission>[];
  var previous = -1;
  for (final permission in values) {
    if (permission == SessionPermission.SESSION_PERMISSION_UNSPECIFIED ||
        permission.value <= previous) {
      _fail(SessionAnswerAuthenticationErrorCode.invalidPermissions);
    }
    previous = permission.value;
    normalized.add(permission);
  }
  if (normalized.contains(SessionPermission.SESSION_PERMISSION_CONTROL_INPUT) &&
      !normalized.contains(SessionPermission.SESSION_PERMISSION_VIEW_SCREEN)) {
    _fail(SessionAnswerAuthenticationErrorCode.invalidPermissions);
  }
  return normalized;
}

List<SessionPermission> _normalizeReconnectPermissions(
  List<SessionPermission> values,
) {
  if (values.isEmpty) {
    _failReconnect(SessionReconnectAuthenticationErrorCode.invalidPermissions);
  }
  final normalized = <SessionPermission>[];
  var previous = -1;
  for (final permission in values) {
    if (permission == SessionPermission.SESSION_PERMISSION_UNSPECIFIED ||
        permission.value <= previous) {
      _failReconnect(
        SessionReconnectAuthenticationErrorCode.invalidPermissions,
      );
    }
    previous = permission.value;
    normalized.add(permission);
  }
  if (normalized.contains(SessionPermission.SESSION_PERMISSION_CONTROL_INPUT) &&
      !normalized.contains(SessionPermission.SESSION_PERMISSION_VIEW_SCREEN)) {
    _failReconnect(SessionReconnectAuthenticationErrorCode.invalidPermissions);
  }
  return normalized;
}

int _permissionBits(List<SessionPermission> values) => _normalizePermissions(
  values,
).fold<int>(0, (bits, permission) => bits | permission.value);

int _reconnectPermissionBits(List<SessionPermission> values) =>
    _normalizeReconnectPermissions(
      values,
    ).fold<int>(0, (bits, permission) => bits | permission.value);

Uint8List _uint32(int value) {
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value, Endian.big);
  return bytes;
}

Uint8List _uint64(int value) {
  final bytes = Uint8List(8);
  ByteData.sublistView(bytes).setUint64(0, value, Endian.big);
  return bytes;
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

bool _enumListsEqual(
  List<SessionPermission> left,
  List<SessionPermission> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

Never _fail(SessionAnswerAuthenticationErrorCode code) =>
    throw SessionAnswerAuthenticationException(code);

Never _failReconnect(SessionReconnectAuthenticationErrorCode code) =>
    throw SessionReconnectAuthenticationException(code);
