// SPDX-License-Identifier: MPL-2.0

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:roammand/desktop/remote/input_sender.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

enum MobileModifierKey { control, shift, alt, command }

enum MobileSpecialKey { escape, tab, arrowLeft, arrowUp, arrowRight, arrowDown }

const _modifierUsages = <MobileModifierKey, int>{
  MobileModifierKey.control: 0xe0,
  MobileModifierKey.shift: 0xe1,
  MobileModifierKey.alt: 0xe2,
  MobileModifierKey.command: 0xe3,
};

const _modifierBits = <MobileModifierKey, int>{
  MobileModifierKey.control: 1 << 0,
  MobileModifierKey.shift: 1 << 1,
  MobileModifierKey.alt: 1 << 2,
  MobileModifierKey.command: 1 << 3,
};

const _specialUsages = <MobileSpecialKey, int>{
  MobileSpecialKey.escape: 0x29,
  MobileSpecialKey.tab: 0x2b,
  MobileSpecialKey.arrowRight: 0x4f,
  MobileSpecialKey.arrowLeft: 0x50,
  MobileSpecialKey.arrowDown: 0x51,
  MobileSpecialKey.arrowUp: 0x52,
};

const maxPendingMobileKeyboardOperations = 32;
const maxPendingMobileKeyboardTextBytes = 32 * 1024;

final class MobileKeyboardController {
  MobileKeyboardController(
    this._sender, {
    this.operationTimeout = reliableInputTimeout,
  }) {
    if (operationTimeout <= Duration.zero) {
      throw ArgumentError.value(operationTimeout, 'operationTimeout');
    }
  }

  final RemoteInputSender _sender;
  final Set<MobileModifierKey> _activeModifiers = <MobileModifierKey>{};
  final StreamController<void> _modifierChanges =
      StreamController<void>.broadcast();

  final Duration operationTimeout;
  final Queue<_KeyboardOperation> _pending = Queue<_KeyboardOperation>();
  _KeyboardOperation? _active;
  Future<void>? _closeFuture;
  Future<void> _lastOperation = Future<void>.value();
  int _pendingTextBytes = 0;
  int _generation = 0;
  bool _closed = false;

  Set<MobileModifierKey> get activeModifiers =>
      UnmodifiableSetView<MobileModifierKey>(_activeModifiers);

  // Async delivery lets session teardown clear modifiers during a widget frame.
  // Terminal cleanup closes the stream after delivering its final state change.
  Stream<void> get modifierChanges => _modifierChanges.stream;

  bool isModifierActive(MobileModifierKey modifier) =>
      _activeModifiers.contains(modifier);

  Future<void> setModifier(MobileModifierKey modifier, bool active) {
    if (_closed) {
      return _closedFuture();
    }
    final changed = active
        ? _activeModifiers.add(modifier)
        : _activeModifiers.remove(modifier);
    if (!changed) {
      return _lastOperation;
    }
    _modifierChanges.add(null);
    final usage = _modifierUsages[modifier]!;
    final bits = _currentModifierBits();
    return _enqueue(
      () => _sender.sendKeyboard(
        action: active
            ? KeyboardAction.KEYBOARD_ACTION_DOWN
            : KeyboardAction.KEYBOARD_ACTION_UP,
        usbHidUsage: usage,
        modifierBits: bits,
      ),
    );
  }

  Future<void> sendSpecial(MobileSpecialKey key) {
    if (_closed) {
      return _closedFuture();
    }
    final usage = _specialUsages[key]!;
    final bits = _currentModifierBits();
    final generation = _generation;
    return _enqueue(() async {
      await _sender.sendKeyboard(
        action: KeyboardAction.KEYBOARD_ACTION_DOWN,
        usbHidUsage: usage,
        modifierBits: bits,
      );
      if (_generation != generation) {
        throw const InputSenderException(InputSenderErrorCode.cancelled);
      }
      await _sender.sendKeyboard(
        action: KeyboardAction.KEYBOARD_ACTION_UP,
        usbHidUsage: usage,
        modifierBits: bits,
      );
    });
  }

  Future<void> sendText(String text) {
    if (_closed) {
      return _closedFuture();
    }
    final textBytes = utf8.encode(text).length;
    if (textBytes == 0 || textBytes > maxRemoteTextInputBytes) {
      return Future<void>.error(
        const InputSenderException(InputSenderErrorCode.invalidText),
      );
    }
    return _enqueue(() => _sender.sendText(text), textBytes: textBytes);
  }

  Future<void> releaseAll() {
    if (_closed) return _closeFuture ?? Future<void>.value();
    _cancelOperations(InputSenderErrorCode.cancelled);
    _clearModifiers();
    return _enqueue(_sender.releaseAll);
  }

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closed = true;
    _cancelOperations(InputSenderErrorCode.cancelled);
    _clearModifiers();
    unawaited(_modifierChanges.close());
    // The sender serializes release behind any call already submitted to the
    // native channel and applies its own bounded send deadline.
    return _closeFuture = _sender.releaseAll().catchError((_) {});
  }

  int _currentModifierBits() => _activeModifiers.fold<int>(
    0,
    (bits, modifier) => bits | _modifierBits[modifier]!,
  );

  Future<void> _enqueue(
    Future<void> Function() operation, {
    int textBytes = 0,
  }) {
    if (_pending.length + (_active == null ? 0 : 1) >=
            maxPendingMobileKeyboardOperations ||
        _pendingTextBytes + textBytes > maxPendingMobileKeyboardTextBytes) {
      _abort();
      return Future<void>.error(
        const InputSenderException(InputSenderErrorCode.channel),
      );
    }
    final task = _KeyboardOperation(operation, textBytes);
    task.timer = Timer(operationTimeout, _abort);
    _pending.addLast(task);
    _pendingTextBytes += textBytes;
    _lastOperation = task.completer.future;
    _pump();
    return task.completer.future;
  }

  void _pump() {
    if (_closed || _active != null || _pending.isEmpty) return;
    final task = _pending.removeFirst();
    _active = task;
    unawaited(
      Future<void>.sync(task.operation).then(
        (_) {
          if (!identical(_active, task)) return;
          _active = null;
          _pendingTextBytes -= task.textBytes;
          task.timer?.cancel();
          task.completer.complete();
          _pump();
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!identical(_active, task)) return;
          if (error is InputSenderException &&
              error.code == InputSenderErrorCode.cancelled) {
            // Gestures share the sender and can release input directly. Their
            // release cancels queued keyboard work without failing the peer.
            _clearModifiers();
            _cancelOperations(InputSenderErrorCode.cancelled);
            return;
          }
          task.timer?.cancel();
          task.completer.completeError(error, stackTrace);
          _active = null;
          _pendingTextBytes -= task.textBytes;
          _abort();
        },
      ),
    );
  }

  void _abort() {
    if (_closed) return;
    _closed = true;
    _clearModifiers();
    unawaited(_modifierChanges.close());
    _cancelOperations(InputSenderErrorCode.channel);
    _sender.abort();
  }

  void _clearModifiers() {
    if (_activeModifiers.isEmpty) return;
    _activeModifiers.clear();
    _modifierChanges.add(null);
  }

  void _cancelOperations(InputSenderErrorCode code) {
    _generation += 1;
    final active = _active;
    _active = null;
    if (active != null) _failOperation(active, code);
    while (_pending.isNotEmpty) {
      _failOperation(_pending.removeFirst(), code);
    }
    _pendingTextBytes = 0;
  }

  void _failOperation(_KeyboardOperation task, InputSenderErrorCode code) {
    task.timer?.cancel();
    if (!task.completer.isCompleted) {
      task.completer.completeError(InputSenderException(code));
    }
  }

  Future<void> _closedFuture() =>
      Future<void>.error(StateError('mobile keyboard controller is closed'));
}

final class _KeyboardOperation {
  _KeyboardOperation(this.operation, this.textBytes);

  final Future<void> Function() operation;
  final int textBytes;
  final Completer<void> completer = Completer<void>();
  Timer? timer;
}
