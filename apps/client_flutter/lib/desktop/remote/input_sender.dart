// SPDX-License-Identifier: MPL-2.0

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

const pointerFrameInterval = Duration(microseconds: 16667);
const maxFastBufferedAmount = 256 * 1024;
const maxReliableBufferedAmount = 64 * 1024;
const reliableBufferedLowWatermark = maxReliableBufferedAmount ~/ 2;
const maxPendingReliableInputEvents = 64;
const maxPendingReliableInputBytes = 64 * 1024;
const reliableInputTimeout = Duration(seconds: 2);
const _reliableBufferRetryInterval = Duration(milliseconds: 16);
const remoteInputCoordinateMaximum = 10000;
const maxRemoteTextInputBytes = 1024;
const maxRemoteScrollDelta = 10000;
const _minimumUsbHidUsage = 0x04;
const _maximumUsbHidUsage = 0xe7;
const _maximumModifierBits = 0xff;

abstract interface class InputDataChannel {
  int get bufferedAmount;

  Future<void> send(Uint8List bytes);
}

/// Native adapters may cache bufferedAmount until a platform event arrives.
/// A paused reliable queue refreshes that cache even on platforms without
/// buffered-amount change notifications.
abstract interface class RefreshableInputDataChannel
    implements InputDataChannel {
  Future<int> readBufferedAmount();
}

abstract interface class InputFrameScheduler {
  void schedule(Duration delay, Future<void> Function() callback);

  void cancel();
}

final class TimerInputFrameScheduler implements InputFrameScheduler {
  Timer? _timer;

  @override
  void schedule(Duration delay, Future<void> Function() callback) {
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(callback()));
  }

  @override
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

enum InputSenderErrorCode {
  invalidSession,
  invalidCoordinate,
  invalidUsage,
  invalidEnum,
  invalidText,
  invalidScroll,
  suspended,
  closed,
  channel,
  cancelled,
}

final class InputSenderException implements Exception {
  const InputSenderException(this.code);

  final InputSenderErrorCode code;

  @override
  String toString() => 'InputSenderException(${code.name})';
}

final class RemoteInputSender {
  factory RemoteInputSender({
    required List<int> sessionId,
    required InputDataChannel reliable,
    required InputDataChannel fast,
    InputFrameScheduler? frameScheduler,
    Duration reliableSendTimeout = reliableInputTimeout,
    void Function()? onReliableFailure,
  }) => RemoteInputSender._(
    Uint8List.fromList(sessionId),
    reliable,
    fast,
    frameScheduler ?? TimerInputFrameScheduler(),
    reliableSendTimeout,
    onReliableFailure,
  );

  RemoteInputSender._(
    this._sessionId,
    this._reliable,
    this._fast,
    this._frameScheduler,
    this._reliableSendTimeout,
    this._onReliableFailure,
  ) {
    if (_reliableSendTimeout <= Duration.zero) {
      throw ArgumentError.value(_reliableSendTimeout, 'reliableSendTimeout');
    }
    if (_sessionId.length != sessionIdBytes) {
      throw const InputSenderException(InputSenderErrorCode.invalidSession);
    }
  }

  final Uint8List _sessionId;
  final InputDataChannel _reliable;
  final InputDataChannel _fast;
  final InputFrameScheduler _frameScheduler;
  final Duration _reliableSendTimeout;
  final void Function()? _onReliableFailure;
  final Queue<_ReliableInputTask> _reliableQueue = Queue<_ReliableInputTask>();
  _ReliableInputTask? _activeReliable;
  Timer? _reliableRetryTimer;
  int _pendingReliableBytes = 0;
  bool _reliableFailed = false;
  bool _reliableBufferPaused = false;
  bool _reliableBufferReadInFlight = false;
  Future<void>? _closeFuture;

  int _reliableSequence = 0;
  int _fastSequence = 0;
  _PendingPointerMove? _pendingMove;
  bool _frameScheduled = false;
  bool _releaseSent = false;
  bool _suspended = false;
  bool _closed = false;
  bool _fastSendInFlight = false;
  int _droppedPointerMoves = 0;

  int get droppedPointerMoves => _droppedPointerMoves;

  Future<void> sendPointerButton({
    required PointerButton button,
    required ButtonAction action,
    required int x,
    required int y,
  }) {
    _ensureOpen();
    _releaseSent = false;
    _validateCoordinate(x, y);
    if (button == PointerButton.POINTER_BUTTON_UNSPECIFIED ||
        action == ButtonAction.BUTTON_ACTION_UNSPECIFIED) {
      throw const InputSenderException(InputSenderErrorCode.invalidEnum);
    }
    return _sendReliable(
      ReliableInputEnvelope(
        pointerButton: PointerButtonEvent(
          button: button,
          action: action,
          x: x,
          y: y,
        ),
      ),
    );
  }

  Future<void> sendPointerClick({
    required PointerButton button,
    required ButtonAction action,
    required int x,
    required int y,
  }) {
    if (action != ButtonAction.BUTTON_ACTION_CLICK &&
        action != ButtonAction.BUTTON_ACTION_DOUBLE_CLICK) {
      throw const InputSenderException(InputSenderErrorCode.invalidEnum);
    }
    return sendPointerButton(button: button, action: action, x: x, y: y);
  }

  Future<void> sendKeyboard({
    required KeyboardAction action,
    required int usbHidUsage,
    int modifierBits = 0,
  }) {
    _ensureOpen();
    _releaseSent = false;
    if (action == KeyboardAction.KEYBOARD_ACTION_UNSPECIFIED) {
      throw const InputSenderException(InputSenderErrorCode.invalidEnum);
    }
    if (usbHidUsage < _minimumUsbHidUsage ||
        usbHidUsage > _maximumUsbHidUsage ||
        modifierBits < 0 ||
        modifierBits > _maximumModifierBits) {
      throw const InputSenderException(InputSenderErrorCode.invalidUsage);
    }
    return _sendReliable(
      ReliableInputEnvelope(
        keyboard: KeyboardEvent(
          action: action,
          usbHidUsage: usbHidUsage,
          modifierBits: modifierBits,
        ),
      ),
    );
  }

  Future<void> sendText(String text) {
    _ensureOpen();
    final encoded = utf8.encode(text);
    if (encoded.isEmpty || encoded.length > maxRemoteTextInputBytes) {
      throw const InputSenderException(InputSenderErrorCode.invalidText);
    }
    _releaseSent = false;
    return _sendReliable(
      ReliableInputEnvelope(text: TextInputEvent(text: text)),
    );
  }

  Future<void> sendScroll({required int deltaX, required int deltaY}) async {
    _ensureOpen();
    if (deltaX.abs() > maxRemoteScrollDelta ||
        deltaY.abs() > maxRemoteScrollDelta) {
      throw const InputSenderException(InputSenderErrorCode.invalidScroll);
    }
    _releaseSent = false;
    await _sendFastBestEffort(
      PointerFastEnvelope(
        scroll: PointerScrollEvent(deltaX: deltaX, deltaY: deltaY),
      ),
    );
  }

  void queuePointerMove({
    required int x,
    required int y,
    required int pressedButtonBits,
  }) {
    _ensureOpen();
    _releaseSent = false;
    _validateCoordinate(x, y);
    if (pressedButtonBits < 0 || pressedButtonBits > 0x07) {
      throw const InputSenderException(InputSenderErrorCode.invalidEnum);
    }
    _pendingMove = _PendingPointerMove(x, y, pressedButtonBits);
    _schedulePendingPointerMove();
  }

  Future<void> releaseAll() async {
    if (_closed || _releaseSent) {
      return;
    }
    _pendingMove = null;
    if (_frameScheduled) {
      _frameScheduler.cancel();
      _frameScheduled = false;
    }
    _cancelQueuedReliable();
    _releaseSent = true;
    await _sendReliable(
      ReliableInputEnvelope(releaseAllInput: ReleaseAllInput()),
    );
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _cancelQueuedReliable();
    _pendingMove = null;
    if (_frameScheduled) {
      _frameScheduler.cancel();
      _frameScheduled = false;
    }
    if (_reliableFailed) return;
    if (!_releaseSent) {
      _releaseSent = true;
      await _sendReliable(
        ReliableInputEnvelope(releaseAllInput: ReleaseAllInput()),
      );
    }
    await _sendReliable(
      ReliableInputEnvelope(
        sessionControl: SessionControlEvent(
          action: SessionControlAction.SESSION_CONTROL_ACTION_CLOSE,
        ),
      ),
    );
  }

  Future<void> suspend() async {
    if (_closed || _suspended) {
      return;
    }
    _suspended = true;
    _pendingMove = null;
    if (_frameScheduled) {
      _frameScheduler.cancel();
      _frameScheduled = false;
    }
    await releaseAll();
  }

  void resume() {
    if (_closed || _reliableFailed) {
      throw const InputSenderException(InputSenderErrorCode.closed);
    }
    _suspended = false;
  }

  Future<void> _flushPointerMove() async {
    _frameScheduled = false;
    final move = _pendingMove;
    _pendingMove = null;
    if (_closed || _suspended || move == null) {
      return;
    }
    if (_fastSendInFlight) {
      _pendingMove ??= move;
      return;
    }
    if (_fast.bufferedAmount > maxFastBufferedAmount) {
      _droppedPointerMoves += 1;
      return;
    }
    final sent = await _sendFastBestEffort(
      PointerFastEnvelope(
        move: PointerMoveEvent(
          x: move.x,
          y: move.y,
          pressedButtonBits: move.pressedButtonBits,
        ),
      ),
    );
    if (!sent) {
      _droppedPointerMoves += 1;
    }
  }

  void _schedulePendingPointerMove() {
    if (_closed ||
        _suspended ||
        _pendingMove == null ||
        _frameScheduled ||
        _fastSendInFlight) {
      return;
    }
    _frameScheduled = true;
    _frameScheduler.schedule(pointerFrameInterval, _flushPointerMove);
  }

  Future<bool> _sendFastBestEffort(PointerFastEnvelope envelope) async {
    if (_fastSendInFlight || _fast.bufferedAmount > maxFastBufferedAmount) {
      return false;
    }
    _fastSendInFlight = true;
    try {
      await _sendFast(envelope);
      return true;
    } on InputSenderException catch (error) {
      if (error.code != InputSenderErrorCode.channel) {
        rethrow;
      }
      // Pointer movement and scrolling use the deliberately lossy channel.
      // A closed or temporarily unwritable fast channel must not terminate
      // the reliable input path or surface an unhandled frame-callback error.
      return false;
    } finally {
      _fastSendInFlight = false;
      _schedulePendingPointerMove();
    }
  }

  Future<void> _sendReliable(ReliableInputEnvelope envelope) {
    if (_reliableFailed) {
      return Future<void>.error(
        const InputSenderException(InputSenderErrorCode.channel),
      );
    }
    envelope
      ..protocolVersion = _version()
      ..sessionId = _sessionId
      ..sequence = Int64(-1);
    // Reserve the largest sequence encoding; assign the contiguous wire
    // sequence only when dispatching, since queued work can be cancelled.
    final encoded = envelope.writeToBuffer();
    if (encoded.length > maxReliableInputEnvelopeBytes ||
        _reliableQueue.length + (_activeReliable == null ? 0 : 1) >=
            maxPendingReliableInputEvents ||
        _pendingReliableBytes + encoded.length > maxPendingReliableInputBytes) {
      abort();
      return Future<void>.error(
        const InputSenderException(InputSenderErrorCode.channel),
      );
    }
    final task = _ReliableInputTask(envelope, encoded.length);
    task.timer = Timer(_reliableSendTimeout, abort);
    _reliableQueue.addLast(task);
    _pendingReliableBytes += encoded.length;
    _pumpReliable();
    return task.completer.future;
  }

  void _pumpReliable() {
    if (_reliableFailed ||
        _activeReliable != null ||
        _reliableQueue.isEmpty ||
        _reliableBufferReadInFlight) {
      return;
    }
    final channel = _reliable;
    if (_reliableBufferPaused && channel is RefreshableInputDataChannel) {
      _reliableBufferReadInFlight = true;
      unawaited(
        Future<int>.sync(channel.readBufferedAmount)
            .timeout(_reliableSendTimeout)
            .then(
              (amount) {
                _reliableBufferReadInFlight = false;
                _dispatchReliable(amount);
              },
              onError: (Object _, StackTrace _) {
                _reliableBufferReadInFlight = false;
                abort();
              },
            ),
      );
      return;
    }
    try {
      _dispatchReliable(_reliable.bufferedAmount);
    } catch (_) {
      abort();
    }
  }

  void _dispatchReliable(int bufferedAmount) {
    if (_reliableFailed || _activeReliable != null || _reliableQueue.isEmpty) {
      return;
    }
    final task = _reliableQueue.first;
    try {
      if (_reliableBufferPaused
          ? bufferedAmount > reliableBufferedLowWatermark
          : bufferedAmount + task.budgetBytes > maxReliableBufferedAmount) {
        _reliableBufferPaused = true;
        _reliableRetryTimer ??= Timer(_reliableBufferRetryInterval, () {
          _reliableRetryTimer = null;
          _pumpReliable();
        });
        return;
      }
      _reliableBufferPaused = false;
      _reliableQueue.removeFirst();
      _activeReliable = task;
      unawaited(
        _reliable
            .send(
              (task.envelope..sequence = Int64(++_reliableSequence))
                  .writeToBuffer(),
            )
            .then((_) {
              // A timed-out native call cannot be cancelled. Its late completion
              // must never resume the abandoned input queue.
              if (_reliableFailed || !identical(_activeReliable, task)) return;
              _activeReliable = null;
              _pendingReliableBytes -= task.budgetBytes;
              task.timer?.cancel();
              task.completer.complete();
              _pumpReliable();
            }, onError: (Object _, StackTrace _) => abort()),
      );
    } catch (_) {
      abort();
    }
  }

  /// Ends input after congestion or an uncertain send. The owner must close
  /// the peer so the Host releases pressed input even if this channel is stuck.
  void abort() {
    if (_reliableFailed) return;
    _reliableFailed = true;
    _suspended = true;
    _pendingMove = null;
    _frameScheduler.cancel();
    _frameScheduled = false;
    _reliableRetryTimer?.cancel();
    _reliableRetryTimer = null;
    final active = _activeReliable;
    _activeReliable = null;
    if (active != null) _failReliableTask(active, InputSenderErrorCode.channel);
    while (_reliableQueue.isNotEmpty) {
      _failReliableTask(
        _reliableQueue.removeFirst(),
        InputSenderErrorCode.channel,
      );
    }
    _pendingReliableBytes = 0;
    _onReliableFailure?.call();
  }

  void _cancelQueuedReliable() {
    _reliableRetryTimer?.cancel();
    _reliableRetryTimer = null;
    while (_reliableQueue.isNotEmpty) {
      final task = _reliableQueue.removeFirst();
      _pendingReliableBytes -= task.budgetBytes;
      if (task.releasesInput) _releaseSent = false;
      _failReliableTask(task, InputSenderErrorCode.cancelled);
    }
  }

  void _failReliableTask(_ReliableInputTask task, InputSenderErrorCode code) {
    task.timer?.cancel();
    if (!task.completer.isCompleted) {
      task.completer.completeError(InputSenderException(code));
    }
  }

  Future<void> _sendFast(PointerFastEnvelope envelope) async {
    envelope
      ..protocolVersion = _version()
      ..sessionId = _sessionId
      ..sequence = Int64(++_fastSequence);
    final encoded = Uint8List.fromList(envelope.writeToBuffer());
    if (encoded.length > maxPointerFastEnvelopeBytes) {
      throw const InputSenderException(InputSenderErrorCode.channel);
    }
    try {
      await _fast.send(encoded);
    } catch (_) {
      throw const InputSenderException(InputSenderErrorCode.channel);
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw const InputSenderException(InputSenderErrorCode.closed);
    }
    if (_reliableFailed) {
      throw const InputSenderException(InputSenderErrorCode.channel);
    }
    if (_suspended) {
      throw const InputSenderException(InputSenderErrorCode.suspended);
    }
  }
}

final class _ReliableInputTask {
  _ReliableInputTask(this.envelope, this.budgetBytes);

  final ReliableInputEnvelope envelope;
  final int budgetBytes;
  bool get releasesInput => envelope.hasReleaseAllInput();
  final Completer<void> completer = Completer<void>();
  Timer? timer;
}

final class _PendingPointerMove {
  const _PendingPointerMove(this.x, this.y, this.pressedButtonBits);

  final int x;
  final int y;
  final int pressedButtonBits;
}

ProtocolVersion _version() => ProtocolVersion(
  major: protocolMajorVersion,
  minor: minimumProtocolMinorVersion,
);

void _validateCoordinate(int x, int y) {
  if (x < 0 ||
      x > remoteInputCoordinateMaximum ||
      y < 0 ||
      y > remoteInputCoordinateMaximum) {
    throw const InputSenderException(InputSenderErrorCode.invalidCoordinate);
  }
}
