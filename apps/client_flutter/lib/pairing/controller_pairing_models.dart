// SPDX-License-Identifier: MPL-2.0

import 'dart:typed_data';

import 'package:roammand/identity/device_identity_copy.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

enum ControllerPairingState {
  idle,
  connecting,
  waitingHostInvitation,
  verifyingHost,
  waitingHostDecision,
  accepted,
  rejected,
  expired,
  cancelled,
  failed,
}

enum ControllerPairingError {
  invalidInvitation,
  signaling,
  authentication,
  persistence,
  expired,
  cancelled,
  internal,
}

final class ControllerPairingSnapshot {
  ControllerPairingSnapshot({
    required this.state,
    DeviceIdentity? hostIdentity,
    List<int> hostFingerprintSha256 = const <int>[],
    List<String> sasWords = const <String>[],
    this.expiresAtUnixMs = 0,
    this.error,
  }) : _hostIdentity = hostIdentity == null
           ? null
           : copyDeviceIdentity(hostIdentity),
       _hostFingerprintSha256 = Uint8List.fromList(hostFingerprintSha256),
       sasWords = List<String>.unmodifiable(sasWords);

  final ControllerPairingState state;
  final DeviceIdentity? _hostIdentity;
  final Uint8List _hostFingerprintSha256;
  final List<String> sasWords;
  final int expiresAtUnixMs;
  final ControllerPairingError? error;

  DeviceIdentity? get hostIdentity {
    final identity = _hostIdentity;
    return identity == null ? null : copyDeviceIdentity(identity);
  }

  Uint8List get hostFingerprintSha256 =>
      Uint8List.fromList(_hostFingerprintSha256);

  bool get isTerminal => switch (state) {
    ControllerPairingState.accepted ||
    ControllerPairingState.rejected ||
    ControllerPairingState.expired ||
    ControllerPairingState.cancelled ||
    ControllerPairingState.failed => true,
    _ => false,
  };

  @override
  String toString() =>
      'ControllerPairingSnapshot(state: ${state.name}, error: ${error?.name})';
}
