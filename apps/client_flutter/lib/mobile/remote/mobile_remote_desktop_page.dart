// SPDX-License-Identifier: MPL-2.0

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:roammand/design_system/roammand_progress_indicator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:roammand/design_system/roammand_colors.dart';
import 'package:roammand/desktop/remote/input_sender.dart';
import 'package:roammand/desktop/remote/peer_session.dart';
import 'package:roammand/desktop/remote/remote_desktop_controller.dart';
import 'package:roammand/l10n/generated/app_localizations.dart';
import 'package:roammand/mobile/remote/mobile_gesture_surface.dart';
import 'package:roammand/mobile/remote/mobile_input_tray.dart';
import 'package:roammand/mobile/remote/mobile_keyboard_controller.dart';
import 'package:roammand/mobile/widgets/mobile_page_header.dart';

import '../../diagnostics/diagnostics_dialog.dart';

const _statusHeight = 32.0;
const _statusHorizontalPadding = 8.0;
const _statusVerticalPadding = 4.0;
const _statusRadius = 16.0;
const _controlBarPadding = 4.0;
const _controlBarHeight = 40.0;
const _unlockButtonSize = 48.0;
const _focusedInputTrayHeight = 56.0;
const _minimumInputTrayHeight = 120.0;
const _maximumInputTrayHeight = 200.0;
const _inputTrayScreenFraction = 0.36;
const _textInputHideMethod = 'TextInput.hide';
const _overlayClear = Color(0x00000000);
const _overlayScrim = Color(0xB3000000);
const _unlockSurface = Color(0xA6000000);
const _remoteOrientations = <DeviceOrientation>[
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
];
const _systemManagedOrientations = <DeviceOrientation>[];

List<DeviceOrientation> get _restoredOrientations =>
    defaultTargetPlatform == TargetPlatform.iOS
    ? _remoteOrientations
    : _systemManagedOrientations;

typedef MobileRemoteVideoBuilder =
    Widget Function(BuildContext context, Object renderer);

final class MobileRemoteDesktopPage extends StatefulWidget {
  const MobileRemoteDesktopPage({
    required this.target,
    required this.controller,
    this.videoBuilder,
    this.videoAspectRatio,
    super.key,
  });

  final RemoteDesktopTarget target;
  final RemoteDesktopViewModel controller;
  final MobileRemoteVideoBuilder? videoBuilder;
  final double? videoAspectRatio;

  @override
  State<MobileRemoteDesktopPage> createState() =>
      _MobileRemoteDesktopPageState();
}

final class _MobileRemoteDesktopPageState extends State<MobileRemoteDesktopPage>
    with WidgetsBindingObserver {
  final MobileGestureSurfaceController _gestureController =
      MobileGestureSurfaceController();
  final FocusNode _textInputFocusNode = FocusNode(
    debugLabel: 'mobile-remote-text-input',
  );

  RemoteInputSender? _keyboardSender;
  MobileKeyboardController? _keyboardController;
  Future<void>? _closeFuture;
  bool _keyboardVisible = false;
  bool _controlsLocked = false;
  bool _immersiveSystemUiActive = false;
  bool _privacyShieldVisible = false;
  bool _privacyShieldSyncScheduled = false;
  OverlayEntry? _privacyShieldEntry;
  bool _closing = false;
  bool _popRequested = false;
  bool _allowPop = false;
  late final Future<void> _orientationLock;

  @override
  void initState() {
    super.initState();
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _privacyShieldVisible =
        lifecycleState != null && lifecycleState != AppLifecycleState.resumed;
    _orientationLock = _setPreferredOrientations(_remoteOrientations);
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onControllerChanged);
    _syncKeyboardController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncPrivacyShield();
      if (mounted && !_closing) {
        unawaited(widget.controller.connect(widget.target));
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_closing) {
          unawaited(_closeSession(pop: true));
        } else {
          _setPrivacyShieldVisible(false);
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        _setPrivacyShieldVisible(true);
        _exitControlsLock();
        _releaseInput();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _setPrivacyShieldVisible(true);
        _exitControlsLock();
        _releaseInput();
        unawaited(_closeSession(pop: false));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _removePrivacyShield();
    widget.controller.removeListener(_onControllerChanged);
    _restoreSystemUiIfNeeded();
    _textInputFocusNode.dispose();
    unawaited(_keyboardController?.close() ?? Future<void>.value());
    final closing = _closeController();
    unawaited(closing.whenComplete(widget.controller.dispose));
    unawaited(
      _orientationLock.whenComplete(
        () => _setPreferredOrientations(_restoredOrientations),
      ),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final mediaQuery = MediaQuery.of(context);
    final inputTrayHeight = (mediaQuery.size.height * _inputTrayScreenFraction)
        .clamp(_minimumInputTrayHeight, _maximumInputTrayHeight);
    final softwareKeyboardVisible = mediaQuery.viewInsets.bottom > 0;
    final visibleInputTrayHeight = softwareKeyboardVisible
        ? _focusedInputTrayHeight
        : inputTrayHeight;
    return Theme(
      data: _compactRemoteTheme(Theme.of(context)),
      child: PopScope<void>(
        canPop: _allowPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            unawaited(_closeSession(pop: true));
          }
        },
        child: Scaffold(
          backgroundColor: RoammandColors.canvas,
          resizeToAvoidBottomInset: false,
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              RepaintBoundary(
                key: const Key('mobile-remote-render-boundary'),
                child: _buildRemoteViewport(
                  context,
                  dismissKeyboardOnTap:
                      _keyboardVisible && softwareKeyboardVisible,
                ),
              ),
              if (!_controlsLocked)
                Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  child: _buildHeader(context, strings, mediaQuery.padding),
                ),
              if (!_controlsLocked && !softwareKeyboardVisible)
                Positioned(
                  key: const Key('mobile-remote-control-bar-position'),
                  left: 0,
                  right: 0,
                  bottom: _keyboardVisible ? inputTrayHeight : 0,
                  height: _controlBarHeight,
                  child: _buildControlBar(strings, mediaQuery.padding),
                ),
              if (!_controlsLocked && _keyboardVisible)
                Positioned(
                  key: const Key('mobile-input-tray-position'),
                  left: 0,
                  right: 0,
                  bottom: softwareKeyboardVisible
                      ? mediaQuery.viewInsets.bottom
                      : 0,
                  height: visibleInputTrayHeight,
                  child: _buildInputTray(
                    mediaQuery.padding,
                    compact: softwareKeyboardVisible,
                  ),
                ),
              if (_controlsLocked)
                _buildUnlockButton(strings, mediaQuery.padding),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    AppLocalizations strings,
    EdgeInsets safePadding,
  ) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[_overlayScrim, _overlayClear],
      ),
    ),
    child: MobilePageHeader(
      safePadding: safePadding,
      backgroundColor: Colors.transparent,
      surfaceKey: const Key('mobile-remote-header'),
      child: Row(
        children: <Widget>[
          MobilePageBackButton(
            buttonKey: const Key('mobile-remote-back-action'),
            onPressed: _closing
                ? null
                : () => unawaited(_closeSession(pop: true)),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          ),
          const SizedBox(width: 4),
          Expanded(
            flex: 2,
            child: Text(
              strings.remoteDesktopTitle(
                widget.target.hostIdentity.displayName,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Align(
              alignment: Alignment.centerRight,
              child: _buildStatus(context, strings),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const Key('mobile-remote-diagnostics-action'),
            onPressed: _closing
                ? null
                : () => unawaited(
                    showDiagnosticsDialog(
                      context,
                      report: widget.controller.diagnosticsReport,
                    ),
                  ),
            tooltip: strings.diagnosticsAction,
            icon: const Icon(Icons.shield_outlined, size: 20),
          ),
          if (widget.controller.state == RemoteDesktopState.connected)
            SizedBox.square(
              dimension: _unlockButtonSize,
              child: IconButton(
                key: const Key('mobile-control-lock'),
                onPressed: _enterControlsLock,
                tooltip: strings.mobileLockControlsAction,
                icon: const Icon(Icons.lock_outline_rounded, size: 20),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _buildRemoteViewport(
    BuildContext context, {
    required bool dismissKeyboardOnTap,
  }) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      _buildRemoteArea(context),
      if (dismissKeyboardOnTap)
        Positioned.fill(
          child: GestureDetector(
            key: const Key('mobile-dismiss-keyboard-overlay'),
            behavior: HitTestBehavior.opaque,
            onTap: _dismissSoftwareKeyboard,
          ),
        ),
    ],
  );

  Widget _buildRemoteArea(BuildContext context) {
    final renderer = widget.controller.videoRenderer;
    if (renderer is RTCVideoRenderer && widget.videoAspectRatio == null) {
      return ListenableBuilder(
        listenable: renderer,
        builder: (context, _) => _remoteSurface(
          _rendererAspectRatio(renderer),
          _buildVideo(context, renderer),
        ),
      );
    }
    return _remoteSurface(
      _configuredAspectRatio,
      _buildVideo(context, renderer),
    );
  }

  Widget _remoteSurface(double aspectRatio, Widget video) =>
      MobileGestureSurface(
        video: video,
        videoAspectRatio: aspectRatio,
        sender: _connectedSender,
        controller: _gestureController,
        onInputFailure: _handleInputFailure,
      );

  Widget _buildVideo(BuildContext context, Object renderer) {
    final builder = widget.videoBuilder;
    if (builder != null) {
      return builder(context, renderer);
    }
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
    final colors = Theme.of(context).colorScheme;
    final accent = failed
        ? RoammandColors.emergency
        : connected
        ? RoammandColors.online
        : RoammandColors.auroraSoft;
    return SizedBox(
      height: _statusHeight,
      child: DecoratedBox(
        key: const Key('mobile-remote-status'),
        decoration: BoxDecoration(
          color: failed
              ? colors.errorContainer
              : connected
              ? RoammandColors.online.withValues(alpha: 0.14)
              : colors.surfaceContainerHighest.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(_statusRadius),
          border: Border.all(color: accent.withValues(alpha: 0.48)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: _statusHorizontalPadding,
            vertical: _statusVerticalPadding,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (connected) ...<Widget>[
                const Icon(Icons.circle, size: 8, color: RoammandColors.online),
                const SizedBox(width: 8),
              ],
              if (_isProgressState(widget.controller.state)) ...<Widget>[
                const RoammandProgressIndicator(size: 12),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  _statusText(strings),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              if (failed && widget.controller.canRetry) ...<Widget>[
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () => unawaited(_retrySession()),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(36, 24),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(strings.retryRemoteAction),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControlBar(AppLocalizations strings, EdgeInsets safePadding) =>
      DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: <Color>[_overlayScrim, _overlayClear],
          ),
        ),
        child: Material(
          key: const Key('mobile-remote-control-bar'),
          color: Colors.transparent,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              safePadding.left + _controlBarPadding,
              0,
              safePadding.right + _controlBarPadding,
              0,
            ),
            child: SizedBox(
              height: _controlBarHeight,
              child: Row(
                children: <Widget>[
                  const Icon(Icons.touch_app_outlined, size: 16),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      strings.mobileGestureHint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    key: const Key('mobile-keyboard-toggle'),
                    onPressed: _toggleKeyboardTray,
                    tooltip: _keyboardVisible
                        ? strings.mobileHideKeyboardAction
                        : strings.mobileKeyboardAction,
                    icon: Icon(
                      _keyboardVisible
                          ? Icons.keyboard_hide_outlined
                          : Icons.keyboard_outlined,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _buildUnlockButton(AppLocalizations strings, EdgeInsets safePadding) =>
      Positioned(
        right: safePadding.right + mobilePageHeaderHorizontalPadding,
        top: safePadding.top,
        width: _unlockButtonSize,
        height: _unlockButtonSize,
        child: Material(
          key: const Key('mobile-control-unlock-surface'),
          color: _unlockSurface,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: IconButton(
            key: const Key('mobile-control-unlock'),
            onPressed: _exitControlsLock,
            tooltip: strings.mobileUnlockControlsAction,
            color: Colors.white,
            icon: const Icon(Icons.lock_open_rounded, size: 20),
          ),
        ),
      );

  Widget _buildInputTray(EdgeInsets safePadding, {required bool compact}) =>
      MobileInputTray(
        key: const Key('mobile-input-tray'),
        controller: _keyboardController,
        enabled: _inputEnabled,
        textFocusNode: _textInputFocusNode,
        onDismissKeyboard: _dismissSoftwareKeyboard,
        onInputFailure: _handleInputFailure,
        compact: compact,
        padding: EdgeInsets.fromLTRB(
          safePadding.left + 8,
          compact ? 4 : 8,
          safePadding.right + 8,
          compact ? 4 : 8,
        ),
      );

  void _dismissSoftwareKeyboard() {
    _textInputFocusNode.unfocus();
    FocusManager.instance.primaryFocus?.unfocus(
      disposition: UnfocusDisposition.scope,
    );
    unawaited(
      SystemChannels.textInput
          .invokeMethod<void>(_textInputHideMethod)
          .catchError((_) {}),
    );
  }

  void _toggleKeyboardTray() {
    if (_keyboardVisible) {
      _dismissSoftwareKeyboard();
    }
    setState(() => _keyboardVisible = !_keyboardVisible);
  }

  void _enterControlsLock() {
    if (_controlsLocked ||
        _closing ||
        widget.controller.state != RemoteDesktopState.connected) {
      return;
    }
    _dismissSoftwareKeyboard();
    _releaseInput();
    setState(() {
      _keyboardVisible = false;
      _controlsLocked = true;
      _immersiveSystemUiActive = true;
    });
    unawaited(_setSystemUiMode(SystemUiMode.immersiveSticky));
  }

  void _exitControlsLock({bool rebuild = true}) {
    if (!_controlsLocked && !_immersiveSystemUiActive) {
      return;
    }
    final restoreSystemUi = _immersiveSystemUiActive;
    _controlsLocked = false;
    _immersiveSystemUiActive = false;
    if (rebuild && mounted) {
      setState(() {});
    }
    if (restoreSystemUi) {
      unawaited(_setSystemUiMode(SystemUiMode.edgeToEdge));
    }
  }

  void _restoreSystemUiIfNeeded() {
    if (!_immersiveSystemUiActive) return;
    _immersiveSystemUiActive = false;
    unawaited(_setSystemUiMode(SystemUiMode.edgeToEdge));
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

  double get _configuredAspectRatio {
    final ratio = widget.videoAspectRatio;
    return ratio != null && ratio.isFinite && ratio > 0 ? ratio : 16 / 9;
  }

  double _rendererAspectRatio(RTCVideoRenderer renderer) =>
      renderer.videoWidth > 0 && renderer.videoHeight > 0
      ? renderer.videoWidth / renderer.videoHeight
      : 16 / 9;

  bool get _inputEnabled =>
      widget.controller.state == RemoteDesktopState.connected &&
      _keyboardController != null;

  RemoteInputSender? get _connectedSender =>
      widget.controller.state == RemoteDesktopState.connected
      ? widget.controller.inputSender
      : null;

  void _onControllerChanged() {
    _syncKeyboardController();
    if (!mounted) return;
    if (_controlsLocked &&
        widget.controller.state != RemoteDesktopState.connected) {
      _exitControlsLock(rebuild: false);
    }
    if (!_closing && widget.controller.state == RemoteDesktopState.idle) {
      unawaited(_closeSession(pop: true));
      return;
    }
    setState(() {});
  }

  void _syncKeyboardController() {
    final sender = _connectedSender;
    if (identical(sender, _keyboardSender)) return;
    final previous = _keyboardController;
    _keyboardSender = sender;
    _keyboardController = sender == null
        ? null
        : MobileKeyboardController(sender);
    if (previous != null) {
      unawaited(previous.close());
    }
  }

  void _releaseInput() {
    _gestureController.cancel();
    unawaited(
      (_keyboardController?.releaseAll() ?? Future<void>.value()).catchError(
        _handleInputFailure,
      ),
    );
  }

  void _setPrivacyShieldVisible(bool visible) {
    if (!mounted) return;
    _privacyShieldVisible = visible;
    _syncPrivacyShield();
  }

  void _syncPrivacyShield() {
    if (!mounted) return;
    if (!_privacyShieldVisible) {
      _removePrivacyShield();
      return;
    }
    if (_privacyShieldEntry != null) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      if (_privacyShieldSyncScheduled) return;
      _privacyShieldSyncScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _privacyShieldSyncScheduled = false;
        _syncPrivacyShield();
      });
      return;
    }
    final entry = OverlayEntry(
      builder: (_) => const ModalBarrier(
        key: Key('mobile-remote-privacy-shield'),
        dismissible: false,
        color: Colors.black,
      ),
    );
    _privacyShieldEntry = entry;
    overlay.insert(entry);
  }

  void _removePrivacyShield() {
    _privacyShieldEntry?.remove();
    _privacyShieldEntry = null;
  }

  void _handleInputFailure(Object error) {
    if (error is InputSenderException &&
        error.code == InputSenderErrorCode.cancelled) {
      return;
    }
    if (kDebugMode) {
      final cause = switch (error) {
        InputSenderException(:final code) => code.name,
        PeerSessionException(:final code) => code.name,
        _ => error.runtimeType.toString(),
      };
      debugPrint('[remote] input_operation=send cause=$cause');
    }
    if (!_closing) {
      unawaited(_closeSession(pop: true));
    }
  }

  Future<void> _closeSession({required bool pop}) async {
    _popRequested = _popRequested || pop;
    if (!_closing) {
      _closing = true;
      _dismissSoftwareKeyboard();
      _exitControlsLock(rebuild: false);
      if (mounted) setState(() {});
      _releaseInput();
    }
    await _closeController();
    if (_popRequested && mounted && !_allowPop) {
      setState(() => _allowPop = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) {
        await Navigator.of(context).maybePop();
      }
    }
  }

  Future<void> _closeController() => _closeFuture ??= widget.controller.close();

  Future<void> _retrySession() async {
    if (_closing || !widget.controller.canRetry) {
      return;
    }
    try {
      await widget.controller.retry();
    } catch (_) {}
  }
}

Future<void> _setPreferredOrientations(
  List<DeviceOrientation> orientations,
) async {
  try {
    await SystemChrome.setPreferredOrientations(orientations);
  } catch (error) {
    if (kDebugMode) {
      debugPrint(
        '[remote] operation=setPreferredOrientations '
        'cause=${error.runtimeType}',
      );
    }
  }
}

Future<void> _setSystemUiMode(SystemUiMode mode) async {
  try {
    await SystemChrome.setEnabledSystemUIMode(mode);
  } catch (error) {
    if (kDebugMode) {
      debugPrint(
        '[remote] operation=setSystemUiMode cause=${error.runtimeType}',
      );
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

ThemeData _compactRemoteTheme(ThemeData theme) {
  final text = theme.textTheme;
  return theme.copyWith(
    visualDensity: VisualDensity.compact,
    textTheme: text.copyWith(
      titleLarge: text.titleLarge?.copyWith(fontSize: 16),
      titleMedium: text.titleMedium?.copyWith(fontSize: 16),
      titleSmall: text.titleSmall?.copyWith(fontSize: 12),
      bodyLarge: text.bodyLarge?.copyWith(fontSize: 12),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 12),
      bodySmall: text.bodySmall?.copyWith(fontSize: 12),
      labelLarge: text.labelLarge?.copyWith(fontSize: 12),
      labelMedium: text.labelMedium?.copyWith(fontSize: 12),
      labelSmall: text.labelSmall?.copyWith(fontSize: 12),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size.square(40),
        padding: const EdgeInsets.all(8),
        iconSize: 20,
      ),
    ),
  );
}
