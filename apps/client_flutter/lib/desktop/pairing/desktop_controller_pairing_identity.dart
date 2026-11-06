// SPDX-License-Identifier: MPL-2.0

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:roammand/identity/device_identity_copy.dart';
import 'package:roammand/pairing/controller_pairing_identity.dart';
import 'package:roammand/pairing/device_identity_validator.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

typedef PairingTranscriptSigner =
    Future<PairingTranscriptSignature> Function(
      List<int> canonicalTranscript,
      PairingIdentityRole role,
    );

final class DesktopControllerPairingIdentityException implements Exception {
  const DesktopControllerPairingIdentityException();

  @override
  String toString() => 'DesktopControllerPairingIdentityException';
}

final class DesktopControllerPairingIdentity
    implements ControllerPairingIdentity {
  DesktopControllerPairingIdentity({
    required DeviceIdentity identity,
    required PairingTranscriptSigner signTranscript,
  }) : _identity = copyDeviceIdentity(identity),
       // ignore: prefer_initializing_formals, keeps the public argument readable.
       _signTranscript = signTranscript {
    try {
      validateDesktopHostIdentity(_identity);
    } catch (_) {
      throw const DesktopControllerPairingIdentityException();
    }
  }

  final DeviceIdentity _identity;
  final PairingTranscriptSigner _signTranscript;

  @override
  DeviceIdentity get publicIdentity => copyDeviceIdentity(_identity);

  @override
  Future<Uint8List> sign(List<int> canonicalTranscript) async {
    try {
      final signed = await _signTranscript(
        canonicalTranscript,
        PairingIdentityRole.PAIRING_IDENTITY_ROLE_CONTROLLER,
      );
      if (signed.role != PairingIdentityRole.PAIRING_IDENTITY_ROLE_CONTROLLER ||
          !_constantTimeEquals(signed.signerDeviceId, _identity.deviceId) ||
          !_constantTimeEquals(signed.signerPublicKey, _identity.publicKey) ||
          !_constantTimeEquals(
            signed.transcriptSha256,
            hashes.sha256.convert(canonicalTranscript).bytes,
          ) ||
          signed.signature.length != signatureBytes) {
        throw const DesktopControllerPairingIdentityException();
      }
      final valid = await Ed25519().verify(
        canonicalTranscript,
        signature: Signature(
          signed.signature,
          publicKey: SimplePublicKey(
            _identity.publicKey,
            type: KeyPairType.ed25519,
          ),
        ),
      );
      if (!valid) {
        throw const DesktopControllerPairingIdentityException();
      }
      return Uint8List.fromList(signed.signature);
    } on DesktopControllerPairingIdentityException {
      rethrow;
    } catch (_) {
      throw const DesktopControllerPairingIdentityException();
    }
  }
}

bool _constantTimeEquals(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}
