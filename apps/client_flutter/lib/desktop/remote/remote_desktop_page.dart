// SPDX-License-Identifier: MPL-2.0

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:roammand/design_system/roammand_progress_indicator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:roammand/design_system/roammand_colors.dart';
import 'package:roammand/l10n/generated/app_localizations.dart';
import 'package:roammand_protocol/roammand_protocol.dart'
    hide PointerScrollEvent;

import '../../diagnostics/diagnostics_dialog.dart';
import '../desktop_app_bar.dart';
import 'input_sender.dart';
import 'remote_desktop_controller.dart';

const _toolbarPadding = 16.0;
const _toolbarSpacing = 12.0;
const _statusPaddingHorizontal = 16.0;
const _statusPaddingVertical = 8.0;
const _statusMargin = 16.0;
const _statusRadius = 20.0;
const _scrollScale = 1.0;
const _modifierLeftControl = 1 << 0;
const _modifierLeftShift = 1 << 1;
const _modifierLeftAlt = 1 << 2;
const _modifierLeftMeta = 1 << 3;
const _modifierRightControl = 1 << 4;
const _modifierRightShift = 1 << 5;
const _modifierRightAlt = 1 << 6;
const _modifierRightMeta = 1 << 7;

typedef RemoteVideoBuilder =
    Widget Function(BuildContext context, Object renderer);

final class RemotePointerPosition {
  const RemotePointerPosition(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is RemotePointerPosition && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

RemotePointerPosition? mapRemotePointer({
  required Offset localPosition,
  required Size viewportSize,
  required double videoAspectRatio,
}) {
  if (viewportSize.width <= 0 ||
      viewportSize.height <= 0 ||
      !videoAspectRatio.isFinite ||
      videoAspectRatio <= 0) {
    return null;
  }
  final viewportAspectRatio = viewportSize.width / viewportSize.height;
  late final Rect videoRect;
  if (viewportAspectRatio > videoAspectRatio) {
    final width = viewportSize.height * videoAspectRatio;
    videoRect = Rect.fromLTWH(
      (viewportSize.width - width) / 2,
      0,
      width,
      viewportSize.height,
    );
  } else {
    final height = viewportSize.width / videoAspectRatio;
    videoRect = Rect.fromLTWH(
      0,
      (viewportSize.height - height) / 2,
      viewportSize.width,
      height,
    );
  }
  if (!videoRect.contains(localPosition)) {
    return null;
  }
  final x = ((localPosition.dx - videoRect.left) / videoRect.width).clamp(
    0.0,
    1.0,
  );
  final y = ((localPosition.dy - videoRect.top) / videoRect.height).clamp(
    0.0,
    1.0,
  );
  return RemotePointerPosition(
    (x * remoteInputCoordinateMaximum).round(),
    (y * remoteInputCoordinateMaximum).round(),
  );
}

final class RemoteDesktopPage extends StatefulWidget {
  const RemoteDesktopPage({
    super.key,
    required this.target,
    required this.controller,
    this.videoBuilder,
    this.videoAspectRatio,
  });

  final RemoteDesktopTarget target;
  final RemoteDesktopViewModel controller;
  final RemoteVideoBuilder? videoBuilder;
  final double? videoAspectRatio;

  @override
  State<RemoteDesktopPage> createState() => _RemoteDesktopPageState();
}

final class _RemoteDesktopPageState extends State<RemoteDesktopPage>
    with WidgetsBindingObserver {
  final FocusNode _focusNode = FocusNode(debugLabel: 'remote-desktop-input');
  int _pressedButtonBits = 0;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onControllerChanged);
    _focusNode.addListener(_onFocusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
        unawaited(widget.controller.connect(widget.target));
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (mounted) {
          _focusNode.requestFocus();
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        _releaseAll();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(_closeSession(pop: false));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onControllerChanged);
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    unawaited(
      widget.controller.close().whenComplete(widget.controller.dispose),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: RoammandColors.canvas,
      appBar: RoammandDesktopAppBar(
        platform: Theme.of(context).platform,
        showBackButton: true,
        title: Text(
          strings.remoteDesktopTitle(widget.target.hostIdentity.displayName),
        ),
        actions: <Widget>[
          IconButton(
            key: const Key('remote-diagnostics-action'),
            onPressed: _closing
                ? null
                : () => unawaited(
                    showDiagnosticsDialog(
                      context,
                      report: widget.controller.diagnosticsReport,
                    ),
                  ),
            tooltip: strings.diagnosticsAction,
            icon: const Icon(Icons.monitor_heart_outlined, size: 24),
          ),
          TextButton.icon(
            onPressed: _closing ? null : () => _closeSession(pop: true),
            icon: const Icon(Icons.close, size: 20),
            label: Text(strings.closeSessionAction),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            KeyboardListener(
              focusNode: _focusNode,
              onKeyEvent: _handleKey,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(
                    math.max(0, constraints.maxWidth),
                    math.max(0, constraints.maxHeight),
                  );
                  return Listener(
                    key: const Key('remote-video-interaction'),
                    behavior: HitTestBehavior.opaque,
                    onPointerHover: (event) => _move(event.localPosition, size),
                    onPointerMove: (event) {
                      _pressedButtonBits = _protocolButtonBits(event.buttons);
                      _move(event.localPosition, size);
                    },
                    onPointerDown: (event) {
                      _focusNode.requestFocus();
                      _button(event.localPosition, size, event.buttons, true);
                    },
                    onPointerUp: (event) => _button(
                      event.localPosition,
                      size,
                      event.buttons,
                      false,
                    ),
                    onPointerCancel: (_) => _releaseAll(),
                    onPointerSignal: (event) {
                      if (event is PointerScrollEvent) {
                        _scroll(event.scrollDelta);
                      }
                    },
                    child: _buildVideo(context),
                  );
                },
              ),
            ),
            Positioned(
              top: _statusMargin,
              left: _statusMargin,
              right: _statusMargin,
              child: Center(child: _buildStatus(context, strings)),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildToolbar(context, strings),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideo(BuildContext context) {
    final builder = widget.videoBuilder;
    if (builder != null) {
      return builder(context, widget.controller.videoRenderer);
    }
    final renderer = widget.controller.videoRenderer;
    if (renderer is! RTCVideoRenderer) {
      return const ColoredBox(color: Colors.black);
    }
    return RTCVideoView(
      renderer,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    );
  }

  Widget _buildStatus(BuildContext context, AppLocalizations strings) {
    final failed = widget.controller.state == RemoteDesktopState.failed;
    final connected = widget.controller.state == RemoteDesktopState.connected;
    final colorScheme = Theme.of(context).colorScheme;
    final accent = failed
        ? RoammandColors.emergency
        : connected
        ? RoammandColors.online
        : RoammandColors.auroraSoft;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: failed
            ? colorScheme.errorContainer
            : connected
            ? RoammandColors.online.withValues(alpha: 0.14)
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(_statusRadius),
        border: Border.all(color: accent.withValues(alpha: 0.48)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _statusPaddingHorizontal,
          vertical: _statusPaddingVertical,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (connected) ...<Widget>[
              const Icon(Icons.circle, size: 8, color: RoammandColors.online),
              const SizedBox(width: 8),
            ],
            if (_isProgressState(widget.controller.state)) ...<Widget>[
              const RoammandProgressIndicator(
                size: roammandCompactProgressIndicatorSize,
              ),
              const SizedBox(width: 8),
            ],
            Flexible(child: Text(_statusText(strings))),
            if (failed && widget.controller.canRetry) ...<Widget>[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => unawaited(_retrySession()),
                child: Text(strings.retryRemoteAction),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(BuildContext context, AppLocalizations strings) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xF211142D),
        border: Border(top: BorderSide(color: RoammandColors.outline)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(_toolbarPadding),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: _toolbarSpacing,
          runSpacing: 8,
          children: <Widget>[
            const Icon(Icons.mouse_outlined, size: 20),
            Text(strings.remoteInputHint),
            const Icon(Icons.keyboard_outlined, size: 20),
            Text(strings.localExitShortcutHint),
          ],
        ),
      ),
    );
  }

  String _statusText(AppLocalizations strings) {
    if (widget.controller.state == RemoteDesktopState.failed) {
      return switch (widget.controller.errorCode) {
        RemoteDesktopErrorCode.authentication =>
          strings.remoteAuthenticationFailed,
        RemoteDesktopErrorCode.localIdentity =>
          strings.remoteLocalIdentityFailed,
        RemoteDesktopErrorCode.signaling => strings.remoteSignalingFailed,
        RemoteDesktopErrorCode.configuration =>
          strings.remoteConfigurationFailed,
        RemoteDesktopErrorCode.peer ||
        RemoteDesktopErrorCode.remote ||
        null => strings.remoteConnectionFailed,
      };
    }
    return switch (widget.controller.state) {
      RemoteDesktopState.idle => strings.remoteIdle,
      RemoteDesktopState.connecting => strings.remoteConnecting,
      RemoteDesktopState.reconnecting => _reconnectText(strings),
      RemoteDesktopState.authenticating => strings.remoteAuthenticating,
      RemoteDesktopState.negotiating => strings.remoteNegotiating,
      RemoteDesktopState.connected => strings.remoteConnected,
      RemoteDesktopState.closing => strings.remoteClosing,
      RemoteDesktopState.failed => strings.remoteConnectionFailed,
    };
  }

  String _reconnectText(AppLocalizations strings) {
    final progress = widget.controller.reconnectProgress;
    if (progress == null) {
      return strings.remoteReconnectingPending;
    }
    return strings.remoteReconnecting(
      progress.attempt,
      progress.maximumAttempts,
      progress.remaining.inSeconds,
    );
  }

  double get _videoAspectRatio {
    final configured = widget.videoAspectRatio;
    if (configured != null && configured.isFinite && configured > 0) {
      return configured;
    }
    final renderer = widget.controller.videoRenderer;
    if (renderer is RTCVideoRenderer &&
        renderer.videoWidth > 0 &&
        renderer.videoHeight > 0) {
      return renderer.videoWidth / renderer.videoHeight;
    }
    return 16 / 9;
  }

  void _move(Offset localPosition, Size viewportSize) {
    final sender = _connectedSender;
    final position = mapRemotePointer(
      localPosition: localPosition,
      viewportSize: viewportSize,
      videoAspectRatio: _videoAspectRatio,
    );
    if (sender == null || position == null) {
      return;
    }
    sender.queuePointerMove(
      x: position.x,
      y: position.y,
      pressedButtonBits: _pressedButtonBits,
    );
  }

  void _button(
    Offset localPosition,
    Size viewportSize,
    int buttons,
    bool down,
  ) {
    final sender = _connectedSender;
    final position = mapRemotePointer(
      localPosition: localPosition,
      viewportSize: viewportSize,
      videoAspectRatio: _videoAspectRatio,
    );
    if (sender == null || position == null) {
      return;
    }
    final nextBits = _protocolButtonBits(buttons);
    final changed = down
        ? nextBits & ~_pressedButtonBits
        : _pressedButtonBits & ~nextBits;
    _pressedButtonBits = nextBits;
    final button = _pointerButton(changed);
    if (button == null) {
      return;
    }
    _guardInput(
      sender.sendPointerButton(
        button: button,
        action: down
            ? ButtonAction.BUTTON_ACTION_DOWN
            : ButtonAction.BUTTON_ACTION_UP,
        x: position.x,
        y: position.y,
      ),
    );
  }

  void _scroll(Offset delta) {
    final sender = _connectedSender;
    if (sender == null) {
      return;
    }
    unawaited(
      sender.sendScroll(
        deltaX: (-delta.dx * _scrollScale).round(),
        deltaY: (-delta.dy * _scrollScale).round(),
      ),
    );
  }

  void _handleKey(KeyEvent event) {
    final sender = _connectedSender;
    if (sender == null || event is KeyRepeatEvent) {
      return;
    }
    if (event is KeyDownEvent && _isLocalExit(event)) {
      unawaited(_closeSession(pop: true));
      return;
    }
    final usage = event.physicalKey.usbHidUsage & 0xffff;
    if (usage == 0) {
      return;
    }
    final action = event is KeyDownEvent
        ? KeyboardAction.KEYBOARD_ACTION_DOWN
        : event is KeyUpEvent
        ? KeyboardAction.KEYBOARD_ACTION_UP
        : null;
    if (action == null) {
      return;
    }
    _guardInput(
      sender.sendKeyboard(
        action: action,
        usbHidUsage: usage,
        modifierBits: _modifierBits(),
      ),
    );
  }

  bool _isLocalExit(KeyDownEvent event) {
    final keyboard = HardwareKeyboard.instance;
    return event.physicalKey == PhysicalKeyboardKey.escape &&
        keyboard.isControlPressed &&
        keyboard.isAltPressed &&
        keyboard.isShiftPressed;
  }

  int _modifierBits() {
    final pressed = HardwareKeyboard.instance.physicalKeysPressed;
    var bits = 0;
    if (pressed.contains(PhysicalKeyboardKey.controlLeft)) {
      bits |= _modifierLeftControl;
    }
    if (pressed.contains(PhysicalKeyboardKey.shiftLeft)) {
      bits |= _modifierLeftShift;
    }
    if (pressed.contains(PhysicalKeyboardKey.altLeft)) {
      bits |= _modifierLeftAlt;
    }
    if (pressed.contains(PhysicalKeyboardKey.metaLeft)) {
      bits |= _modifierLeftMeta;
    }
    if (pressed.contains(PhysicalKeyboardKey.controlRight)) {
      bits |= _modifierRightControl;
    }
    if (pressed.contains(PhysicalKeyboardKey.shiftRight)) {
      bits |= _modifierRightShift;
    }
    if (pressed.contains(PhysicalKeyboardKey.altRight)) {
      bits |= _modifierRightAlt;
    }
    if (pressed.contains(PhysicalKeyboardKey.metaRight)) {
      bits |= _modifierRightMeta;
    }
    return bits;
  }

  RemoteInputSender? get _connectedSender =>
      widget.controller.state == RemoteDesktopState.connected
      ? widget.controller.inputSender
      : null;

  void _onFocusChanged() {
    if (!_focusNode.hasFocus) {
      _releaseAll();
    }
  }

  void _releaseAll() {
    _pressedButtonBits = 0;
    _guardInput(
      widget.controller.inputSender?.releaseAll() ?? Future<void>.value(),
    );
  }

  void _guardInput(Future<void> operation) {
    // Reliable channel errors notify the controller, which closes the session.
    // Cancellation during focus loss or teardown is expected.
    unawaited(operation.catchError((_) {}));
  }

  Future<void> _closeSession({required bool pop}) async {
    if (_closing) {
      return;
    }
    _closing = true;
    _releaseAll();
    await widget.controller.close();
    if (pop && mounted) {
      await Navigator.of(context).maybePop();
    }
  }

  Future<void> _retrySession() async {
    if (_closing || !widget.controller.canRetry) {
      return;
    }
    try {
      await widget.controller.retry();
    } catch (_) {}
  }

  void _onControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }
}

bool _isProgressState(RemoteDesktopState state) => switch (state) {
  RemoteDesktopState.connecting ||
  RemoteDesktopState.authenticating ||
  RemoteDesktopState.negotiating ||
  RemoteDesktopState.reconnecting ||
  RemoteDesktopState.closing => true,
  RemoteDesktopState.idle ||
  RemoteDesktopState.connected ||
  RemoteDesktopState.failed => false,
};

int _protocolButtonBits(int buttons) {
  var result = 0;
  if (buttons & kPrimaryMouseButton != 0) {
    result |= 1;
  }
  if (buttons & kSecondaryMouseButton != 0) {
    result |= 1 << 1;
  }
  if (buttons & kMiddleMouseButton != 0) {
    result |= 1 << 2;
  }
  return result;
}

PointerButton? _pointerButton(int changedBits) {
  if (changedBits & 1 != 0) {
    return PointerButton.POINTER_BUTTON_LEFT;
  }
  if (changedBits & (1 << 1) != 0) {
    return PointerButton.POINTER_BUTTON_RIGHT;
  }
  if (changedBits & (1 << 2) != 0) {
    return PointerButton.POINTER_BUTTON_MIDDLE;
  }
  return null;
}
