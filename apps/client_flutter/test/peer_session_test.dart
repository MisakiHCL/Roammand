// SPDX-License-Identifier: MPL-2.0

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:roammand/desktop/remote/peer_session.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

const _offerSdp =
    'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96 97\r\n'
    'a=rtpmap:96 VP8/90000\r\na=rtpmap:97 H264/90000\r\n';
const _answerSdp = 'v=0\r\na=fingerprint:sha-256 CC:DD\r\n';
const _restartOfferSdp = 'v=0\r\na=fingerprint:sha-256 DD:EE\r\n';

void main() {
  test('input channels expose independent native buffering', () async {
    final adapter = _FakePeerAdapter()
      ..reliableBufferedAmount = 12345
      ..fastBufferedAmount = 67890;
    final session = ControllerPeerSession(
      adapter: adapter,
      configuration: const ControllerPeerConfiguration(),
    );
    expect(session.reliableInput.bufferedAmount, 12345);
    expect(session.fastInput.bufferedAmount, 67890);
    adapter.reliableBufferedAmount = 321;
    expect(session.reliableInput.bufferedAmount, 321);
    await session.close();
  });

  test(
    'initializes renderer, peer, exact channels, codecs and ICE policy',
    () async {
      final adapter = _FakePeerAdapter();
      final session = ControllerPeerSession(
        adapter: adapter,
        configuration: const ControllerPeerConfiguration(
          iceTransportPolicy: DesktopIceTransportPolicy.relay,
          iceServers: <DesktopIceServer>[
            DesktopIceServer(
              urls: <String>['turns:turn.example.test:5349'],
              username: 'user',
              credential: 'password',
            ),
          ],
        ),
      );

      final offer = await session.start();

      expect(offer.sdp, _offerSdp);
      expect(offer.dtlsFingerprintSha256, List<int>.filled(32, 0x44));
      expect(adapter.configuration!.videoCodecPreference, <String>[
        'H264',
        'VP8',
      ]);
      expect(adapter.configuration!.reliableChannel.label, 'input.reliable');
      expect(adapter.configuration!.reliableChannel.ordered, isTrue);
      expect(adapter.configuration!.reliableChannel.maxRetransmits, isNull);
      expect(adapter.configuration!.fastChannel.label, 'pointer.fast');
      expect(adapter.configuration!.fastChannel.ordered, isFalse);
      expect(adapter.configuration!.fastChannel.maxRetransmits, 0);
      expect(
        adapter.configuration!.iceTransportPolicy,
        DesktopIceTransportPolicy.relay,
      );
      expect(session.videoRenderer, same(adapter.videoRenderer));
    },
  );

  test(
    'gates remote ICE until the verified answer is applied in order',
    () async {
      final adapter = _FakePeerAdapter();
      final session = ControllerPeerSession(
        adapter: adapter,
        configuration: const ControllerPeerConfiguration(),
      );
      await session.start();
      await session.addRemoteCandidate(
        IceCandidate(candidate: 'candidate:1', sdpMid: '0', sdpMLineIndex: 0),
      );
      expect(adapter.operations, <String>['initialize']);

      await session.applyVerifiedAnswer(_answerSdp);

      expect(adapter.operations, <String>[
        'initialize',
        'answer',
        'candidate:candidate:1',
      ]);
      await session.addRemoteCandidate(
        IceCandidate(candidate: 'candidate:2', sdpMid: '0', sdpMLineIndex: 0),
      );
      expect(adapter.operations.last, 'candidate:candidate:2');
    },
  );

  test('prefers H264 then VP8 without discarding other codecs', () {
    final preferred = preferDesktopVideoCodecs(_offerSdp);

    expect(preferred, contains('m=video 9 UDP/TLS/RTP/SAVPF 97 96'));
    expect(preferred, contains('a=rtpmap:97 H264/90000'));
    expect(preferred, contains('a=rtpmap:96 VP8/90000'));
  });

  test('validates relay configuration and propagates peer failures', () async {
    expect(
      () => const ControllerPeerConfiguration(
        iceTransportPolicy: DesktopIceTransportPolicy.relay,
      ).validate(),
      throwsA(isA<PeerSessionException>()),
    );

    final adapter = _FakePeerAdapter()..failInitialize = true;
    final session = ControllerPeerSession(
      adapter: adapter,
      configuration: const ControllerPeerConfiguration(),
    );
    await expectLater(
      session.start(),
      throwsA(
        isA<PeerSessionException>().having(
          (error) => error.code,
          'code',
          PeerSessionErrorCode.peer,
        ),
      ),
    );
    expect(session.state, ControllerPeerState.failed);
    expect(adapter.closeCount, 1);
  });

  test('restarts ICE without replacing renderer or data channels', () async {
    final adapter = _FakePeerAdapter();
    final session = ControllerPeerSession(
      adapter: adapter,
      configuration: const ControllerPeerConfiguration(),
    );
    final renderer = session.videoRenderer;
    await session.start();
    await session.applyVerifiedAnswer(_answerSdp);
    adapter.emit(ControllerPeerEvent.connected);
    adapter.emit(ControllerPeerEvent.disconnected);

    final offer = await session.restartIce();

    expect(offer.sdp, _restartOfferSdp);
    expect(offer.dtlsFingerprintSha256, List<int>.filled(32, 0x55));
    expect(session.videoRenderer, same(renderer));
    expect(session.state, ControllerPeerState.awaitingVerifiedAnswer);
    expect(adapter.operations, <String>['initialize', 'answer', 'restart-ice']);

    await session.addRemoteCandidate(
      IceCandidate(candidate: 'candidate:restart', sdpMid: '0'),
    );
    await session.applyVerifiedAnswer(_answerSdp);
    expect(adapter.operations, <String>[
      'initialize',
      'answer',
      'restart-ice',
      'answer',
      'candidate:candidate:restart',
    ]);
  });

  test('ten connect and dispose cycles release every peer resource', () async {
    final resources = _ResourceCounter();
    for (var cycle = 0; cycle < 10; cycle += 1) {
      final adapter = _FakePeerAdapter(resources: resources);
      final session = ControllerPeerSession(
        adapter: adapter,
        configuration: const ControllerPeerConfiguration(),
      );
      await session.start();
      await session.close();
      await session.close();
    }

    expect(resources.live, 0);
    expect(resources.created, 10);
    expect(resources.closed, 10);
  });

  test(
    'closing while peer initialization is pending cannot revive it',
    () async {
      final resources = _ResourceCounter();
      final initializeGate = Completer<void>();
      final adapter = _FakePeerAdapter(resources: resources)
        ..initializeGate = initializeGate;
      final session = ControllerPeerSession(
        adapter: adapter,
        configuration: const ControllerPeerConfiguration(),
      );

      final start = session.start();
      await Future<void>.delayed(Duration.zero);
      final expectation = expectLater(
        start,
        throwsA(
          isA<PeerSessionException>().having(
            (error) => error.code,
            'code',
            PeerSessionErrorCode.closed,
          ),
        ),
      );
      await session.close();
      initializeGate.complete();
      await expectation;

      expect(session.state, ControllerPeerState.closed);
      expect(adapter.closeCount, 1);
      expect(resources.live, 0);
    },
  );

  test(
    'closing during a remote answer cannot revive the peer session',
    () async {
      final answerGate = Completer<void>();
      final adapter = _FakePeerAdapter()..answerGate = answerGate;
      final session = ControllerPeerSession(
        adapter: adapter,
        configuration: const ControllerPeerConfiguration(),
      );
      await session.start();

      final applying = session.applyVerifiedAnswer(_answerSdp);
      await Future<void>.delayed(Duration.zero);
      final result = expectLater(
        applying,
        throwsA(
          isA<PeerSessionException>().having(
            (error) => error.code,
            'code',
            PeerSessionErrorCode.closed,
          ),
        ),
      );
      await session.close();
      answerGate.complete();
      await result;

      expect(session.state, ControllerPeerState.closed);
      expect(adapter.closeCount, 1);
    },
  );

  test('closing during ICE restart cannot revive the peer session', () async {
    final restartGate = Completer<void>();
    final adapter = _FakePeerAdapter()..restartGate = restartGate;
    final session = ControllerPeerSession(
      adapter: adapter,
      configuration: const ControllerPeerConfiguration(),
    );
    await session.start();
    await session.applyVerifiedAnswer(_answerSdp);
    adapter.emit(ControllerPeerEvent.connected);

    final restarting = session.restartIce();
    await Future<void>.delayed(Duration.zero);
    final result = expectLater(
      restarting,
      throwsA(
        isA<PeerSessionException>().having(
          (error) => error.code,
          'code',
          PeerSessionErrorCode.closed,
        ),
      ),
    );
    await session.close();
    restartGate.complete();
    await result;

    expect(session.state, ControllerPeerState.closed);
    expect(adapter.closeCount, 1);
  });
}

final class _FakePeerAdapter implements ControllerPeerAdapter {
  _FakePeerAdapter({this.resources});

  final _ResourceCounter? resources;
  final Object videoRenderer = Object();
  final List<String> operations = <String>[];
  ControllerPeerConfiguration? configuration;
  Completer<void>? initializeGate;
  Completer<void>? answerGate;
  Completer<void>? restartGate;
  bool failInitialize = false;
  int closeCount = 0;
  bool _created = false;
  ControllerPeerCallbacks? _callbacks;

  @override
  int reliableBufferedAmount = 0;

  @override
  Future<int> readReliableBufferedAmount() async => reliableBufferedAmount;

  @override
  int fastBufferedAmount = 0;

  @override
  Object get renderer => videoRenderer;

  @override
  Future<ControllerPeerOffer> initialize(
    ControllerPeerConfiguration configuration,
    ControllerPeerCallbacks callbacks,
  ) async {
    this.configuration = configuration;
    _callbacks = callbacks;
    operations.add('initialize');
    _created = true;
    resources?.create();
    await initializeGate?.future;
    if (failInitialize) {
      throw StateError('peer failed');
    }
    return ControllerPeerOffer(
      sdp: _offerSdp,
      dtlsFingerprintSha256: Uint8List.fromList(List<int>.filled(32, 0x44)),
    );
  }

  void emit(ControllerPeerEvent event) => _callbacks?.onEvent(event);

  @override
  Future<ControllerPeerOffer> restartIce() async {
    operations.add('restart-ice');
    await restartGate?.future;
    return ControllerPeerOffer(
      sdp: _restartOfferSdp,
      dtlsFingerprintSha256: Uint8List.fromList(List<int>.filled(32, 0x55)),
    );
  }

  @override
  Future<void> addRemoteCandidate(IceCandidate candidate) async {
    operations.add('candidate:${candidate.candidate}');
  }

  @override
  Future<void> setRemoteAnswer(String sdp) async {
    operations.add('answer');
    await answerGate?.future;
  }

  @override
  Future<void> sendFast(Uint8List bytes) async {}

  @override
  Future<void> sendReliable(Uint8List bytes) async {}

  @override
  Future<void> close() async {
    closeCount += 1;
    if (_created) {
      _created = false;
      resources?.close();
    }
  }
}

final class _ResourceCounter {
  int created = 0;
  int closed = 0;
  int live = 0;

  void create() {
    created += 1;
    live += 1;
  }

  void close() {
    closed += 1;
    live -= 1;
  }
}
