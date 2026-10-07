// SPDX-License-Identifier: MPL-2.0

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roammand/desktop/remote/input_sender.dart';
import 'package:roammand/desktop/remote/remote_desktop_controller.dart';
import 'package:roammand/desktop/remote/retryable_remote_desktop_controller.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

void main() {
  test('closes the failed resource group before creating a retry', () async {
    final operations = <String>[];
    final children = <_FakeController>[];
    final firstCloseGate = Completer<void>();
    final controller = RetryableRemoteDesktopController(
      createController: () {
        final child = _FakeController(
          children.length + 1,
          operations,
          closeGate: children.isEmpty ? firstCloseGate : null,
        );
        children.add(child);
        operations.add('create:${child.id}');
        return child;
      },
    );
    await controller.connect(_target());
    children.single.fail();

    final retry = controller.retry();
    await Future<void>.delayed(Duration.zero);
    expect(operations, <String>['create:1', 'connect:1', 'close:1']);

    firstCloseGate.complete();
    await retry;
    expect(operations, <String>[
      'create:1',
      'connect:1',
      'close:1',
      'dispose:1',
      'create:2',
      'connect:2',
    ]);
    expect(controller.videoRenderer, same(children[1].renderer));

    children.first.emitLateFailure();
    expect(controller.state, RemoteDesktopState.connecting);
  });

  test('ten retries and close release every resource exactly once', () async {
    final children = <_FakeController>[];
    final controller = RetryableRemoteDesktopController(
      createController: () {
        final child = _FakeController(children.length + 1, <String>[]);
        children.add(child);
        return child;
      },
    );
    await controller.connect(_target());

    for (var retry = 0; retry < 10; retry += 1) {
      children.last.fail();
      await controller.retry();
    }
    await controller.close();
    controller.dispose();

    expect(children, hasLength(11));
    for (final child in children) {
      expect(child.closeCount, 1, reason: 'child ${child.id} close');
      expect(child.disposeCount, 1, reason: 'child ${child.id} dispose');
    }
  });

  test('manual retry is available only after automatic failure', () async {
    final child = _FakeController(1, <String>[]);
    final controller = RetryableRemoteDesktopController(
      createController: () => child,
    );
    await controller.connect(_target());

    await expectLater(
      controller.retry(),
      throwsA(
        isA<RemoteDesktopException>().having(
          (error) => error.code,
          'code',
          RemoteDesktopErrorCode.configuration,
        ),
      ),
    );
    child.fail();
    expect(controller.canRetry, isTrue);
  });

  test('close cancels the retry connection before waiting for it', () async {
    final connectGate = Completer<void>();
    final children = <_FakeController>[];
    final controller = RetryableRemoteDesktopController(
      createController: () {
        final child = _FakeController(
          children.length + 1,
          <String>[],
          connectGate: children.isEmpty ? null : connectGate,
        );
        children.add(child);
        return child;
      },
    );
    await controller.connect(_target());
    children.first.fail();
    final retry = controller.retry();
    await Future<void>.delayed(Duration.zero);
    expect(children, hasLength(2));

    final closing = controller.close();
    await Future<void>.delayed(Duration.zero);
    final closeCountDuringConnect = children.last.closeCount;
    connectGate.complete();
    await retry;
    await closing;

    expect(closeCountDuringConnect, 1);
    expect(children.last.disposeCount, 1);
    expect(controller.state, RemoteDesktopState.idle);
    controller.dispose();
  });

  test('close disposes the child even when child cleanup fails', () async {
    final failure = StateError('cleanup failed');
    final child = _FakeController(1, <String>[], closeError: failure);
    final controller = RetryableRemoteDesktopController(
      createController: () => child,
    );
    await controller.connect(_target());

    await expectLater(controller.close(), throwsA(same(failure)));

    expect(child.disposeCount, 1);
    expect(controller.state, RemoteDesktopState.idle);
  });
}

final class _FakeController implements RemoteDesktopViewModel {
  _FakeController(
    this.id,
    this.operations, {
    this.closeGate,
    this.connectGate,
    this.closeError,
  });

  final int id;
  final List<String> operations;
  final Completer<void>? closeGate;
  final Completer<void>? connectGate;
  final Object? closeError;
  final Object renderer = Object();

  @override
  RemoteDesktopState state = RemoteDesktopState.idle;

  @override
  RemoteDesktopErrorCode? errorCode;

  int closeCount = 0;
  int disposeCount = 0;
  bool _disposed = false;
  final List<VoidCallback> _listeners = <VoidCallback>[];

  @override
  bool get canRetry => state == RemoteDesktopState.failed;

  @override
  DiagnosticsReport get diagnosticsReport => throw UnimplementedError();

  @override
  RemoteInputSender? get inputSender => null;

  @override
  RemoteReconnectProgress? get reconnectProgress => null;

  @override
  Object get videoRenderer => renderer;

  @override
  Future<void> connect(RemoteDesktopTarget target) async {
    operations.add('connect:$id');
    state = RemoteDesktopState.connecting;
    _notify();
    await connectGate?.future;
  }

  void fail() {
    state = RemoteDesktopState.failed;
    errorCode = RemoteDesktopErrorCode.peer;
    _notify();
  }

  void emitLateFailure() {
    state = RemoteDesktopState.failed;
    _notify();
  }

  @override
  Future<void> retry() async {
    throw UnimplementedError();
  }

  @override
  Future<void> close() async {
    if (closeCount != 0) return;
    closeCount = 1;
    operations.add('close:$id');
    await closeGate?.future;
    final error = closeError;
    if (error != null) throw error;
    state = RemoteDesktopState.idle;
    _notify();
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _notify() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    disposeCount += 1;
    operations.add('dispose:$id');
  }
}

RemoteDesktopTarget _target() {
  final publicKey = List<int>.generate(32, (index) => index + 1);
  return RemoteDesktopTarget(
    hostIdentity: DeviceIdentity(
      deviceId: deriveDeviceIdV1(publicKey),
      publicKeyAlgorithm: PublicKeyAlgorithm.PUBLIC_KEY_ALGORITHM_ED25519,
      publicKey: publicKey,
      displayName: 'Host',
      platform: DevicePlatform.DEVICE_PLATFORM_MACOS,
    ),
    signalingEndpoint: Uri.parse('wss://signal.example.test/v1/ws'),
  );
}
