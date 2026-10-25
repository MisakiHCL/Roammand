// SPDX-License-Identifier: MPL-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart';
import 'package:roammand/controller/session/controller_session_identity.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

import '../../diagnostics/diagnostics_collector.dart';
import '../../diagnostics/diagnostics_model.dart';
import 'controller_signaling_link.dart';
import 'input_sender.dart';
import 'peer_session.dart';
import 'reconnect_policy.dart';
import 'session_authenticator.dart';
import 'signaling_client.dart';

export 'controller_signaling_link.dart';
export '../../diagnostics/diagnostics_model.dart' show DiagnosticsReport;

part 'remote_desktop_diagnostics.dart';
part 'remote_desktop_models.dart';

const _sessionIdBytes = 16;
const _nonceBytes = 32;
const _authenticationLifetime = Duration(seconds: 30);
const _maximumPendingLocalCandidates = 64;
const _diagnosticsStatsInterval = Duration(seconds: 5);
const _appVersion = String.fromEnvironment(
  'ROAMMAND_APP_VERSION',
  defaultValue: '0.0.1',
);

final class _RemoteDesktopOperationCancelled implements Exception {
  const _RemoteDesktopOperationCancelled();
}

final class RemoteDesktopController extends ChangeNotifier
    implements RemoteDesktopViewModel {
  factory RemoteDesktopController({
    required ControllerSessionIdentity identity,
    required ControllerSignalingLink signaling,
    required ControllerPeerSession peer,
    Uint8List Function(int length)? randomBytes,
    int Function()? nowUnixMs,
    ReconnectScheduler? reconnectScheduler,
    DiagnosticsCollector? diagnostics,
  }) => RemoteDesktopController._(
    identity,
    signaling,
    peer,
    randomBytes ?? _secureRandomBytes,
    nowUnixMs ?? _systemNowUnixMs,
    reconnectScheduler ?? const TimerReconnectScheduler(),
    diagnostics,
  );

  RemoteDesktopController._(
    this._identity,
    this._signaling,
    this._peer,
    this._randomBytes,
    this._nowUnixMs,
    this._reconnectScheduler,
    DiagnosticsCollector? diagnostics,
  ) : _diagnostics =
          diagnostics ??
          DiagnosticsCollector(
            metadata: DiagnosticsMetadata(
              appVersion: _appVersion,
              protocolMajor: protocolMajorVersion,
              protocolMinor: minimumProtocolMinorVersion,
              osFamily: _currentOsFamily(),
            ),
            nowUnixMs: _nowUnixMs,
          );

  final ControllerSessionIdentity _identity;
  final ControllerSignalingLink _signaling;
  final ControllerPeerSession _peer;
  final Uint8List Function(int length) _randomBytes;
  final int Function() _nowUnixMs;
  final ReconnectScheduler _reconnectScheduler;
  final DiagnosticsCollector _diagnostics;
  final List<IceCandidate> _pendingLocalCandidates = <IceCandidate>[];

  RemoteDesktopState _state = RemoteDesktopState.idle;
  RemoteDesktopErrorCode? _errorCode;
  RemoteReconnectProgress? _reconnectProgress;
  RemoteDesktopTarget? _target;
  DeviceIdentity? _controllerIdentity;
  Uint8List? _sessionId;
  SessionOfferAuthentication? _offer;
  SessionAnswerAuthentication? _answer;
  SessionReconnectAuthentication? _reconnect;
  WebRtcSessionDescription? _answerDescription;
  RemoteInputSender? _inputSender;
  StreamSubscription<SignalingRoutedSession>? _signalingSubscription;
  StreamSubscription<ControllerPeerEvent>? _peerSubscription;
  StreamSubscription<IceCandidate>? _candidateSubscription;
  Future<void>? _closeFuture;
  Future<void>? _resourceCloseFuture;
  ReconnectAttemptSequence? _reconnectSequence;
  ReconnectTimer? _reconnectTimer;
  bool _reconnectConnectionGracePending = false;
  Timer? _diagnosticsTimer;
  bool _offerSent = false;
  bool _answerApplicationInFlight = false;
  bool _signalingRecoveryRequired = false;
  bool _resourcesClosed = false;
  bool _closeRequested = false;
  bool _disposed = false;
  bool _statsCollectionInFlight = false;
  int _requestSequence = 0;
  int _operationGeneration = 0;
  int _reconnectGeneration = 0;
  RemoteDesktopErrorCode _reconnectFailureCode = RemoteDesktopErrorCode.peer;

  @override
  RemoteDesktopState get state => _state;
  @override
  RemoteDesktopErrorCode? get errorCode => _errorCode;
  @override
  RemoteReconnectProgress? get reconnectProgress => _reconnectProgress;
  @override
  bool get canRetry => false;
  @override
  DiagnosticsReport get diagnosticsReport => _diagnostics.snapshot();
  @override
  Object get videoRenderer => _peer.videoRenderer;
  @override
  RemoteInputSender? get inputSender => _inputSender;

  @override
  Future<void> retry() async {
    throw const RemoteDesktopException(RemoteDesktopErrorCode.configuration);
  }

  @override
  Future<void> connect(RemoteDesktopTarget target) async {
    if (_state != RemoteDesktopState.idle || _closeFuture != null) {
      throw const RemoteDesktopException(RemoteDesktopErrorCode.configuration);
    }
    target.validate();
    final operationGeneration = ++_operationGeneration;
    _target = target;
    _setState(RemoteDesktopState.connecting);
    var operation = _RemoteDebugOperation.openIdentity;
    try {
      final controllerIdentity = await _identity.open();
      _requireActiveOperation(operationGeneration);
      validateDeviceIdentity(controllerIdentity);
      _controllerIdentity = controllerIdentity.deepCopy();
      _sessionId = _checkedRandom(_sessionIdBytes);
      _signalingSubscription = _signaling.routedSessions.listen(
        (event) {
          if (_operationIsCurrent(operationGeneration)) {
            unawaited(_handleRouted(event, operationGeneration));
          }
        },
        onError: (Object error) {
          if (!_operationIsCurrent(operationGeneration)) return;
          _debugRemoteFailure(_RemoteDebugOperation.signalingStream, error);
          if (error is SignalingRemoteException) {
            _diagnostics.recordError(
              DiagnosticsErrorCategory.signaling,
              _diagnosticSignalingRemoteError(error.code),
            );
          }
          unawaited(_handleRecoverableFailure(signaling: true));
        },
        onDone: () {
          if (!_operationIsCurrent(operationGeneration)) return;
          _debugRemoteReason(_RemoteDebugOperation.signalingStream, 'closed');
          unawaited(_handleRecoverableFailure(signaling: true));
        },
      );
      _peerSubscription = _peer.events.listen(
        (event) {
          if (_operationIsCurrent(operationGeneration)) {
            _handlePeerEvent(event);
          }
        },
        onError: (Object error) {
          if (!_operationIsCurrent(operationGeneration)) return;
          _debugRemoteFailure(_RemoteDebugOperation.peerStream, error);
          unawaited(_handleRecoverableFailure());
        },
      );
      _candidateSubscription = _peer.localCandidates.listen(
        (candidate) {
          if (_operationIsCurrent(operationGeneration)) {
            unawaited(_handleLocalCandidate(candidate));
          }
        },
        onError: (Object error) {
          if (!_operationIsCurrent(operationGeneration)) return;
          _debugRemoteFailure(_RemoteDebugOperation.candidateStream, error);
          unawaited(_handleRecoverableFailure());
        },
      );
      operation = _RemoteDebugOperation.connectSignaling;
      await _signaling.connect(controllerIdentity.deviceId);
      _requireActiveOperation(operationGeneration);
      operation = _RemoteDebugOperation.createPeerOffer;
      final peerOffer = await _peer.start();
      _requireActiveOperation(operationGeneration);
      _setState(RemoteDesktopState.authenticating);
      operation = _RemoteDebugOperation.sendAuthenticatedOffer;
      await _sendAuthenticatedOffer(peerOffer, operationGeneration);
      _requireActiveOperation(operationGeneration);
      _setState(RemoteDesktopState.negotiating);
    } on _RemoteDesktopOperationCancelled {
      return;
    } on RemoteDesktopException catch (error) {
      _debugRemoteFailure(operation, error);
      await _fail(error.code);
    } on ControllerSessionIdentityException catch (error) {
      _debugRemoteFailure(operation, error);
      await _fail(RemoteDesktopErrorCode.localIdentity);
    } on SignalingClientException catch (error) {
      _debugRemoteFailure(operation, error);
      await _fail(RemoteDesktopErrorCode.signaling);
    } on SessionAnswerAuthenticationException catch (error) {
      _debugRemoteFailure(operation, error);
      await _fail(RemoteDesktopErrorCode.authentication);
    } on PeerSessionException catch (error) {
      _debugRemoteFailure(operation, error);
      await _fail(RemoteDesktopErrorCode.peer);
    } catch (error) {
      _debugRemoteFailure(operation, error);
      await _fail(RemoteDesktopErrorCode.peer);
    }
  }

  Future<void> _sendAuthenticatedOffer(
    ControllerPeerOffer peerOffer,
    int operationGeneration,
  ) async {
    final controllerIdentity = _controllerIdentity!;
    final target = _target!;
    final offer = _createOffer(controllerIdentity, target, peerOffer);
    final transcript = encodeSessionOfferTranscript(offer);
    final signature = await _identity.signOffer(transcript);
    _requireActiveOperation(operationGeneration);
    await _validateLocalSignature(signature, controllerIdentity, transcript);
    _requireActiveOperation(operationGeneration);
    offer.signature = signature;
    _offer = offer;
    _answer = null;
    _reconnect = null;
    _answerDescription = null;
    await _relay(sessionAuthentication: SessionAuthentication(offer: offer));
    _requireActiveOperation(operationGeneration);
    await _relay(
      webRtcNegotiation: WebRtcNegotiation(
        sessionId: offer.sessionId,
        description: WebRtcSessionDescription(
          type: SessionDescriptionType.SESSION_DESCRIPTION_TYPE_OFFER,
          sdp: peerOffer.sdp,
          dtlsFingerprintSha256: peerOffer.dtlsFingerprintSha256,
        ),
      ),
    );
    _requireActiveOperation(operationGeneration);
    _offerSent = true;
    for (final candidate in List<IceCandidate>.of(_pendingLocalCandidates)) {
      await _relayCandidate(candidate);
      _requireActiveOperation(operationGeneration);
    }
    _pendingLocalCandidates.clear();
  }

  SessionOfferAuthentication _createOffer(
    DeviceIdentity controller,
    RemoteDesktopTarget target,
    ControllerPeerOffer peerOffer,
  ) {
    final now = _nowUnixMs();
    return SessionOfferAuthentication(
      controllerDeviceId: controller.deviceId,
      hostDeviceId: target.hostIdentity.deviceId,
      sessionId: _sessionId,
      nonce: _checkedRandom(_nonceBytes),
      issuedAtUnixMs: Int64(now),
      expiresAtUnixMs: Int64(now + _authenticationLifetime.inMilliseconds),
      requestedPermissions: const <SessionPermission>[
        SessionPermission.SESSION_PERMISSION_VIEW_SCREEN,
        SessionPermission.SESSION_PERMISSION_CONTROL_INPUT,
      ],
      // Rust authenticates the SDP's UTF-8 wire bytes. Using Dart UTF-16 code
      // units here would make otherwise valid non-ASCII SDP fail binding.
      offerSha256: hashes.sha256.convert(utf8.encode(peerOffer.sdp)).bytes,
      controllerDtlsFingerprintSha256: peerOffer.dtlsFingerprintSha256,
    );
  }

  Future<void> _handleRouted(
    SignalingRoutedSession routed,
    int operationGeneration,
  ) async {
    if (_state == RemoteDesktopState.closing ||
        _state == RemoteDesktopState.failed ||
        _state == RemoteDesktopState.idle) {
      return;
    }
    var operation = _RemoteDebugOperation.decodeRoutedEnvelope;
    try {
      final target = _target!;
      final controller = _controllerIdentity!;
      final sessionId = _sessionId!;
      final envelope = decodeAndValidateSignalingEnvelope(
        routed.opaqueEnvelope,
      );
      if (!_bytesEqual(routed.senderDeviceId, target.hostIdentity.deviceId) ||
          !_bytesEqual(envelope.senderDeviceId, target.hostIdentity.deviceId) ||
          !_bytesEqual(envelope.recipientDeviceId, controller.deviceId)) {
        throw const RemoteDesktopException(
          RemoteDesktopErrorCode.authentication,
        );
      }
      switch (envelope.whichPayload()) {
        case SignalingEnvelope_Payload.sessionAuthentication:
          final authentication = envelope.sessionAuthentication;
          switch (authentication.whichPayload()) {
            case SessionAuthentication_Payload.answer:
              if (!_bytesEqual(authentication.answer.sessionId, sessionId)) {
                throw const RemoteDesktopException(
                  RemoteDesktopErrorCode.authentication,
                );
              }
              _answer = authentication.answer.deepCopy();
            case SessionAuthentication_Payload.reconnect:
              if (_reconnectSequence == null ||
                  !_bytesEqual(authentication.reconnect.sessionId, sessionId)) {
                throw const RemoteDesktopException(
                  RemoteDesktopErrorCode.authentication,
                );
              }
              _reconnect = authentication.reconnect.deepCopy();
            case SessionAuthentication_Payload.offer:
            case SessionAuthentication_Payload.notSet:
              throw const RemoteDesktopException(
                RemoteDesktopErrorCode.authentication,
              );
          }
          operation = _RemoteDebugOperation.applyRemoteAnswer;
          await _tryApplyAnswer(operationGeneration);
        case SignalingEnvelope_Payload.webrtcNegotiation:
          final negotiation = envelope.webrtcNegotiation;
          if (!_bytesEqual(negotiation.sessionId, sessionId)) {
            throw const RemoteDesktopException(
              RemoteDesktopErrorCode.authentication,
            );
          }
          switch (negotiation.whichPayload()) {
            case WebRtcNegotiation_Payload.description:
              if (negotiation.description.type !=
                  SessionDescriptionType.SESSION_DESCRIPTION_TYPE_ANSWER) {
                throw const RemoteDesktopException(
                  RemoteDesktopErrorCode.authentication,
                );
              }
              _answerDescription = negotiation.description.deepCopy();
              operation = _RemoteDebugOperation.applyRemoteAnswer;
              await _tryApplyAnswer(operationGeneration);
            case WebRtcNegotiation_Payload.iceCandidate:
              operation = _RemoteDebugOperation.addRemoteCandidate;
              await _peer.addRemoteCandidate(negotiation.iceCandidate);
              _requireActiveOperation(operationGeneration);
            case WebRtcNegotiation_Payload.endOfCandidates:
            case WebRtcNegotiation_Payload.notSet:
              break;
          }
        case SignalingEnvelope_Payload.error:
          _debugRemoteReason(
            _RemoteDebugOperation.remoteError,
            envelope.error.code.name,
          );
          if (_reconnectSequence != null && envelope.error.retryable) {
            await _handleRecoverableFailure(signaling: true);
            return;
          }
          throw const RemoteDesktopException(RemoteDesktopErrorCode.remote);
        case SignalingEnvelope_Payload.sessionStatus:
          final status = envelope.sessionStatus;
          if (!_bytesEqual(status.sessionId, sessionId)) {
            throw const RemoteDesktopException(
              RemoteDesktopErrorCode.authentication,
            );
          }
          if (status.state == SessionState.SESSION_STATE_CLOSING) {
            await _closeResources(setIdle: true, notifyRemote: false);
            return;
          }
          if (status.state == SessionState.SESSION_STATE_FAILED) {
            throw const RemoteDesktopException(RemoteDesktopErrorCode.remote);
          }
        case SignalingEnvelope_Payload.capabilityNegotiation:
        case SignalingEnvelope_Payload.pairing:
        case SignalingEnvelope_Payload.notSet:
          throw const RemoteDesktopException(RemoteDesktopErrorCode.signaling);
      }
    } on RemoteDesktopException catch (error) {
      _debugRemoteFailure(operation, error);
      await _fail(error.code);
    } on SessionAnswerAuthenticationException catch (error) {
      _debugRemoteFailure(operation, error);
      await _fail(RemoteDesktopErrorCode.authentication);
    } on SessionReconnectAuthenticationException catch (error) {
      _debugRemoteFailure(operation, error);
      await _fail(RemoteDesktopErrorCode.authentication);
    } on ProtocolValidationException catch (error) {
      _debugRemoteFailure(operation, error);
      await _fail(RemoteDesktopErrorCode.signaling);
    } on PeerSessionException catch (error) {
      _debugRemoteFailure(operation, error);
      await _fail(RemoteDesktopErrorCode.peer);
    } catch (error) {
      _debugRemoteFailure(operation, error);
      await _fail(RemoteDesktopErrorCode.peer);
    }
  }

  Future<void> _tryApplyAnswer(int operationGeneration) async {
    final answer = _answer;
    final reconnect = _reconnect;
    final description = _answerDescription;
    final offer = _offer;
    final target = _target;
    if ((answer == null && reconnect == null) ||
        description == null ||
        offer == null ||
        target == null) {
      return;
    }
    if (_answerApplicationInFlight) return;
    _answerApplicationInFlight = true;
    try {
      final fingerprint = extractSha256DtlsFingerprint(description.sdp);
      if (!_bytesEqual(fingerprint, description.dtlsFingerprintSha256)) {
        throw const RemoteDesktopException(
          RemoteDesktopErrorCode.authentication,
        );
      }
      if (reconnect != null) {
        final verified =
            await SessionReconnectVerifier(
              expectedHost: target.hostIdentity,
            ).verify(
              offer: offer,
              reconnect: reconnect,
              answerSdp: description.sdp,
              hostDtlsFingerprintSha256: fingerprint,
              previousGeneration: _reconnectGeneration,
              nowUnixMs: _nowUnixMs(),
            );
        _requireActiveOperation(operationGeneration);
        _reconnectGeneration = verified.generation;
      } else {
        await SessionAnswerVerifier(expectedHost: target.hostIdentity).verify(
          offer: offer,
          answer: answer!,
          answerSdp: description.sdp,
          hostDtlsFingerprintSha256: fingerprint,
          nowUnixMs: _nowUnixMs(),
        );
        _requireActiveOperation(operationGeneration);
        if (_reconnectSequence != null) {
          _reconnectGeneration = 0;
        }
      }
      await _peer.applyVerifiedAnswer(description.sdp);
      _requireActiveOperation(operationGeneration);
      _inputSender ??= RemoteInputSender(
        sessionId: offer.sessionId,
        reliable: _peer.reliableInput,
        fast: _peer.fastInput,
        onReliableFailure: () => unawaited(_fail(RemoteDesktopErrorCode.peer)),
      );
      _answer = null;
      _reconnect = null;
      _answerDescription = null;
      if (_reconnectSequence != null) {
        _reconnectConnectionGracePending = true;
      }
      _setState(RemoteDesktopState.connecting);
    } finally {
      _answerApplicationInFlight = false;
    }
  }

  Future<void> _handleLocalCandidate(IceCandidate candidate) async {
    if (!_offerSent) {
      if (_pendingLocalCandidates.length >= _maximumPendingLocalCandidates) {
        await _fail(RemoteDesktopErrorCode.peer);
        return;
      }
      _pendingLocalCandidates.add(candidate.deepCopy());
      return;
    }
    try {
      await _relayCandidate(candidate);
    } catch (error) {
      _debugRemoteFailure(_RemoteDebugOperation.relayLocalCandidate, error);
      if (_reconnectSequence != null) {
        await _handleRecoverableFailure(signaling: true);
      } else {
        await _fail(RemoteDesktopErrorCode.signaling);
      }
    }
  }

  Future<void> _relayCandidate(IceCandidate candidate) => _relay(
    webRtcNegotiation: WebRtcNegotiation(
      sessionId: _sessionId,
      iceCandidate: candidate,
    ),
  );

  Future<void> _relay({
    SessionAuthentication? sessionAuthentication,
    WebRtcNegotiation? webRtcNegotiation,
    SessionStatus? sessionStatus,
  }) async {
    final controller = _controllerIdentity!;
    final target = _target!;
    final envelope = SignalingEnvelope(
      protocolVersion: ProtocolVersion(
        major: protocolMajorVersion,
        minor: minimumProtocolMinorVersion,
      ),
      senderDeviceId: controller.deviceId,
      recipientDeviceId: target.hostIdentity.deviceId,
      requestId: 'session-${++_requestSequence}',
      sentAtUnixMs: Int64(_nowUnixMs()),
      sessionAuthentication: sessionAuthentication,
      webrtcNegotiation: webRtcNegotiation,
      sessionStatus: sessionStatus,
    );
    final encoded = Uint8List.fromList(envelope.writeToBuffer());
    decodeAndValidateSignalingEnvelope(encoded);
    await _signaling.relay(target.hostIdentity.deviceId, encoded);
  }

  void _handlePeerEvent(ControllerPeerEvent event) {
    _debugRemoteReason(_RemoteDebugOperation.peerEvent, event.name);
    switch (event) {
      case ControllerPeerEvent.connected:
        if (_state == RemoteDesktopState.connecting) {
          if (_reconnectSequence != null) {
            _completeReconnect();
          } else {
            _setState(RemoteDesktopState.connected);
          }
        } else if (_state == RemoteDesktopState.reconnecting) {
          _completeReconnect();
        }
      case ControllerPeerEvent.disconnected:
      case ControllerPeerEvent.failed:
        unawaited(_handleRecoverableFailure());
    }
  }

  Future<void> _handleRecoverableFailure({bool signaling = false}) async {
    if (_state == RemoteDesktopState.failed ||
        _state == RemoteDesktopState.closing ||
        _state == RemoteDesktopState.idle) {
      return;
    }
    final operationGeneration = _operationGeneration;
    if (_inputSender == null && _state != RemoteDesktopState.reconnecting) {
      await _fail(
        signaling
            ? RemoteDesktopErrorCode.signaling
            : RemoteDesktopErrorCode.peer,
      );
      return;
    }
    _signalingRecoveryRequired |= signaling;
    if (signaling) {
      _reconnectFailureCode = RemoteDesktopErrorCode.signaling;
    }
    if (_reconnectSequence != null) {
      if (_state != RemoteDesktopState.reconnecting) {
        _setState(RemoteDesktopState.reconnecting);
      }
      return;
    }
    _reconnectFailureCode = signaling
        ? RemoteDesktopErrorCode.signaling
        : RemoteDesktopErrorCode.peer;
    _reconnectSequence = const ReconnectPolicy().start();
    _setState(RemoteDesktopState.reconnecting);
    try {
      await _inputSender?.suspend();
    } catch (_) {}
    if (!_operationIsCurrent(operationGeneration)) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    final sequence = _reconnectSequence;
    if (sequence == null || !sequence.active || _reconnectTimer != null) {
      return;
    }
    final ticket = sequence.scheduleNext();
    if (ticket == null) {
      if (sequence.exhausted) {
        unawaited(_fail(_reconnectFailureCode));
      }
      return;
    }
    final policy = const ReconnectPolicy();
    _reconnectProgress = RemoteReconnectProgress(
      attempt: ticket.attempt,
      maximumAttempts: policy.attemptDelays.length,
      elapsed: ticket.elapsed,
      recoveryWindow: policy.recoveryWindow,
    );
    _diagnostics.recordReconnect(
      attempt: ticket.attempt,
      delay: ticket.delay,
      outcome: DiagnosticsReconnectOutcome.scheduled,
      totalElapsed: ticket.elapsed,
    );
    if (!_disposed) {
      notifyListeners();
    }
    _reconnectTimer = _reconnectScheduler.schedule(ticket.delay, () {
      _reconnectTimer = null;
      if (_state == RemoteDesktopState.connecting &&
          _reconnectConnectionGracePending) {
        _reconnectConnectionGracePending = false;
        _waitForCurrentConnection(ticket);
        return;
      }
      unawaited(_runReconnectAttempt(ticket));
    });
  }

  void _waitForCurrentConnection(ReconnectAttemptTicket ticket) {
    final sequence = _reconnectSequence;
    if (sequence == null || !sequence.begin(ticket)) {
      return;
    }
    unawaited(_finishReconnectAttempt(sequence, ticket));
  }

  Future<void> _runReconnectAttempt(ReconnectAttemptTicket ticket) async {
    final sequence = _reconnectSequence;
    if (sequence == null || !sequence.begin(ticket)) {
      return;
    }
    final operationGeneration = _operationGeneration;
    _diagnostics.recordReconnect(
      attempt: ticket.attempt,
      delay: ticket.delay,
      outcome: DiagnosticsReconnectOutcome.attempted,
      totalElapsed: ticket.elapsed,
    );
    try {
      if (_signalingRecoveryRequired) {
        await _signaling.recover();
        _requireActiveOperation(operationGeneration);
        _signalingRecoveryRequired = false;
      }
      _offerSent = false;
      _pendingLocalCandidates.clear();
      final peerOffer = await _peer.restartIce();
      _requireActiveOperation(operationGeneration);
      await _sendAuthenticatedOffer(peerOffer, operationGeneration);
    } on _RemoteDesktopOperationCancelled {
      return;
    } on SignalingClientException {
      _signalingRecoveryRequired = true;
      _reconnectFailureCode = RemoteDesktopErrorCode.signaling;
    } on PeerSessionException {
      // The bounded policy owns peer retries.
    } on ControllerSessionIdentityException {
      await _fail(RemoteDesktopErrorCode.localIdentity);
      return;
    } on RemoteDesktopException catch (error) {
      await _fail(error.code);
      return;
    } on ProtocolValidationException {
      await _fail(RemoteDesktopErrorCode.signaling);
      return;
    } catch (_) {
      await _fail(RemoteDesktopErrorCode.peer);
      return;
    }
    await _finishReconnectAttempt(sequence, ticket);
  }

  Future<void> _finishReconnectAttempt(
    ReconnectAttemptSequence sequence,
    ReconnectAttemptTicket ticket,
  ) async {
    if (!sequence.complete(ticket)) return;
    if (sequence.allAttemptsCompleted) {
      _scheduleReconnectExpiry(sequence, ticket);
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnectExpiry(
    ReconnectAttemptSequence sequence,
    ReconnectAttemptTicket ticket,
  ) {
    final grace = sequence.remainingRecoveryWindow;
    _reconnectTimer = _reconnectScheduler.schedule(grace, () {
      _reconnectTimer = null;
      if (!identical(_reconnectSequence, sequence) || !sequence.expire()) {
        return;
      }
      _diagnostics.recordReconnect(
        attempt: ticket.attempt,
        delay: grace,
        outcome: DiagnosticsReconnectOutcome.exhausted,
        totalElapsed: ticket.elapsed + grace,
      );
      unawaited(_fail(_reconnectFailureCode));
    });
  }

  void _completeReconnect() {
    final progress = _reconnectProgress;
    if (progress != null) {
      _diagnostics.recordReconnect(
        attempt: progress.attempt,
        delay: Duration.zero,
        outcome: DiagnosticsReconnectOutcome.recovered,
        totalElapsed: progress.elapsed,
      );
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectSequence?.recovered();
    _reconnectSequence = null;
    _reconnectProgress = null;
    _reconnectConnectionGracePending = false;
    _signalingRecoveryRequired = false;
    try {
      _inputSender?.resume();
    } on InputSenderException {
      unawaited(_fail(RemoteDesktopErrorCode.peer));
      return;
    }
    _setState(RemoteDesktopState.connected);
  }

  @override
  Future<void> close() {
    _closeRequested = true;
    return _closeFuture ??= _closeResources(setIdle: true);
  }

  Future<void> _fail(RemoteDesktopErrorCode code) async {
    if (_state == RemoteDesktopState.failed ||
        _state == RemoteDesktopState.closing ||
        _state == RemoteDesktopState.idle) {
      return;
    }
    _debugRemoteReason(_RemoteDebugOperation.terminalFailure, code.name);
    _errorCode = code;
    _diagnostics.recordError(
      _diagnosticErrorCategory(code),
      _diagnosticErrorCode(code),
    );
    await _closeResources(setIdle: false);
    if (!_closeRequested) {
      _setState(RemoteDesktopState.failed);
    }
  }

  Future<void> _closeResources({
    required bool setIdle,
    bool notifyRemote = true,
  }) async {
    final teardown = _resourceCloseFuture ?? _startResourceClose(notifyRemote);
    await teardown;
    if (setIdle) {
      _errorCode = null;
      _setState(RemoteDesktopState.idle);
    }
  }

  Future<void> _startResourceClose(bool notifyRemote) {
    final completer = Completer<void>();
    _resourceCloseFuture = completer.future;
    unawaited(
      _performResourceClose(notifyRemote).then(
        (_) => completer.complete(),
        onError: (Object error, StackTrace stackTrace) {
          completer.completeError(error, stackTrace);
        },
      ),
    );
    return completer.future;
  }

  Future<void> _performResourceClose(bool notifyRemote) async {
    _operationGeneration += 1;
    _resourcesClosed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopDiagnosticsStats();
    _reconnectSequence?.cancel();
    _reconnectSequence = null;
    _reconnectProgress = null;
    _reconnectConnectionGracePending = false;
    _setState(RemoteDesktopState.closing);
    final input = _inputSender;
    _inputSender = null;
    try {
      await input?.close();
    } catch (_) {}
    if (_offerSent && notifyRemote) {
      try {
        await _relay(
          sessionStatus: SessionStatus(
            sessionId: _sessionId,
            state: SessionState.SESSION_STATE_CLOSING,
          ),
        );
      } catch (error) {
        // Cleanup must still finish if signaling was already interrupted.
        _debugRemoteFailure(_RemoteDebugOperation.relayClosingStatus, error);
      }
    }
    final candidateSubscription = _candidateSubscription;
    _candidateSubscription = null;
    final peerSubscription = _peerSubscription;
    _peerSubscription = null;
    final signalingSubscription = _signalingSubscription;
    _signalingSubscription = null;
    await _bestEffortRemoteCleanup(
      _RemoteDebugOperation.cancelCandidateStream,
      () async => candidateSubscription?.cancel(),
    );
    await _bestEffortRemoteCleanup(
      _RemoteDebugOperation.cancelPeerStream,
      () async => peerSubscription?.cancel(),
    );
    await _bestEffortRemoteCleanup(
      _RemoteDebugOperation.cancelSignalingStream,
      () async => signalingSubscription?.cancel(),
    );
    await _bestEffortRemoteCleanup(
      _RemoteDebugOperation.closePeer,
      _peer.close,
    );
    await _bestEffortRemoteCleanup(
      _RemoteDebugOperation.closeSignaling,
      _signaling.close,
    );
    await _bestEffortRemoteCleanup(
      _RemoteDebugOperation.closeIdentity,
      _identity.close,
    );
    _pendingLocalCandidates.clear();
    _offerSent = false;
    _answerApplicationInFlight = false;
    _offer = null;
    _answer = null;
    _reconnect = null;
    _answerDescription = null;
    _sessionId = null;
    _reconnectGeneration = 0;
    _signalingRecoveryRequired = false;
  }

  bool _operationIsCurrent(int generation) =>
      !_resourcesClosed && !_disposed && generation == _operationGeneration;

  void _requireActiveOperation(int generation) {
    if (!_operationIsCurrent(generation)) {
      throw const _RemoteDesktopOperationCancelled();
    }
  }

  Future<void> _validateLocalSignature(
    List<int> signature,
    DeviceIdentity identity,
    Uint8List transcript,
  ) async {
    if (signature.length != signatureBytes) {
      throw const RemoteDesktopException(RemoteDesktopErrorCode.authentication);
    }
    final valid = await Ed25519().verify(
      transcript,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(
          identity.publicKey,
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!valid) {
      throw const RemoteDesktopException(RemoteDesktopErrorCode.authentication);
    }
  }

  Uint8List _checkedRandom(int length) {
    final value = _randomBytes(length);
    if (value.length != length) {
      value.fillRange(0, value.length, 0);
      throw const RemoteDesktopException(RemoteDesktopErrorCode.configuration);
    }
    return Uint8List.fromList(value);
  }

  void _setState(RemoteDesktopState state) {
    if (_state != state) {
      if (kDebugMode) {
        debugPrint('[remote] state=${state.name}');
      }
      _diagnostics.recordState(_diagnosticSessionState(state));
    }
    _state = state;
    if (state == RemoteDesktopState.connected) {
      _startDiagnosticsStats();
    } else if (state == RemoteDesktopState.reconnecting ||
        state == RemoteDesktopState.closing ||
        state == RemoteDesktopState.failed ||
        state == RemoteDesktopState.idle) {
      _stopDiagnosticsStats();
    }
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _startDiagnosticsStats() {
    if (_diagnosticsTimer != null || _resourcesClosed) {
      return;
    }
    _diagnosticsTimer = Timer.periodic(
      _diagnosticsStatsInterval,
      (_) => unawaited(_collectDiagnosticsStats()),
    );
  }

  void _stopDiagnosticsStats() {
    _diagnosticsTimer?.cancel();
    _diagnosticsTimer = null;
  }

  Future<void> _collectDiagnosticsStats() async {
    if (_statsCollectionInFlight || _state != RemoteDesktopState.connected) {
      return;
    }
    _statsCollectionInFlight = true;
    try {
      final stats = await _peer.getAggregateStats();
      if (stats != null && _state == RemoteDesktopState.connected) {
        _diagnostics.recordStats(stats);
      }
    } catch (_) {
      // Diagnostics are best effort and never affect session behavior.
    } finally {
      _statsCollectionInFlight = false;
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}
