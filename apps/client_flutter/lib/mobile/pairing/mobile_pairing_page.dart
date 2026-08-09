// SPDX-License-Identifier: MPL-2.0

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:roammand/design_system/roammand_colors.dart';
import 'package:roammand/design_system/roammand_progress_indicator.dart';
import 'package:roammand/design_system/roammand_surfaces.dart';
import 'package:roammand/l10n/generated/app_localizations.dart';
import 'package:roammand/mobile/identity/mobile_device_identity.dart';
import 'package:roammand/mobile/widgets/mobile_page_header.dart';
import 'package:roammand/network/network_service_controller.dart';
import 'package:roammand/pairing/controller_pairing_engine.dart';
import 'package:roammand/pairing/controller_pairing_models.dart';
import 'package:roammand/pairing/device_fingerprint.dart';
import 'package:roammand/pairing/pairing_signaling_client.dart';
import 'package:roammand/pairing/qr_pairing_uri.dart';
import 'package:roammand/pairing/trusted_host_repository.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

import 'qr_scanner.dart';

const _wordListAsset = 'assets/bip39-english.txt';
const _pagePadding = 16.0;
const _sectionSpacing = 16.0;
const _scannerMessageWidth = 440.0;
const _scannerOverlayPadding = 12.0;
const _scannerElementSpacing = 8.0;
const _scannerMessageHeight = 36.0;
const _scannerFeedbackHeight = 40.0;
const _scannerMinimumCutoutSize = 120.0;
const _scannerMaximumCutoutSize = 240.0;
const _scannerCutoutScreenFraction = 0.76;
const _scannerCutoutOuterSpacing = 16.0;
const _pairingTitleFontSize = 16.0;
const _pairingBodyFontSize = 12.0;

abstract interface class MobileControllerPairingSession {
  Stream<ControllerPairingSnapshot> get states;
  ControllerPairingSnapshot get snapshot;
  Future<ControllerPairingSnapshot> pairQr(HostPairingInvitation invitation);
  Future<void> cancel();
  Future<void> close();
}

typedef MobilePairingSessionFactory =
    Future<MobileControllerPairingSession> Function();

enum _ScannerRuntimeState { stopped, running, paused }

enum _ScannerTargetState { stopped, running, paused }

Future<MobileControllerPairingSession> createMobilePairingSession({
  required MobileDeviceIdentity identity,
  required TrustedHostRepository trustedHosts,
}) async {
  final words = (await rootBundle.loadString(
    _wordListAsset,
  )).trim().split('\n');
  return _EngineMobilePairingSession(
    ControllerPairingEngine(
      identity: identity,
      signaling: PairingSignalingClient(),
      trustedHosts: trustedHosts,
      sasWordList: words,
    ),
  );
}

final class MobilePairingPage extends StatefulWidget {
  const MobilePairingPage({
    required this.identity,
    required this.trustedHosts,
    this.networkServices,
    this.scanner,
    this.sessionFactory,
    this.nowUnixMs,
    super.key,
  });

  final MobileDeviceIdentity identity;
  final TrustedHostRepository trustedHosts;
  final NetworkServiceController? networkServices;
  final QrScannerSession? scanner;
  final MobilePairingSessionFactory? sessionFactory;
  final int Function()? nowUnixMs;

  @override
  State<MobilePairingPage> createState() => _MobilePairingPageState();
}

final class _MobilePairingPageState extends State<MobilePairingPage>
    with WidgetsBindingObserver {
  late final QrScannerSession _scanner;
  late final bool _ownsScanner;
  StreamSubscription<QrScannerEvent>? _scannerSubscription;
  StreamSubscription<ControllerPairingSnapshot>? _pairingSubscription;
  MobileControllerPairingSession? _session;
  ControllerPairingSnapshot _snapshot = ControllerPairingSnapshot(
    state: ControllerPairingState.idle,
  );
  QrScannerFailure? _scannerFailure;
  bool _invalidQr = false;
  bool _claimedCode = false;
  bool _confirmingCode = false;
  bool _creatingSession = false;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  _ScannerRuntimeState _scannerRuntimeState = _ScannerRuntimeState.stopped;
  Future<void> _scannerCommandTail = Future<void>.value();
  Future<void>? _scannerReconcileOperation;
  bool _scannerReconcileRequested = false;
  bool _scannerHasStarted = false;
  bool _successfulPairingCloseScheduled = false;
  bool _disposed = false;
  Timer? _countdown;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appLifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    _ownsScanner = widget.scanner == null;
    _scanner = widget.scanner ?? MobileQrScannerSession();
    _scannerSubscription = _scanner.events.listen(_onScannerEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) unawaited(_requestScannerReconciliation());
    });
  }

  Future<void> _requestScannerReconciliation() {
    _scannerReconcileRequested = true;
    return _scannerReconcileOperation ??= _reconcileScannerState();
  }

  Future<void> _reconcileScannerState() async {
    try {
      while (!_disposed) {
        _scannerReconcileRequested = false;
        final target = _scannerTargetState;
        await _applyScannerTarget(target);
        if (!_scannerReconcileRequested &&
            _scannerTargetSatisfied(_scannerTargetState)) {
          return;
        }
      }
    } finally {
      _scannerReconcileOperation = null;
      if (_scannerReconcileRequested && !_disposed) {
        unawaited(_requestScannerReconciliation());
      }
    }
  }

  _ScannerTargetState get _scannerTargetState {
    if (_claimedCode) return _ScannerTargetState.stopped;
    if (_confirmingCode || _appLifecycleState != AppLifecycleState.resumed) {
      return _ScannerTargetState.paused;
    }
    return _ScannerTargetState.running;
  }

  Future<void> _applyScannerTarget(_ScannerTargetState target) async {
    switch (target) {
      case _ScannerTargetState.running:
        if (_scannerRuntimeState == _ScannerRuntimeState.running) return;
        if (_scannerHasStarted) {
          await _enqueueScannerCommand(_scanner.resume);
        } else {
          await _enqueueScannerCommand(_scanner.start);
          _scannerHasStarted = true;
        }
        _scannerRuntimeState = _ScannerRuntimeState.running;
      case _ScannerTargetState.paused:
        if (_scannerRuntimeState != _ScannerRuntimeState.running) return;
        await _enqueueScannerCommand(_scanner.pause);
        _scannerRuntimeState = _ScannerRuntimeState.paused;
      case _ScannerTargetState.stopped:
        if (!_scannerHasStarted ||
            _scannerRuntimeState == _ScannerRuntimeState.stopped) {
          return;
        }
        await _enqueueScannerCommand(_scanner.stop);
        _scannerRuntimeState = _ScannerRuntimeState.stopped;
    }
  }

  Future<void> _enqueueScannerCommand(Future<void> Function() command) {
    final operation = _scannerCommandTail.then((_) => command());
    _scannerCommandTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _runScannerControl(Future<void> Function() command) async {
    await _requestScannerReconciliation();
    if (_disposed ||
        _scannerTargetState != _ScannerTargetState.running ||
        _scannerRuntimeState != _ScannerRuntimeState.running) {
      return;
    }
    await _enqueueScannerCommand(command);
    if (!_disposed) await _requestScannerReconciliation();
  }

  bool _scannerTargetSatisfied(_ScannerTargetState target) => switch (target) {
    _ScannerTargetState.running =>
      _scannerRuntimeState == _ScannerRuntimeState.running,
    _ScannerTargetState.paused =>
      _scannerRuntimeState != _ScannerRuntimeState.running,
    _ScannerTargetState.stopped =>
      _scannerRuntimeState == _ScannerRuntimeState.stopped,
  };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    if (!_disposed) unawaited(_requestScannerReconciliation());
  }

  void _onScannerEvent(QrScannerEvent event) {
    if (_disposed || _claimedCode || _confirmingCode) return;
    switch (event) {
      case QrScannerReady():
        if (mounted && _scannerFailure != null) {
          setState(() => _scannerFailure = null);
        }
      case QrScannerCode(:final value):
        if (_appLifecycleState == AppLifecycleState.resumed) {
          _acceptCode(value);
        }
      case QrScannerFailed(:final failure):
        if (mounted) setState(() => _scannerFailure = failure);
    }
  }

  Future<void> _acceptCode(String encoded) async {
    if (_claimedCode || _confirmingCode) return;
    late final HostPairingInvitation invitation;
    try {
      invitation = parseQrPairingUri(
        encoded,
        nowUnixMs:
            widget.nowUnixMs?.call() ?? DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      if (mounted) setState(() => _invalidQr = true);
      return;
    }
    if (_requiresServerConfirmation(invitation)) {
      _confirmingCode = true;
      await _requestScannerReconciliation();
      if (_disposed) return;
      final confirmed = await _confirmUnfamiliarServer(invitation);
      _confirmingCode = false;
      if (!confirmed) {
        if (!_disposed) await _requestScannerReconciliation();
        return;
      }
    }
    _claimedCode = true;
    if (mounted) {
      setState(() {
        _invalidQr = false;
        _scannerFailure = null;
        _creatingSession = true;
      });
    }
    await _requestScannerReconciliation();
    if (_disposed) return;
    try {
      final session =
          await (widget.sessionFactory?.call() ??
              createMobilePairingSession(
                identity: widget.identity,
                trustedHosts: widget.trustedHosts,
              ));
      if (_disposed) {
        await session.close();
        return;
      }
      _session = session;
      _snapshot = session.snapshot;
      _pairingSubscription = session.states.listen(_onSnapshot);
      if (mounted) setState(() => _creatingSession = false);
      await session.pairQr(invitation);
    } catch (_) {
      if (mounted) {
        setState(() {
          _creatingSession = false;
          _snapshot = ControllerPairingSnapshot(
            state: ControllerPairingState.failed,
            error: ControllerPairingError.internal,
          );
        });
      }
    }
  }

  bool _requiresServerConfirmation(HostPairingInvitation invitation) {
    final networkServices = widget.networkServices;
    if (networkServices == null) return false;
    final endpoint = Uri.parse(invitation.signalingEndpoint);
    if (endpoint == networkServices.configuration.signalingEndpoint) {
      return false;
    }
    return !widget.trustedHosts.hosts.any(
      (host) =>
          host.signalingEndpoint == endpoint &&
          _bytesEqual(
            host.hostIdentity.deviceId,
            invitation.hostIdentity.deviceId,
          ),
    );
  }

  Future<bool> _confirmUnfamiliarServer(
    HostPairingInvitation invitation,
  ) async {
    if (!mounted) return false;
    final strings = AppLocalizations.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(strings.mobileUnfamiliarServerTitle),
            content: Text(
              strings.mobileUnfamiliarServerBody(invitation.signalingEndpoint),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(strings.cancelAction),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(strings.mobileTrustServerAction),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _onSnapshot(ControllerPairingSnapshot snapshot) {
    if (!mounted) return;
    setState(() => _snapshot = snapshot);
    _countdown?.cancel();
    if (snapshot.state == ControllerPairingState.accepted) {
      _scheduleSuccessfulPairingClose();
      return;
    }
    if (!snapshot.isTerminal && snapshot.expiresAtUnixMs > 0) {
      _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _scheduleSuccessfulPairingClose() {
    if (_successfulPairingCloseScheduled) return;
    _successfulPairingCloseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _cancel() async {
    await _session?.cancel();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _disposed = true;
    final scannerOperation = _scannerReconcileOperation;
    WidgetsBinding.instance.removeObserver(this);
    _countdown?.cancel();
    unawaited(_scannerSubscription?.cancel());
    unawaited(_pairingSubscription?.cancel());
    unawaited(_session?.close());
    if (_ownsScanner) {
      unawaited(_closeOwnedScanner(scannerOperation));
    }
    super.dispose();
  }

  Future<void> _closeOwnedScanner(Future<void>? scannerOperation) async {
    try {
      await scannerOperation;
      await _scannerCommandTail;
    } finally {
      await _scanner.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Theme(
      data: _compactPairingTheme(Theme.of(context)),
      child: PopScope(
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_cancel());
        },
        child: _claimedCode
            ? Scaffold(
                body: RoammandBackdrop(
                  child: Column(
                    children: <Widget>[
                      MobilePageNavigationHeader(
                        safePadding: MediaQuery.paddingOf(context),
                        title: strings.mobileScanQrAction,
                        surfaceKey: const Key('mobile-pairing-header'),
                        backButtonKey: const Key('mobile-pairing-back'),
                        onBack: () => unawaited(_cancel()),
                      ),
                      Expanded(
                        child: SafeArea(
                          top: false,
                          child: Padding(
                            padding: const EdgeInsets.all(_pagePadding),
                            child: Builder(
                              builder: (context) =>
                                  _buildPairing(context, strings),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : Scaffold(
                backgroundColor: Colors.black,
                body: Builder(
                  builder: (context) => _buildScanner(context, strings),
                ),
              ),
      ),
    );
  }

  Widget _buildScanner(BuildContext context, AppLocalizations strings) {
    final safePadding = MediaQuery.paddingOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cutout = _scannerCutout(constraints.biggest, safePadding);
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(color: Colors.black, child: _scanner.buildPreview()),
            IgnorePointer(
              child: CustomPaint(
                key: const Key('mobile-scanner-mask'),
                painter: _ScannerOverlayPainter(cutout: cutout),
              ),
            ),
            Positioned.fromRect(
              rect: cutout,
              child: const IgnorePointer(
                child: SizedBox.expand(key: Key('mobile-scanner-focus-area')),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: MobilePageHeader(
                safePadding: safePadding,
                surfaceKey: const Key('mobile-scanner-header'),
                child: Row(
                  children: <Widget>[
                    MobilePageBackButton(
                      buttonKey: const Key('mobile-scanner-close'),
                      onPressed: () => unawaited(_cancel()),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                    ),
                    const Spacer(),
                    _scannerButton(
                      key: const Key('mobile-scanner-torch'),
                      onPressed: () =>
                          unawaited(_runScannerControl(_scanner.toggleTorch)),
                      tooltip: strings.mobileScannerTorchAction,
                      icon: Icons.flashlight_on_outlined,
                    ),
                    const SizedBox(width: _scannerElementSpacing),
                    _scannerButton(
                      key: const Key('mobile-scanner-switch-camera'),
                      onPressed: () =>
                          unawaited(_runScannerControl(_scanner.switchCamera)),
                      tooltip: strings.mobileScannerSwitchCameraAction,
                      icon: Icons.cameraswitch_outlined,
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: _scannerOverlayPadding,
              right: _scannerOverlayPadding,
              bottom:
                  safePadding.bottom +
                  _scannerOverlayPadding +
                  _scannerMessageHeight +
                  _scannerElementSpacing,
              child: _buildScannerFeedback(context, strings),
            ),
            Positioned(
              left: _scannerOverlayPadding,
              right: _scannerOverlayPadding,
              bottom: safePadding.bottom + _scannerOverlayPadding,
              child: _buildScannerMessage(context, strings),
            ),
          ],
        );
      },
    );
  }

  Widget _buildScannerMessage(BuildContext context, AppLocalizations strings) =>
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _scannerMessageWidth),
          child: SizedBox(
            key: const Key('mobile-scanner-message'),
            height: _scannerMessageHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                  child: Text(
                    strings.mobileScannerInstructions,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _buildScannerFeedback(BuildContext context, AppLocalizations strings) {
    final text = _scannerFeedbackText(strings);
    return SizedBox(
      height: _scannerFeedbackHeight,
      child: Center(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          child: text == null
              ? const SizedBox.shrink(key: Key('mobile-scanner-feedback-empty'))
              : ConstrainedBox(
                  key: const Key('mobile-scanner-feedback'),
                  constraints: const BoxConstraints(
                    maxWidth: _scannerMessageWidth,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.78),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: RoammandColors.emergency.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: RoammandColors.emergency,
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  String? _scannerFeedbackText(AppLocalizations strings) {
    if (_invalidQr) return strings.mobileInvalidQr;
    final failure = _scannerFailure;
    return failure == null ? null : _scannerFailureText(strings, failure);
  }

  Widget _scannerButton({
    required Key key,
    required VoidCallback onPressed,
    required String tooltip,
    required IconData icon,
  }) => IconButton(
    key: key,
    onPressed: onPressed,
    tooltip: tooltip,
    constraints: const BoxConstraints.tightFor(
      width: mobilePageHeaderActionSize,
      height: mobilePageHeaderActionSize,
    ),
    padding: const EdgeInsets.all(8),
    icon: Icon(icon, color: RoammandColors.textPrimary, size: 20),
  );

  Widget _buildPairing(BuildContext context, AppLocalizations strings) {
    if (_creatingSession) return _progress(strings.mobilePairingJoining);
    final text = switch (_snapshot.state) {
      ControllerPairingState.idle ||
      ControllerPairingState.connecting ||
      ControllerPairingState.waitingHostInvitation =>
        strings.mobilePairingJoining,
      ControllerPairingState.verifyingHost => strings.mobilePairingVerifying,
      ControllerPairingState.waitingHostDecision =>
        strings.mobilePairingWaitingApproval,
      ControllerPairingState.accepted => strings.mobilePairingSuccess,
      ControllerPairingState.rejected => strings.mobilePairingRejected,
      ControllerPairingState.expired => strings.mobilePairingExpired,
      ControllerPairingState.cancelled => strings.mobilePairingCancelled,
      ControllerPairingState.failed => _pairingFailureText(
        strings,
        _snapshot.error,
      ),
    };
    final host = _snapshot.hostIdentity;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            _snapshot.state == ControllerPairingState.accepted
                ? Icons.check_circle_outline
                : _snapshot.isTerminal
                ? Icons.error_outline
                : Icons.verified_user_outlined,
            size: 56,
          ),
          if (host != null) ...<Widget>[
            const SizedBox(height: _sectionSpacing),
            Text(
              host.displayName,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (_snapshot.hostFingerprintSha256.isNotEmpty)
              SelectableText(
                strings.hostShortFingerprint(
                  formatShortDeviceFingerprint(_snapshot.hostFingerprintSha256),
                ),
                textAlign: TextAlign.center,
              ),
          ],
          const SizedBox(height: _sectionSpacing),
          if (!_snapshot.isTerminal) const RoammandProgressIndicator(),
          const SizedBox(height: _sectionSpacing),
          Text(text, textAlign: TextAlign.center),
          if (!_snapshot.isTerminal && _remainingSeconds > 0) ...<Widget>[
            const SizedBox(height: 8),
            Text(strings.pairingSecondsRemaining(_remainingSeconds)),
          ],
          if (_snapshot.isTerminal) ...<Widget>[
            const SizedBox(height: _sectionSpacing),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(MaterialLocalizations.of(context).closeButtonLabel),
            ),
          ],
        ],
      ),
    );
  }

  Widget _progress(String text) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const RoammandProgressIndicator(),
        const SizedBox(height: _sectionSpacing),
        Text(text, textAlign: TextAlign.center),
      ],
    ),
  );

  int get _remainingSeconds {
    if (_snapshot.expiresAtUnixMs <= 0) return 0;
    final now =
        widget.nowUnixMs?.call() ?? DateTime.now().millisecondsSinceEpoch;
    final remaining = _snapshot.expiresAtUnixMs - now;
    return remaining <= 0 ? 0 : (remaining / 1000).ceil();
  }
}

String _pairingFailureText(
  AppLocalizations strings,
  ControllerPairingError? error,
) => switch (error) {
  ControllerPairingError.invalidInvitation => strings.mobileInvalidQr,
  ControllerPairingError.signaling => strings.mobilePairingSignalingFailed,
  ControllerPairingError.authentication =>
    strings.mobilePairingAuthenticationFailed,
  ControllerPairingError.persistence => strings.mobilePairingPersistenceFailed,
  ControllerPairingError.expired => strings.mobilePairingExpired,
  ControllerPairingError.cancelled => strings.mobilePairingCancelled,
  ControllerPairingError.internal => strings.mobilePairingInternalFailed,
  null => strings.mobilePairingFailed,
};

String _scannerFailureText(
  AppLocalizations strings,
  QrScannerFailure failure,
) => switch (failure) {
  QrScannerFailure.permissionDenied ||
  QrScannerFailure.permanentlyDenied => strings.mobileScannerPermissionDenied,
  QrScannerFailure.restricted => strings.mobileScannerRestricted,
  QrScannerFailure.noCamera => strings.mobileScannerNoCamera,
  QrScannerFailure.initialization => strings.mobileScannerInitializationFailed,
};

final class _EngineMobilePairingSession
    implements MobileControllerPairingSession {
  _EngineMobilePairingSession(this._engine);
  final ControllerPairingEngine _engine;
  @override
  Stream<ControllerPairingSnapshot> get states => _engine.states;
  @override
  ControllerPairingSnapshot get snapshot => _engine.snapshot;
  @override
  Future<ControllerPairingSnapshot> pairQr(HostPairingInvitation invitation) =>
      _engine.pairQr(invitation);
  @override
  Future<void> cancel() => _engine.cancel();
  @override
  Future<void> close() => _engine.close();
}

Rect _scannerCutout(Size size, EdgeInsets safePadding) {
  if (size.isEmpty) return Rect.zero;
  final top = safePadding.top + mobilePageHeaderHeight + _scannerElementSpacing;
  final bottom =
      safePadding.bottom +
      _scannerOverlayPadding +
      _scannerMessageHeight +
      _scannerFeedbackHeight +
      (_scannerElementSpacing * 2);
  final availableWidth = math.max(
    0.0,
    size.width - (_scannerOverlayPadding * 2),
  );
  final availableHeight = math.max(0.0, size.height - top - bottom);
  final shortestAvailable = math.min(availableWidth, availableHeight);
  final maximumAvailable = math.max(
    0.0,
    shortestAvailable - _scannerCutoutOuterSpacing,
  );
  final preferredSize = math.max(
    _scannerMinimumCutoutSize,
    shortestAvailable * _scannerCutoutScreenFraction,
  );
  final cutoutSize = math.min(
    maximumAvailable,
    math.min(_scannerMaximumCutoutSize, preferredSize),
  );
  return Rect.fromCenter(
    center: Offset(size.width / 2, top + (availableHeight / 2)),
    width: cutoutSize,
    height: cutoutSize,
  );
}

final class _ScannerOverlayPainter extends CustomPainter {
  const _ScannerOverlayPainter({required this.cutout});

  final Rect cutout;
  static const _cornerLength = 28.0;
  static const _cornerRadius = 16.0;

  @override
  void paint(Canvas canvas, Size size) {
    final cutoutRRect = RRect.fromRectAndRadius(
      cutout,
      const Radius.circular(_cornerRadius),
    );
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(cutoutRRect);
    canvas.drawPath(mask, Paint()..color = const Color(0x8F000000));

    final corners = Path()
      ..moveTo(cutout.left, cutout.top + _cornerLength)
      ..lineTo(cutout.left, cutout.top + _cornerRadius)
      ..quadraticBezierTo(
        cutout.left,
        cutout.top,
        cutout.left + _cornerRadius,
        cutout.top,
      )
      ..lineTo(cutout.left + _cornerLength, cutout.top)
      ..moveTo(cutout.right - _cornerLength, cutout.top)
      ..lineTo(cutout.right - _cornerRadius, cutout.top)
      ..quadraticBezierTo(
        cutout.right,
        cutout.top,
        cutout.right,
        cutout.top + _cornerRadius,
      )
      ..lineTo(cutout.right, cutout.top + _cornerLength)
      ..moveTo(cutout.right, cutout.bottom - _cornerLength)
      ..lineTo(cutout.right, cutout.bottom - _cornerRadius)
      ..quadraticBezierTo(
        cutout.right,
        cutout.bottom,
        cutout.right - _cornerRadius,
        cutout.bottom,
      )
      ..lineTo(cutout.right - _cornerLength, cutout.bottom)
      ..moveTo(cutout.left + _cornerLength, cutout.bottom)
      ..lineTo(cutout.left + _cornerRadius, cutout.bottom)
      ..quadraticBezierTo(
        cutout.left,
        cutout.bottom,
        cutout.left,
        cutout.bottom - _cornerRadius,
      )
      ..lineTo(cutout.left, cutout.bottom - _cornerLength);
    canvas.drawPath(
      corners,
      Paint()
        ..color = RoammandColors.signalCyan
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_ScannerOverlayPainter oldDelegate) =>
      oldDelegate.cutout != cutout;
}

ThemeData _compactPairingTheme(ThemeData theme) {
  final text = theme.textTheme;
  return theme.copyWith(
    visualDensity: VisualDensity.compact,
    textTheme: text.copyWith(
      titleLarge: text.titleLarge?.copyWith(fontSize: _pairingTitleFontSize),
      titleMedium: text.titleMedium?.copyWith(fontSize: _pairingTitleFontSize),
      bodyLarge: text.bodyLarge?.copyWith(fontSize: _pairingBodyFontSize),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: _pairingBodyFontSize),
      bodySmall: text.bodySmall?.copyWith(fontSize: _pairingBodyFontSize),
      labelLarge: text.labelLarge?.copyWith(fontSize: _pairingBodyFontSize),
      labelMedium: text.labelMedium?.copyWith(fontSize: _pairingBodyFontSize),
    ),
  );
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}
