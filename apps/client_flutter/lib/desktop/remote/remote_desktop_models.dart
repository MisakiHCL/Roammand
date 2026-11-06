// SPDX-License-Identifier: MPL-2.0

part of 'remote_desktop_controller.dart';

enum RemoteDesktopState {
  idle,
  connecting,
  authenticating,
  negotiating,
  connected,
  reconnecting,
  closing,
  failed,
}

enum RemoteDesktopErrorCode {
  configuration,
  localIdentity,
  signaling,
  authentication,
  peer,
  remote,
}

final class RemoteReconnectProgress {
  const RemoteReconnectProgress({
    required this.attempt,
    required this.maximumAttempts,
    required this.elapsed,
    required this.recoveryWindow,
  });

  final int attempt;
  final int maximumAttempts;
  final Duration elapsed;
  final Duration recoveryWindow;

  Duration get remaining => recoveryWindow - elapsed;
}

abstract interface class RemoteDesktopViewModel implements Listenable {
  RemoteDesktopState get state;

  RemoteDesktopErrorCode? get errorCode;

  RemoteReconnectProgress? get reconnectProgress;

  DiagnosticsReport get diagnosticsReport;

  bool get canRetry;

  Object get videoRenderer;

  RemoteInputSender? get inputSender;

  Future<void> connect(RemoteDesktopTarget target);

  Future<void> retry();

  Future<void> close();

  void dispose();
}

final class RemoteDesktopTarget {
  RemoteDesktopTarget({
    required DeviceIdentity hostIdentity,
    required this.signalingEndpoint,
  }) : _hostIdentity = copyDeviceIdentity(hostIdentity);

  final DeviceIdentity _hostIdentity;
  final Uri signalingEndpoint;

  DeviceIdentity get hostIdentity => copyDeviceIdentity(_hostIdentity);

  void validate() {
    try {
      validateDeviceIdentity(_hostIdentity);
      validateSignalingEndpoint(signalingEndpoint);
    } catch (_) {
      throw const RemoteDesktopException(RemoteDesktopErrorCode.configuration);
    }
  }
}

final class RemoteDesktopException implements Exception {
  const RemoteDesktopException(this.code);

  final RemoteDesktopErrorCode code;

  @override
  String toString() => 'RemoteDesktopException(${code.name})';
}
