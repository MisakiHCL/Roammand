// SPDX-License-Identifier: MPL-2.0

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roammand/diagnostics/diagnostics_model.dart';
import 'package:roammand/desktop/host_agent/host_agent_models.dart';
import 'package:roammand/desktop/remote/host_agent_controller_session_identity.dart';
import 'package:roammand/desktop/remote/peer_session.dart';
import 'package:roammand/desktop/remote/reconnect_policy.dart';
import 'package:roammand/desktop/remote/remote_desktop_controller.dart';
import 'package:roammand/desktop/remote/session_authenticator.dart';
import 'package:roammand/desktop/remote/signaling_client.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

const _nowUnixMs = 1900000000000;
const _offerSdp = 'v=0\r\na=fingerprint:sha-256 44:44\r\n';
final _answerSdp =
    'v=0\r\na=fingerprint:sha-256 ${List<String>.filled(32, '76').join(':')}\r\n';

void main() {
  test('signs offer locally, verifies answer, and gates candidates', () async {
    final fixture = await _Fixture.create();

    await fixture.controller.connect(fixture.target);

    expect(fixture.controller.state, RemoteDesktopState.negotiating);
    expect(fixture.agent.connectCount, 1);
    expect(fixture.agent.signCount, 1);
    expect(fixture.signaling.sent, hasLength(2));
    final offer = fixture.sentOffer();
    expect(offer.controllerDeviceId, fixture.controllerIdentity.deviceId);
    expect(offer.hostDeviceId, fixture.hostIdentity.deviceId);
    expect(offer.signature, hasLength(64));

    fixture.signaling.route(
      fixture.envelope(
        webrtcNegotiation: WebRtcNegotiation(
          sessionId: offer.sessionId,
          iceCandidate: IceCandidate(
            candidate: 'candidate:1',
            sdpMid: '0',
            sdpMLineIndex: 0,
          ),
        ),
      ),
    );
    await _pumpEvents();
    expect(fixture.adapter.operations, <String>['initialize']);

    final answer = await fixture.signedAnswer(offer);
    fixture.signaling.route(
      fixture.envelope(
        sessionAuthentication: SessionAuthentication(answer: answer),
      ),
    );
    fixture.signaling.route(
      fixture.envelope(
        webrtcNegotiation: WebRtcNegotiation(
          sessionId: offer.sessionId,
          description: WebRtcSessionDescription(
            type: SessionDescriptionType.SESSION_DESCRIPTION_TYPE_ANSWER,
            sdp: _answerSdp,
            dtlsFingerprintSha256: fixture.hostFingerprint,
          ),
        ),
      ),
    );
    await _pumpEvents();

    expect(fixture.adapter.operations, <String>[
      'initialize',
      'answer',
      'candidate:candidate:1',
    ]);
    expect(fixture.controller.state, RemoteDesktopState.connecting);
    fixture.adapter.emit(ControllerPeerEvent.connected);
    await _pumpEvents();
    expect(fixture.controller.state, RemoteDesktopState.connected);
  });

  test('reliable input failure closes every session resource', () async {
    final fixture = await _Fixture.create();
    await fixture.connectFully();
    fixture.adapter.failReliable = true;
    await expectLater(
      fixture.controller.inputSender!.sendText('fails'),
      throwsA(isA<Exception>()),
    );
    await _pumpEvents();
    expect(fixture.controller.state, RemoteDesktopState.failed);
    expect(fixture.adapter.closeCount, 1);
    expect(fixture.signaling.closeCount, 1);
    expect(fixture.agent.closeCount, 1);
    await fixture.controller.close();
  });

  test('hashes the exact UTF-8 offer bytes used on the wire', () async {
    const utf8OfferSdp =
        'v=0\r\ns=\u8fdc\u7a0b\u684c\u9762\r\na=fingerprint:sha-256 44:44\r\n';
    final fixture = await _Fixture.create(offerSdp: utf8OfferSdp);
    addTearDown(fixture.controller.close);

    await fixture.controller.connect(fixture.target);

    expect(
      fixture.sentOffer().offerSha256,
      sha256.convert(utf8.encode(utf8OfferSdp)).bytes,
    );
  });

  test(
    'rejects a signed answer from the wrong Host and closes resources',
    () async {
      final fixture = await _Fixture.create();
      await fixture.controller.connect(fixture.target);
      final offer = fixture.sentOffer();
      final answer = await fixture.signedAnswer(offer)
        ..signature[0] ^= 0xff;

      fixture.signaling.route(
        fixture.envelope(
          sessionAuthentication: SessionAuthentication(answer: answer),
        ),
      );
      fixture.signaling.route(
        fixture.envelope(
          webrtcNegotiation: WebRtcNegotiation(
            sessionId: offer.sessionId,
            description: WebRtcSessionDescription(
              type: SessionDescriptionType.SESSION_DESCRIPTION_TYPE_ANSWER,
              sdp: _answerSdp,
              dtlsFingerprintSha256: fixture.hostFingerprint,
            ),
          ),
        ),
      );
      await _pumpEvents();

      expect(fixture.controller.state, RemoteDesktopState.failed);
      expect(
        fixture.controller.errorCode,
        RemoteDesktopErrorCode.authentication,
      );
      expect(fixture.adapter.closeCount, 1);
      expect(fixture.signaling.closeCount, 1);
    },
  );

  test('logs a sanitized Host error code before failing the session', () async {
    final logs = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };
    addTearDown(() => debugPrint = originalDebugPrint);
    final fixture = await _Fixture.create();

    await fixture.controller.connect(fixture.target);
    fixture.signaling.route(
      fixture.envelope(
        error: UnifiedError(
          code: ErrorCode.ERROR_CODE_INPUT_PERMISSION_REQUIRED,
          messageKey: 'remote_session.failed',
          requestId: 'host-1',
        ),
      ),
    );
    await _pumpEvents();

    expect(fixture.controller.state, RemoteDesktopState.failed);
    expect(fixture.controller.errorCode, RemoteDesktopErrorCode.remote);
    expect(
      logs,
      contains(
        '[remote] operation=remoteError '
        'cause=ERROR_CODE_INPUT_PERMISSION_REQUIRED',
      ),
    );
    expect(logs, contains('[remote] operation=terminalFailure cause=remote'));
  });

  test(
    'disconnect, signaling failure and dispose release resources once',
    () async {
      for (var cycle = 0; cycle < 10; cycle += 1) {
        final fixture = await _Fixture.create();
        await fixture.controller.connect(fixture.target);
        await fixture.controller.close();
        await fixture.controller.close();
        fixture.controller.dispose();

        expect(fixture.adapter.closeCount, 1, reason: 'peer cycle $cycle');
        expect(fixture.signaling.closeCount, 1, reason: 'signal cycle $cycle');
        expect(fixture.agent.closeCount, 1, reason: 'agent cycle $cycle');
        expect(fixture.controller.state, RemoteDesktopState.idle);
      }
    },
  );

  test('cleanup failures do not skip later resources or idle state', () async {
    final fixture = await _Fixture.create();
    await fixture.controller.connect(fixture.target);
    fixture.adapter.failClose = true;
    fixture.signaling.failClose = true;
    fixture.agent.failClose = true;

    await fixture.controller.close();

    expect(fixture.adapter.closeCount, 1);
    expect(fixture.signaling.closeCount, 1);
    expect(fixture.agent.closeCount, 1);
    expect(fixture.controller.state, RemoteDesktopState.idle);
  });

  test(
    'closing during identity open cannot create late session resources',
    () async {
      final fixture = await _Fixture.create();
      final identityGate = Completer<void>();
      fixture.agent.connectGate = identityGate;

      final connecting = fixture.controller.connect(fixture.target);
      while (fixture.agent.connectCount == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await fixture.controller.close();
      identityGate.complete();
      await connecting;

      expect(fixture.controller.state, RemoteDesktopState.idle);
      expect(fixture.signaling.connectCount, 0);
      expect(fixture.adapter.operations, isEmpty);
      expect(fixture.agent.closeCount, 1);
      expect(fixture.signaling.closeCount, 1);
      expect(fixture.adapter.closeCount, 1);
    },
  );

  test('closing during offer relay cannot continue negotiation', () async {
    final fixture = await _Fixture.create();
    final relayGate = Completer<void>();
    final relayStarted = Completer<void>();
    fixture.signaling
      ..relayGate = relayGate
      ..relayStarted = relayStarted;

    final connecting = fixture.controller.connect(fixture.target);
    await relayStarted.future;
    await fixture.controller.close();
    relayGate.complete();
    await connecting;

    expect(fixture.controller.state, RemoteDesktopState.idle);
    expect(fixture.signaling.sent, hasLength(1));
    expect(fixture.adapter.closeCount, 1);
    expect(fixture.signaling.closeCount, 1);
    expect(fixture.agent.closeCount, 1);
  });

  test('duplicate answer frames share one verification operation', () async {
    final fixture = await _Fixture.create();
    await fixture.controller.connect(fixture.target);
    final offer = fixture.sentOffer();
    final answer = await fixture.signedAnswer(offer);
    final answerGate = Completer<void>();
    fixture.adapter.answerGate = answerGate;

    fixture.signaling.route(
      fixture.envelope(
        sessionAuthentication: SessionAuthentication(answer: answer),
      ),
    );
    fixture.routeAnswerDescription(offer);
    while (fixture.adapter.answerCount == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    fixture.routeAnswerDescription(offer);
    await _pumpEvents();

    expect(fixture.adapter.answerCount, 1);
    expect(fixture.adapter.closeCount, 0);
    answerGate.complete();
    await _pumpEvents();
    expect(fixture.controller.state, RemoteDesktopState.connecting);
    expect(fixture.adapter.answerCount, 1);
  });

  test('close waits for teardown already started by a failure', () async {
    final fixture = await _Fixture.create();
    await fixture.controller.connect(fixture.target);
    final closeGate = Completer<void>();
    fixture.adapter.closeGate = closeGate;

    fixture.signaling.fail();
    while (fixture.adapter.closeCount == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    var closeCompleted = false;
    final closing = fixture.controller.close().then((_) {
      closeCompleted = true;
    });
    await _pumpEvents();
    expect(closeCompleted, isFalse);

    closeGate.complete();
    await closing;
    expect(fixture.controller.state, RemoteDesktopState.idle);
    expect(fixture.adapter.closeCount, 1);
    expect(fixture.signaling.closeCount, 1);
    expect(fixture.agent.closeCount, 1);
  });

  test('saved diagnostics preserve a stable signaling server code', () async {
    final logs = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };
    addTearDown(() => debugPrint = originalDebugPrint);
    final fixture = await _Fixture.create();

    await fixture.controller.connect(fixture.target);
    fixture.signaling.fail(
      const SignalingRemoteException(
        code: ErrorCode.ERROR_CODE_DEVICE_OFFLINE,
        retryable: true,
      ),
    );
    await _pumpEvents();

    final errorCodes = fixture.controller.diagnosticsReport.events
        .whereType<DiagnosticsErrorEvent>()
        .map((event) => event.code)
        .toList();
    expect(errorCodes, contains(DiagnosticsErrorCode.deviceOffline));
    expect(
      logs,
      contains(
        '[remote] operation=signalingStream '
        'cause=ERROR_CODE_DEVICE_OFFLINE',
      ),
    );
  });

  test('normal close notifies Host before releasing resources', () async {
    final fixture = await _Fixture.create();
    await fixture.connectFully();
    final sessionId = fixture.sentOffers.single.sessionId;

    await fixture.controller.close();

    final closing = fixture.signaling.sent
        .map(decodeAndValidateSignalingEnvelope)
        .where((envelope) => envelope.hasSessionStatus())
        .single;
    expect(closing.sessionStatus.sessionId, sessionId);
    expect(closing.sessionStatus.state, SessionState.SESSION_STATE_CLOSING);
    final reliableClose = decodeAndValidateReliableInputEnvelope(
      fixture.adapter.reliableSent.last,
    );
    expect(
      reliableClose.sessionControl.action,
      SessionControlAction.SESSION_CONTROL_ACTION_CLOSE,
    );
    expect(fixture.adapter.closeCount, 1);
    expect(fixture.signaling.closeCount, 1);
    expect(fixture.controller.state, RemoteDesktopState.idle);
  });

  test(
    'Host close ends the session without reconnecting or echoing close',
    () async {
      final fixture = await _Fixture.create();
      await fixture.connectFully();
      final sessionId = fixture.sentOffers.single.sessionId;
      final sentBeforeClose = fixture.signaling.sent.length;

      fixture.signaling.route(
        fixture.envelope(
          sessionStatus: SessionStatus(
            sessionId: sessionId,
            state: SessionState.SESSION_STATE_CLOSING,
          ),
        ),
      );
      await _pumpEvents();

      expect(fixture.controller.state, RemoteDesktopState.idle);
      expect(fixture.scheduler.activeCount, 0);
      expect(fixture.adapter.closeCount, 1);
      expect(fixture.signaling.closeCount, 1);
      expect(fixture.signaling.sent, hasLength(sentBeforeClose));
    },
  );

  test(
    'reconnects with a fresh signed offer and Host reconnect proof',
    () async {
      final fixture = await _Fixture.create();
      await fixture.connectFully();
      final initial = fixture.sentOffers.single;

      fixture.adapter.emit(ControllerPeerEvent.disconnected);
      await _pumpEvents();

      expect(fixture.controller.state, RemoteDesktopState.reconnecting);
      expect(fixture.controller.reconnectProgress?.attempt, 1);
      expect(fixture.controller.reconnectProgress?.maximumAttempts, 5);
      expect(
        fixture.controller.reconnectProgress?.remaining,
        const Duration(seconds: 29),
      );
      expect(fixture.scheduler.pendingDelays, <Duration>[
        const Duration(seconds: 1),
      ]);
      expect(fixture.adapter.reliableSent, hasLength(1));
      expect(
        decodeAndValidateReliableInputEnvelope(
          fixture.adapter.reliableSent.single,
        ).hasReleaseAllInput(),
        isTrue,
      );

      await fixture.scheduler.fireNext();
      await _pumpEvents();

      final restarted = fixture.sentOffers.last;
      expect(fixture.sentOffers, hasLength(2));
      expect(restarted.sessionId, initial.sessionId);
      expect(restarted.nonce, isNot(equals(initial.nonce)));
      expect(restarted.signature, isNot(equals(initial.signature)));
      expect(restarted.offerSha256, isNot(equals(initial.offerSha256)));
      expect(fixture.agent.signCount, 2);
      expect(fixture.adapter.operations, contains('restart-ice:1'));

      fixture.signaling.route(
        fixture.envelope(
          sessionAuthentication: SessionAuthentication(
            reconnect: await fixture.signedReconnect(restarted, generation: 1),
          ),
        ),
      );
      fixture.routeAnswerDescription(restarted);
      await _pumpEvents();
      fixture.adapter.emit(ControllerPeerEvent.connected);
      await _pumpEvents();

      expect(fixture.controller.state, RemoteDesktopState.connected);
      expect(fixture.controller.reconnectProgress, isNull);
      expect(fixture.scheduler.activeCount, 0);
      final reconnectEvents = fixture.controller.diagnosticsReport.events
          .whereType<DiagnosticsReconnectEvent>()
          .toList(growable: false);
      expect(
        reconnectEvents.map((event) => event.outcome),
        containsAll(<DiagnosticsReconnectOutcome>[
          DiagnosticsReconnectOutcome.scheduled,
          DiagnosticsReconnectOutcome.attempted,
          DiagnosticsReconnectOutcome.recovered,
        ]),
      );
      await fixture.controller.inputSender!.sendKeyboard(
        action: KeyboardAction.KEYBOARD_ACTION_UP,
        usbHidUsage: 0x04,
      );
      expect(
        decodeAndValidateReliableInputEnvelope(
          fixture.adapter.reliableSent.last,
        ).sequence.toInt(),
        2,
      );
    },
  );

  test('spontaneous peer recovery cancels every pending retry', () async {
    final fixture = await _Fixture.create();
    await fixture.connectFully();
    fixture.adapter.emit(ControllerPeerEvent.disconnected);
    await _pumpEvents();
    expect(fixture.scheduler.activeCount, 1);

    fixture.adapter.emit(ControllerPeerEvent.connected);
    await _pumpEvents();

    expect(fixture.controller.state, RemoteDesktopState.connected);
    expect(fixture.scheduler.activeCount, 0);
    expect(fixture.sentOffers, hasLength(1));
  });

  test(
    'gives a verified reconnect one retry interval before replacing it',
    () async {
      final fixture = await _Fixture.create();
      await fixture.connectFully();
      fixture.adapter.emit(ControllerPeerEvent.disconnected);
      await _pumpEvents();

      await fixture.scheduler.fireNext();
      final restarted = fixture.sentOffers.last;
      fixture.signaling.route(
        fixture.envelope(
          sessionAuthentication: SessionAuthentication(
            reconnect: await fixture.signedReconnect(restarted, generation: 1),
          ),
        ),
      );
      fixture.routeAnswerDescription(restarted);
      await _pumpEvents();
      expect(fixture.controller.state, RemoteDesktopState.connecting);

      await fixture.scheduler.fireNext();
      await _pumpEvents();

      expect(fixture.sentOffers, hasLength(2));
      expect(fixture.adapter.restartCount, 1);
      expect(fixture.scheduler.pendingDelays, <Duration>[
        const Duration(seconds: 4),
      ]);

      await fixture.scheduler.fireNext();
      await _pumpEvents();
      expect(fixture.sentOffers, hasLength(3));
      expect(fixture.adapter.restartCount, 2);

      final secondRestart = fixture.sentOffers.last;
      fixture.signaling.route(
        fixture.envelope(
          sessionAuthentication: SessionAuthentication(
            reconnect: await fixture.signedReconnect(
              secondRestart,
              generation: 2,
            ),
          ),
        ),
      );
      fixture.routeAnswerDescription(secondRestart);
      await _pumpEvents();

      fixture.adapter.emit(ControllerPeerEvent.connected);
      await _pumpEvents();
      expect(fixture.controller.state, RemoteDesktopState.connected);
      expect(fixture.scheduler.activeCount, 0);
    },
  );

  test('recovers signaling and accepts a full Host restart answer', () async {
    final fixture = await _Fixture.create();
    await fixture.connectFully();

    fixture.signaling.fail();
    await _pumpEvents();
    expect(fixture.controller.state, RemoteDesktopState.reconnecting);

    await fixture.scheduler.fireNext();
    await _pumpEvents();
    expect(fixture.signaling.recoverCount, 1);
    final restarted = fixture.sentOffers.last;

    fixture.signaling.route(
      fixture.envelope(
        sessionAuthentication: SessionAuthentication(
          answer: await fixture.signedAnswer(restarted),
        ),
      ),
    );
    fixture.routeAnswerDescription(restarted);
    await _pumpEvents();
    fixture.adapter.emit(ControllerPeerEvent.connected);
    await _pumpEvents();

    expect(fixture.controller.state, RemoteDesktopState.connected);
  });

  test(
    'waits for the final ICE restart through the thirty-second window',
    () async {
      final fixture = await _Fixture.create();
      await fixture.connectFully();
      fixture.adapter.emit(ControllerPeerEvent.failed);
      await _pumpEvents();

      for (var attempt = 0; attempt < 5; attempt += 1) {
        await fixture.scheduler.fireNext();
        await _pumpEvents();
      }

      expect(fixture.controller.state, RemoteDesktopState.reconnecting);
      expect(fixture.scheduler.pendingDelays, <Duration>[
        const Duration(seconds: 7),
      ]);
      await fixture.scheduler.fireNext();
      await _pumpEvents();

      expect(fixture.scheduler.firedDelays, <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
        const Duration(seconds: 8),
        const Duration(seconds: 8),
        const Duration(seconds: 7),
      ]);
      expect(fixture.sentOffers, hasLength(6));
      expect(
        fixture.sentOffers.map((offer) => offer.nonce.join(',')).toSet(),
        hasLength(6),
      );
      expect(fixture.controller.state, RemoteDesktopState.failed);
      expect(fixture.controller.errorCode, RemoteDesktopErrorCode.peer);
      expect(fixture.adapter.closeCount, 1);
    },
  );

  test(
    'accepts a successful final ICE restart during its grace window',
    () async {
      final fixture = await _Fixture.create();
      await fixture.connectFully();
      fixture.adapter.emit(ControllerPeerEvent.failed);
      await _pumpEvents();

      for (var attempt = 0; attempt < 5; attempt += 1) {
        await fixture.scheduler.fireNext();
        await _pumpEvents();
      }
      expect(fixture.scheduler.pendingDelays, <Duration>[
        const Duration(seconds: 7),
      ]);

      final finalRestart = fixture.sentOffers.last;
      fixture.signaling.route(
        fixture.envelope(
          sessionAuthentication: SessionAuthentication(
            reconnect: await fixture.signedReconnect(
              finalRestart,
              generation: 1,
            ),
          ),
        ),
      );
      fixture.routeAnswerDescription(finalRestart);
      await _pumpEvents();
      fixture.adapter.emit(ControllerPeerEvent.connected);
      await _pumpEvents();

      expect(fixture.controller.state, RemoteDesktopState.connected);
      expect(fixture.controller.errorCode, isNull);
      expect(fixture.scheduler.activeCount, 0);
      expect(fixture.adapter.closeCount, 0);
    },
  );
}

Future<void> _pumpEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _Fixture {
  const _Fixture({
    required this.controller,
    required this.target,
    required this.agent,
    required this.signaling,
    required this.adapter,
    required this.controllerIdentity,
    required this.hostIdentity,
    required this.hostKeyPair,
    required this.hostFingerprint,
    required this.scheduler,
  });

  final RemoteDesktopController controller;
  final RemoteDesktopTarget target;
  final _FakeHostAgent agent;
  final _FakeSignalingLink signaling;
  final _FakePeerAdapter adapter;
  final DeviceIdentity controllerIdentity;
  final DeviceIdentity hostIdentity;
  final SimpleKeyPair hostKeyPair;
  final List<int> hostFingerprint;
  final _ManualReconnectScheduler scheduler;

  static Future<_Fixture> create({String offerSdp = _offerSdp}) async {
    final algorithm = Ed25519();
    final hostKeyPair = await algorithm.newKeyPairFromSeed(
      List<int>.filled(32, 0x42),
    );
    final hostPublicKey = await hostKeyPair.extractPublicKey();
    final hostIdentity = DeviceIdentity(
      deviceId: deriveDeviceIdV1(hostPublicKey.bytes),
      publicKeyAlgorithm: PublicKeyAlgorithm.PUBLIC_KEY_ALGORITHM_ED25519,
      publicKey: hostPublicKey.bytes,
      displayName: 'Host',
      platform: DevicePlatform.DEVICE_PLATFORM_MACOS,
    );
    final controllerKeyPair = await algorithm.newKeyPairFromSeed(
      List<int>.filled(32, 0x24),
    );
    final controllerPublicKey = await controllerKeyPair.extractPublicKey();
    final controllerIdentity = DeviceIdentity(
      deviceId: deriveDeviceIdV1(controllerPublicKey.bytes),
      publicKeyAlgorithm: PublicKeyAlgorithm.PUBLIC_KEY_ALGORITHM_ED25519,
      publicKey: controllerPublicKey.bytes,
      displayName: 'Controller',
      platform: DevicePlatform.DEVICE_PLATFORM_MACOS,
    );
    final agent = _FakeHostAgent(controllerIdentity, controllerKeyPair);
    final signaling = _FakeSignalingLink();
    final adapter = _FakePeerAdapter(offerSdp: offerSdp);
    final peer = ControllerPeerSession(
      adapter: adapter,
      configuration: const ControllerPeerConfiguration(),
    );
    final scheduler = _ManualReconnectScheduler();
    var randomCall = 0;
    final controller = RemoteDesktopController(
      identity: HostAgentControllerSessionIdentity(agent),
      signaling: signaling,
      peer: peer,
      randomBytes: (length) {
        randomCall += 1;
        return Uint8List.fromList(
          List<int>.generate(
            length,
            (index) => (index + length + randomCall) & 0xff,
          ),
        );
      },
      nowUnixMs: () => _nowUnixMs,
      reconnectScheduler: scheduler,
    );
    return _Fixture(
      controller: controller,
      target: RemoteDesktopTarget(
        hostIdentity: hostIdentity,
        signalingEndpoint: Uri.parse('wss://signal.example.test/v1/ws'),
      ),
      agent: agent,
      signaling: signaling,
      adapter: adapter,
      controllerIdentity: controllerIdentity,
      hostIdentity: hostIdentity,
      hostKeyPair: hostKeyPair,
      hostFingerprint: List<int>.filled(32, 0x76),
      scheduler: scheduler,
    );
  }

  List<SessionOfferAuthentication> get sentOffers => signaling.sent
      .map(decodeAndValidateSignalingEnvelope)
      .where((envelope) => envelope.sessionAuthentication.hasOffer())
      .map((envelope) => envelope.sessionAuthentication.offer.deepCopy())
      .toList(growable: false);

  SessionOfferAuthentication sentOffer() {
    for (final bytes in signaling.sent) {
      final envelope = decodeAndValidateSignalingEnvelope(bytes);
      if (envelope.hasSessionAuthentication() &&
          envelope.sessionAuthentication.hasOffer()) {
        return envelope.sessionAuthentication.offer;
      }
    }
    throw StateError('signed offer was not relayed');
  }

  Future<void> connectFully() async {
    await controller.connect(target);
    final offer = sentOffers.last;
    signaling.route(
      envelope(
        sessionAuthentication: SessionAuthentication(
          answer: await signedAnswer(offer),
        ),
      ),
    );
    routeAnswerDescription(offer);
    await _pumpEvents();
    adapter.emit(ControllerPeerEvent.connected);
    await _pumpEvents();
    expect(controller.state, RemoteDesktopState.connected);
  }

  void routeAnswerDescription(SessionOfferAuthentication offer) {
    signaling.route(
      envelope(
        webrtcNegotiation: WebRtcNegotiation(
          sessionId: offer.sessionId,
          description: WebRtcSessionDescription(
            type: SessionDescriptionType.SESSION_DESCRIPTION_TYPE_ANSWER,
            sdp: _answerSdp,
            dtlsFingerprintSha256: hostFingerprint,
          ),
        ),
      ),
    );
  }

  SignalingEnvelope envelope({
    SessionAuthentication? sessionAuthentication,
    WebRtcNegotiation? webrtcNegotiation,
    SessionStatus? sessionStatus,
    UnifiedError? error,
  }) => SignalingEnvelope(
    protocolVersion: ProtocolVersion(major: 1, minor: 0),
    senderDeviceId: hostIdentity.deviceId,
    recipientDeviceId: controllerIdentity.deviceId,
    requestId: 'host-1',
    sentAtUnixMs: Int64(_nowUnixMs),
    sessionAuthentication: sessionAuthentication,
    webrtcNegotiation: webrtcNegotiation,
    sessionStatus: sessionStatus,
    error: error,
  );

  Future<SessionAnswerAuthentication> signedAnswer(
    SessionOfferAuthentication offer,
  ) async {
    final answer = SessionAnswerAuthentication(
      controllerDeviceId: offer.controllerDeviceId,
      hostDeviceId: offer.hostDeviceId,
      sessionId: offer.sessionId,
      nonce: offer.nonce,
      issuedAtUnixMs: offer.issuedAtUnixMs,
      expiresAtUnixMs: offer.expiresAtUnixMs,
      requestedPermissions: offer.requestedPermissions,
      offerSha256: offer.offerSha256,
      controllerDtlsFingerprintSha256: offer.controllerDtlsFingerprintSha256,
      answerSha256: sha256.convert(_answerSdp.codeUnits).bytes,
      hostDtlsFingerprintSha256: hostFingerprint,
    );
    final signature = await Ed25519().sign(
      encodeSessionAnswerTranscript(answer),
      keyPair: hostKeyPair,
    );
    answer.signature = signature.bytes;
    return answer;
  }

  Future<SessionReconnectAuthentication> signedReconnect(
    SessionOfferAuthentication offer, {
    required int generation,
  }) async {
    final reconnect = SessionReconnectAuthentication(
      controllerDeviceId: offer.controllerDeviceId,
      hostDeviceId: offer.hostDeviceId,
      sessionId: offer.sessionId,
      nonce: offer.nonce,
      issuedAtUnixMs: offer.issuedAtUnixMs,
      expiresAtUnixMs: offer.expiresAtUnixMs,
      requestedPermissions: offer.requestedPermissions,
      offerSha256: offer.offerSha256,
      controllerDtlsFingerprintSha256: offer.controllerDtlsFingerprintSha256,
      answerSha256: sha256.convert(_answerSdp.codeUnits).bytes,
      hostDtlsFingerprintSha256: hostFingerprint,
      reconnectGeneration: generation,
    );
    final signature = await Ed25519().sign(
      encodeSessionReconnectTranscript(reconnect),
      keyPair: hostKeyPair,
    );
    reconnect.signature = signature.bytes;
    return reconnect;
  }
}

final class _FakeHostAgent implements HostAgentApi {
  _FakeHostAgent(this.identity, this.keyPair);

  final DeviceIdentity identity;
  final SimpleKeyPair keyPair;
  int connectCount = 0;
  int closeCount = 0;
  int signCount = 0;
  bool failClose = false;
  Completer<void>? connectGate;

  @override
  Stream<SessionTerminatedEvent> get sessionTerminations =>
      const Stream<SessionTerminatedEvent>.empty();

  @override
  Stream<HostPairingStatusSnapshot> get hostPairingStates =>
      const Stream<HostPairingStatusSnapshot>.empty();

  @override
  Stream<PrivilegedBridgeStatusSnapshot> get privilegedBridgeStates =>
      const Stream<PrivilegedBridgeStatusSnapshot>.empty();

  @override
  Future<EmergencyStopRemoteSessionResult> emergencyStopRemoteSession() async =>
      EmergencyStopRemoteSessionResult();

  @override
  Future<void> connect() async {
    connectCount += 1;
    await connectGate?.future;
  }

  @override
  Future<HostStatus> getHostStatus() async => HostStatus(identity: identity);

  @override
  Future<SessionOfferSignature> signSessionOffer(
    List<int> canonicalTranscript,
  ) async {
    signCount += 1;
    final signature = await Ed25519().sign(
      canonicalTranscript,
      keyPair: keyPair,
    );
    return SessionOfferSignature(
      controllerDeviceId: identity.deviceId,
      controllerPublicKey: identity.publicKey,
      signature: signature.bytes,
      transcriptSha256: sha256.convert(canonicalTranscript).bytes,
    );
  }

  @override
  Future<void> close() async {
    closeCount += 1;
    if (failClose) {
      throw StateError('host agent cleanup failed');
    }
  }

  @override
  Future<CanonicalTranscriptSignature> signCanonicalTranscript(
    List<int> canonicalTranscript,
  ) => throw UnimplementedError();

  @override
  Future<PairingTranscriptSignature> signPairingTranscript(
    List<int> canonicalTranscript,
    PairingIdentityRole role,
  ) => throw UnimplementedError();

  @override
  Future<ControllerGrantView> createControllerGrant(
    DeviceIdentity controller,
    Iterable<SessionPermission> permissions,
  ) => throw UnimplementedError();

  @override
  Future<List<ControllerGrantView>> listControllerGrants() =>
      throw UnimplementedError();

  @override
  Future<ControllerGrantRevoked> revokeControllerGrant(List<int> grantId) =>
      throw UnimplementedError();

  @override
  Future<HostPairingStatusSnapshot> getHostPairingStatus() =>
      throw UnimplementedError();

  @override
  Future<HostPairingStatusSnapshot> startHostQrPairing(
    String signalingEndpoint,
  ) => throw UnimplementedError();

  @override
  Future<HostPairingStatusSnapshot> startHostDesktopCodePairing(
    String signalingEndpoint,
  ) => throw UnimplementedError();

  @override
  Future<HostPairingStatusSnapshot> cancelHostPairing(List<int> rendezvousId) =>
      throw UnimplementedError();

  @override
  Future<HostPairingStatusSnapshot> acceptHostPairing(
    List<int> rendezvousId,
    List<int> controllerDeviceId,
  ) => throw UnimplementedError();

  @override
  Future<HostPairingStatusSnapshot> rejectHostPairing(
    List<int> rendezvousId,
    List<int> controllerDeviceId,
  ) => throw UnimplementedError();
}

final class _FakeSignalingLink implements ControllerSignalingLink {
  final StreamController<SignalingRoutedSession> _routed =
      StreamController<SignalingRoutedSession>.broadcast();
  final List<Uint8List> sent = <Uint8List>[];
  int closeCount = 0;
  int connectCount = 0;
  int recoverCount = 0;
  bool failClose = false;
  Completer<void>? relayGate;
  Completer<void>? relayStarted;

  @override
  Stream<SignalingRoutedSession> get routedSessions => _routed.stream;

  @override
  Future<void> connect(List<int> controllerDeviceId) async {
    connectCount += 1;
  }

  @override
  Future<void> recover() async {
    recoverCount += 1;
  }

  @override
  Future<void> relay(List<int> hostDeviceId, Uint8List opaqueEnvelope) async {
    sent.add(Uint8List.fromList(opaqueEnvelope));
    final started = relayStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    await relayGate?.future;
  }

  void route(SignalingEnvelope envelope) {
    _routed.add(
      SignalingRoutedSession(
        senderDeviceId: envelope.senderDeviceId,
        opaqueEnvelope: envelope.writeToBuffer(),
      ),
    );
  }

  void fail([
    Object error = const SignalingClientException(
      SignalingClientErrorCode.transport,
    ),
  ]) {
    _routed.addError(error);
  }

  @override
  Future<void> close() async {
    closeCount += 1;
    if (failClose) {
      throw StateError('signaling cleanup failed');
    }
  }
}

final class _FakePeerAdapter implements ControllerPeerAdapter {
  _FakePeerAdapter({this.offerSdp = _offerSdp});

  final String offerSdp;
  final List<String> operations = <String>[];
  ControllerPeerCallbacks? callbacks;
  int closeCount = 0;
  int restartCount = 0;
  int answerCount = 0;
  bool failClose = false;
  bool failReliable = false;
  Completer<void>? answerGate;
  Completer<void>? closeGate;
  final List<Uint8List> reliableSent = <Uint8List>[];

  @override
  int get reliableBufferedAmount => 0;

  @override
  Future<int> readReliableBufferedAmount() async => reliableBufferedAmount;

  @override
  int get fastBufferedAmount => 0;

  @override
  Object get renderer => this;

  @override
  Future<ControllerPeerOffer> initialize(
    ControllerPeerConfiguration configuration,
    ControllerPeerCallbacks callbacks,
  ) async {
    this.callbacks = callbacks;
    operations.add('initialize');
    return ControllerPeerOffer(
      sdp: offerSdp,
      dtlsFingerprintSha256: Uint8List.fromList(List<int>.filled(32, 0x44)),
    );
  }

  void emit(ControllerPeerEvent event) => callbacks?.onEvent(event);

  @override
  Future<void> addRemoteCandidate(IceCandidate candidate) async {
    operations.add('candidate:${candidate.candidate}');
  }

  @override
  Future<void> setRemoteAnswer(String sdp) async {
    answerCount += 1;
    operations.add('answer');
    await answerGate?.future;
  }

  @override
  Future<ControllerPeerOffer> restartIce() async {
    restartCount += 1;
    operations.add('restart-ice:$restartCount');
    return ControllerPeerOffer(
      sdp: '$offerSdp\na=x-restart:$restartCount\r\n',
      dtlsFingerprintSha256: Uint8List.fromList(
        List<int>.filled(32, 0x44 + restartCount),
      ),
    );
  }

  @override
  Future<void> sendFast(Uint8List bytes) async {}

  @override
  Future<void> sendReliable(Uint8List bytes) async {
    if (failReliable) throw StateError('native channel rejected input');
    reliableSent.add(Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    closeCount += 1;
    await closeGate?.future;
    if (failClose) {
      throw StateError('peer cleanup failed');
    }
  }
}

final class _ManualReconnectScheduler implements ReconnectScheduler {
  final List<_ScheduledReconnect> _scheduled = <_ScheduledReconnect>[];
  final List<Duration> firedDelays = <Duration>[];

  List<Duration> get pendingDelays => _scheduled
      .where((scheduled) => !scheduled.cancelled && !scheduled.fired)
      .map((scheduled) => scheduled.delay)
      .toList(growable: false);

  int get activeCount => pendingDelays.length;

  @override
  ReconnectTimer schedule(Duration delay, void Function() callback) {
    final scheduled = _ScheduledReconnect(delay, callback);
    _scheduled.add(scheduled);
    return scheduled;
  }

  Future<void> fireNext() async {
    final scheduled = _scheduled.firstWhere(
      (candidate) => !candidate.cancelled && !candidate.fired,
    );
    scheduled.fired = true;
    firedDelays.add(scheduled.delay);
    scheduled.callback();
    await _pumpEvents();
  }
}

final class _ScheduledReconnect implements ReconnectTimer {
  _ScheduledReconnect(this.delay, this.callback);

  final Duration delay;
  final void Function() callback;
  bool cancelled = false;
  bool fired = false;

  @override
  void cancel() {
    cancelled = true;
  }
}
