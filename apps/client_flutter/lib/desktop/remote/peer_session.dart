// SPDX-License-Identifier: MPL-2.0

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

import '../../diagnostics/diagnostics_collector.dart';
import '../../diagnostics/diagnostics_model.dart';
import 'input_sender.dart';
import 'session_authenticator.dart';

part 'flutter_webrtc_peer_adapter.dart';

const reliableInputChannelLabel = 'input.reliable';
const fastPointerChannelLabel = 'pointer.fast';
const _maximumIceServers = 8;
const _maximumIceUrlsPerServer = 8;
const _maximumIceUrlBytes = 2048;
const _maximumIceCredentialBytes = 1024;
const _videoMediaKind = 'video';
const _localMediaStreamOwnerTag = 'local';
const _receiveVideoOfferConstraints = <String, dynamic>{
  'mandatory': <String, dynamic>{
    'OfferToReceiveVideo': true,
    'OfferToReceiveAudio': false,
  },
  'optional': <Map<String, dynamic>>[],
};

enum DesktopIceTransportPolicy { all, relay }

final class DesktopIceServer {
  const DesktopIceServer({
    required this.urls,
    this.username = '',
    this.credential = '',
  });

  final List<String> urls;
  final String username;
  final String credential;

  void validate() {
    if (urls.isEmpty || urls.length > _maximumIceUrlsPerServer) {
      throw const PeerSessionException(PeerSessionErrorCode.configuration);
    }
    for (final value in urls) {
      final uri = Uri.tryParse(value);
      if (uri == null ||
          value.length > _maximumIceUrlBytes ||
          !const <String>{
            'stun',
            'stuns',
            'turn',
            'turns',
          }.contains(uri.scheme)) {
        throw const PeerSessionException(PeerSessionErrorCode.configuration);
      }
    }
    if (username.length > _maximumIceCredentialBytes ||
        credential.length > _maximumIceCredentialBytes) {
      throw const PeerSessionException(PeerSessionErrorCode.configuration);
    }
    final hasTurn = urls.any(
      (value) => value.startsWith('turn:') || value.startsWith('turns:'),
    );
    if (hasTurn && (username.isEmpty || credential.isEmpty)) {
      throw const PeerSessionException(PeerSessionErrorCode.configuration);
    }
  }
}

final class DesktopDataChannelConfiguration {
  const DesktopDataChannelConfiguration({
    required this.label,
    required this.ordered,
    this.maxRetransmits,
  });

  final String label;
  final bool ordered;
  final int? maxRetransmits;
}

final class ControllerPeerConfiguration {
  const ControllerPeerConfiguration({
    this.iceTransportPolicy = DesktopIceTransportPolicy.all,
    this.iceServers = const <DesktopIceServer>[],
    this.videoCodecPreference = const <String>['H264', 'VP8'],
    this.reliableChannel = const DesktopDataChannelConfiguration(
      label: reliableInputChannelLabel,
      ordered: true,
    ),
    this.fastChannel = const DesktopDataChannelConfiguration(
      label: fastPointerChannelLabel,
      ordered: false,
      maxRetransmits: 0,
    ),
  });

  final DesktopIceTransportPolicy iceTransportPolicy;
  final List<DesktopIceServer> iceServers;
  final List<String> videoCodecPreference;
  final DesktopDataChannelConfiguration reliableChannel;
  final DesktopDataChannelConfiguration fastChannel;

  void validate() {
    if (iceServers.length > _maximumIceServers ||
        videoCodecPreference.length != 2 ||
        videoCodecPreference[0].toUpperCase() != 'H264' ||
        videoCodecPreference[1].toUpperCase() != 'VP8' ||
        reliableChannel.label != reliableInputChannelLabel ||
        !reliableChannel.ordered ||
        reliableChannel.maxRetransmits != null ||
        fastChannel.label != fastPointerChannelLabel ||
        fastChannel.ordered ||
        fastChannel.maxRetransmits != 0) {
      throw const PeerSessionException(PeerSessionErrorCode.configuration);
    }
    for (final server in iceServers) {
      server.validate();
    }
    if (iceTransportPolicy == DesktopIceTransportPolicy.relay &&
        !iceServers.any(
          (server) => server.urls.any(
            (url) => url.startsWith('turn:') || url.startsWith('turns:'),
          ),
        )) {
      throw const PeerSessionException(PeerSessionErrorCode.configuration);
    }
  }
}

final class ControllerPeerOffer {
  ControllerPeerOffer({
    required this.sdp,
    required List<int> dtlsFingerprintSha256,
  }) : dtlsFingerprintSha256 = Uint8List.fromList(dtlsFingerprintSha256);

  final String sdp;
  final Uint8List dtlsFingerprintSha256;
}

enum ControllerPeerEvent { connected, disconnected, failed }

final class ControllerPeerCallbacks {
  const ControllerPeerCallbacks({
    required this.onLocalCandidate,
    required this.onEvent,
  });

  final void Function(IceCandidate candidate) onLocalCandidate;
  final void Function(ControllerPeerEvent event) onEvent;
}

abstract interface class ControllerPeerAdapter {
  Object get renderer;

  int get reliableBufferedAmount;

  Future<int> readReliableBufferedAmount();

  int get fastBufferedAmount;

  Future<ControllerPeerOffer> initialize(
    ControllerPeerConfiguration configuration,
    ControllerPeerCallbacks callbacks,
  );

  Future<ControllerPeerOffer> restartIce();

  Future<void> setRemoteAnswer(String sdp);

  Future<void> addRemoteCandidate(IceCandidate candidate);

  Future<void> sendReliable(Uint8List bytes);

  Future<void> sendFast(Uint8List bytes);

  Future<void> close();
}

abstract interface class ControllerPeerStatsProvider {
  Future<PeerAggregateStats?> getAggregateStats();
}

enum ControllerPeerState {
  idle,
  starting,
  awaitingVerifiedAnswer,
  connecting,
  connected,
  reconnecting,
  failed,
  closed,
}

enum PeerSessionErrorCode { configuration, state, candidateLimit, peer, closed }

final class PeerSessionException implements Exception {
  const PeerSessionException(this.code);

  final PeerSessionErrorCode code;

  @override
  String toString() => 'PeerSessionException(${code.name})';
}

final class ControllerPeerSession {
  ControllerPeerSession({required this.adapter, required this.configuration});

  factory ControllerPeerSession.production({
    required ControllerPeerConfiguration configuration,
  }) => ControllerPeerSession(
    adapter: FlutterWebRtcPeerAdapter(),
    configuration: configuration,
  );

  final ControllerPeerAdapter adapter;
  final ControllerPeerConfiguration configuration;
  final PendingIceCandidates _pendingCandidates = PendingIceCandidates();
  final StreamController<ControllerPeerEvent> _events =
      StreamController<ControllerPeerEvent>.broadcast();
  ControllerPeerState _state = ControllerPeerState.idle;
  bool _answerApplied = false;
  bool _answerApplicationInFlight = false;
  bool _closed = false;

  ControllerPeerState get state => _state;
  Object get videoRenderer => adapter.renderer;
  Stream<ControllerPeerEvent> get events => _events.stream;
  InputDataChannel get reliableInput => _PeerInputChannel(adapter, true);
  InputDataChannel get fastInput => _PeerInputChannel(adapter, false);

  Future<PeerAggregateStats?> getAggregateStats() {
    if (adapter case final ControllerPeerStatsProvider provider) {
      return provider.getAggregateStats();
    }
    return Future<PeerAggregateStats?>.value();
  }

  Future<ControllerPeerOffer> start() async {
    if (_state != ControllerPeerState.idle) {
      throw const PeerSessionException(PeerSessionErrorCode.state);
    }
    configuration.validate();
    _state = ControllerPeerState.starting;
    try {
      final offer = await adapter.initialize(
        configuration,
        ControllerPeerCallbacks(
          onLocalCandidate: _onLocalCandidate,
          onEvent: _onPeerEvent,
        ),
      );
      if (_closed) {
        throw const PeerSessionException(PeerSessionErrorCode.closed);
      }
      if (offer.sdp.isEmpty || offer.dtlsFingerprintSha256.length != 32) {
        throw const PeerSessionException(PeerSessionErrorCode.peer);
      }
      _state = ControllerPeerState.awaitingVerifiedAnswer;
      return offer;
    } on PeerSessionException {
      await _failAndClose();
      rethrow;
    } catch (_) {
      await _failAndClose();
      throw const PeerSessionException(PeerSessionErrorCode.peer);
    }
  }

  Future<void> applyVerifiedAnswer(String sdp) async {
    if (_closed ||
        _state != ControllerPeerState.awaitingVerifiedAnswer ||
        _answerApplicationInFlight) {
      throw const PeerSessionException(PeerSessionErrorCode.state);
    }
    _answerApplicationInFlight = true;
    try {
      await adapter.setRemoteAnswer(sdp);
      _requireOpen();
      _answerApplied = true;
      for (final candidate in _pendingCandidates.drain()) {
        await adapter.addRemoteCandidate(candidate);
        _requireOpen();
      }
      _state = ControllerPeerState.connecting;
    } on PeerSessionException catch (error) {
      if (_closed || error.code == PeerSessionErrorCode.closed) {
        throw const PeerSessionException(PeerSessionErrorCode.closed);
      }
      await _handleAnswerFailure();
      throw const PeerSessionException(PeerSessionErrorCode.peer);
    } catch (_) {
      if (_closed) {
        throw const PeerSessionException(PeerSessionErrorCode.closed);
      }
      await _handleAnswerFailure();
      throw const PeerSessionException(PeerSessionErrorCode.peer);
    } finally {
      _answerApplicationInFlight = false;
    }
  }

  Future<void> _handleAnswerFailure() async {
    if (_restarting) {
      _pendingCandidates.drain();
      _answerApplied = false;
      _state = ControllerPeerState.reconnecting;
    } else {
      await _failAndClose();
    }
  }

  bool _restarting = false;

  Future<ControllerPeerOffer> restartIce() async {
    if (_closed ||
        _answerApplicationInFlight ||
        (_state != ControllerPeerState.connected &&
            _state != ControllerPeerState.connecting &&
            _state != ControllerPeerState.awaitingVerifiedAnswer &&
            _state != ControllerPeerState.reconnecting)) {
      throw const PeerSessionException(PeerSessionErrorCode.state);
    }
    _pendingCandidates.drain();
    _answerApplied = false;
    _state = ControllerPeerState.reconnecting;
    _restarting = true;
    try {
      final offer = await adapter.restartIce();
      _requireOpen();
      if (offer.sdp.isEmpty || offer.dtlsFingerprintSha256.length != 32) {
        throw const PeerSessionException(PeerSessionErrorCode.peer);
      }
      _state = ControllerPeerState.awaitingVerifiedAnswer;
      return offer;
    } on PeerSessionException catch (error) {
      if (_closed || error.code == PeerSessionErrorCode.closed) {
        throw const PeerSessionException(PeerSessionErrorCode.closed);
      }
      _state = ControllerPeerState.reconnecting;
      throw const PeerSessionException(PeerSessionErrorCode.peer);
    } catch (_) {
      if (_closed) {
        throw const PeerSessionException(PeerSessionErrorCode.closed);
      }
      _state = ControllerPeerState.reconnecting;
      throw const PeerSessionException(PeerSessionErrorCode.peer);
    }
  }

  Future<void> addRemoteCandidate(IceCandidate candidate) async {
    if (_closed ||
        (_state != ControllerPeerState.awaitingVerifiedAnswer &&
            _state != ControllerPeerState.connecting &&
            _state != ControllerPeerState.connected)) {
      throw const PeerSessionException(PeerSessionErrorCode.state);
    }
    if (!_answerApplied) {
      try {
        _pendingCandidates.add(candidate);
      } on PendingIceLimitException {
        throw const PeerSessionException(PeerSessionErrorCode.candidateLimit);
      }
      return;
    }
    try {
      await adapter.addRemoteCandidate(candidate);
    } catch (_) {
      await _failAndClose();
      throw const PeerSessionException(PeerSessionErrorCode.peer);
    }
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _answerApplicationInFlight = false;
    _restarting = false;
    _pendingCandidates.drain();
    try {
      await adapter.close();
    } catch (_) {
      // Closing event streams must not depend on a native cleanup succeeding.
    }
    _state = ControllerPeerState.closed;
    await _localCandidateController.close();
    await _events.close();
  }

  void _requireOpen() {
    if (_closed) {
      throw const PeerSessionException(PeerSessionErrorCode.closed);
    }
  }

  void _onLocalCandidate(IceCandidate candidate) {
    if (!_closed) {
      _localCandidateController.add(candidate.deepCopy());
    }
  }

  final StreamController<IceCandidate> _localCandidateController =
      StreamController<IceCandidate>.broadcast();

  Stream<IceCandidate> get localCandidates => _localCandidateController.stream;

  void _onPeerEvent(ControllerPeerEvent event) {
    if (_closed) {
      return;
    }
    switch (event) {
      case ControllerPeerEvent.connected:
        _state = ControllerPeerState.connected;
        _restarting = false;
      case ControllerPeerEvent.disconnected:
      case ControllerPeerEvent.failed:
        _state = ControllerPeerState.reconnecting;
    }
    _events.add(event);
  }

  Future<void> _failAndClose() async {
    if (_closed) {
      return;
    }
    _state = ControllerPeerState.failed;
    _closed = true;
    _pendingCandidates.drain();
    try {
      await adapter.close();
    } catch (_) {
      // Preserve the stable peer failure while still releasing Dart streams.
    }
    await _localCandidateController.close();
    await _events.close();
  }
}

final class _PeerInputChannel implements RefreshableInputDataChannel {
  const _PeerInputChannel(this._adapter, this._reliable);

  final ControllerPeerAdapter _adapter;
  final bool _reliable;

  @override
  int get bufferedAmount =>
      _reliable ? _adapter.reliableBufferedAmount : _adapter.fastBufferedAmount;

  @override
  Future<int> readBufferedAmount() => _reliable
      ? _adapter.readReliableBufferedAmount()
      : Future<int>.value(_adapter.fastBufferedAmount);

  @override
  Future<void> send(Uint8List bytes) =>
      _reliable ? _adapter.sendReliable(bytes) : _adapter.sendFast(bytes);
}
