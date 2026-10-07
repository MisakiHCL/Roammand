// SPDX-License-Identifier: MPL-2.0

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'input_sender.dart';
import 'remote_desktop_controller.dart';

typedef RemoteDesktopControllerFactory = RemoteDesktopViewModel Function();

final class RetryableRemoteDesktopController extends ChangeNotifier
    implements RemoteDesktopViewModel {
  factory RetryableRemoteDesktopController({
    required RemoteDesktopControllerFactory createController,
  }) => RetryableRemoteDesktopController._(createController);

  RetryableRemoteDesktopController._(this._createController) {
    _controller = _createController();
    _controller.addListener(_handleControllerChanged);
    _syncControllerState();
  }

  final RemoteDesktopControllerFactory _createController;
  final Set<RemoteDesktopViewModel> _disposedControllers =
      Set<RemoteDesktopViewModel>.identity();
  late RemoteDesktopViewModel _controller;
  RemoteDesktopTarget? _target;
  RemoteDesktopState _state = RemoteDesktopState.idle;
  RemoteDesktopErrorCode? _errorCode;
  RemoteReconnectProgress? _reconnectProgress;
  Future<void>? _retryFuture;
  Future<void>? _closeFuture;
  bool _closed = false;
  bool _disposed = false;

  @override
  RemoteDesktopState get state => _state;

  @override
  RemoteDesktopErrorCode? get errorCode => _errorCode;

  @override
  RemoteReconnectProgress? get reconnectProgress => _reconnectProgress;

  @override
  bool get canRetry => !_closed && _state == RemoteDesktopState.failed;

  @override
  DiagnosticsReport get diagnosticsReport => _controller.diagnosticsReport;

  @override
  Object get videoRenderer => _controller.videoRenderer;

  @override
  RemoteInputSender? get inputSender => _controller.inputSender;

  @override
  Future<void> connect(RemoteDesktopTarget target) async {
    if (_closed || _target != null || _state != RemoteDesktopState.idle) {
      throw const RemoteDesktopException(RemoteDesktopErrorCode.configuration);
    }
    target.validate();
    _target = target;
    await _controller.connect(target);
  }

  @override
  Future<void> retry() {
    final existing = _retryFuture;
    if (existing != null) {
      return existing;
    }
    if (!canRetry || _target == null) {
      return Future<void>.error(
        const RemoteDesktopException(RemoteDesktopErrorCode.configuration),
      );
    }
    final retry = _replaceAndConnect();
    _retryFuture = retry;
    return retry;
  }

  Future<void> _replaceAndConnect() async {
    final previous = _controller;
    previous.removeListener(_handleControllerChanged);
    _state = RemoteDesktopState.closing;
    _reconnectProgress = null;
    _notify();
    try {
      var closeFailed = false;
      try {
        await previous.close();
      } catch (_) {
        closeFailed = true;
      }
      _disposeController(previous);
      if (closeFailed) {
        _markRetryFailure();
        return;
      }
      if (_closed) {
        return;
      }
      late final RemoteDesktopViewModel next;
      try {
        next = _createController();
      } catch (_) {
        _markRetryFailure();
        return;
      }
      _controller = next;
      next.addListener(_handleControllerChanged);
      _syncControllerState();
      _notify();
      await next.connect(_target!);
    } finally {
      _retryFuture = null;
    }
  }

  void _markRetryFailure() {
    _state = RemoteDesktopState.failed;
    _errorCode = RemoteDesktopErrorCode.peer;
    _reconnectProgress = null;
    _notify();
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    final retry = _retryFuture;
    final current = _controller;
    current.removeListener(_handleControllerChanged);
    try {
      // Closing the child cancels a pending connection. Waiting for retry
      // first would let that connection keep resources alive until it finishes.
      await current.close();
    } finally {
      if (retry != null) {
        try {
          await retry;
        } catch (_) {
          // A failed connection must not prevent the child from being disposed.
        }
      }
      _disposeController(current);
      _state = RemoteDesktopState.idle;
      _errorCode = null;
      _reconnectProgress = null;
      _notify();
    }
  }

  void _handleControllerChanged() {
    _syncControllerState();
    _notify();
  }

  void _syncControllerState() {
    _state = _controller.state;
    _errorCode = _controller.errorCode;
    _reconnectProgress = _controller.reconnectProgress;
  }

  void _disposeController(RemoteDesktopViewModel controller) {
    if (_disposedControllers.add(controller)) {
      controller.dispose();
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    unawaited(close().catchError((_) {}));
    super.dispose();
  }
}
