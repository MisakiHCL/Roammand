// SPDX-License-Identifier: MPL-2.0

part of 'peer_session.dart';

final class FlutterWebRtcPeerAdapter
    implements ControllerPeerAdapter, ControllerPeerStatsProvider {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  final PeerStatsParser _statsParser = PeerStatsParser();
  RTCPeerConnection? _peer;
  RTCDataChannel? _reliable;
  RTCDataChannel? _fast;
  MediaStream? _ownedRemoteVideoStream;
  Future<void>? _rendererInitialization;
  Future<void>? _closeFuture;
  final Set<Future<void>> _videoBindingTasks = <Future<void>>{};
  bool _closed = false;
  bool _peerConnected = false;
  bool _reportedConnected = false;
  bool _transportFailureReported = false;

  @override
  Object get renderer => _renderer;

  @override
  int get reliableBufferedAmount => _reliable?.bufferedAmount ?? 0;

  @override
  Future<int> readReliableBufferedAmount() async {
    final channel = _reliable;
    if (_closed || channel == null) {
      throw const PeerSessionException(PeerSessionErrorCode.closed);
    }
    return channel.getBufferedAmount();
  }

  @override
  int get fastBufferedAmount => _fast?.bufferedAmount ?? 0;

  @override
  Future<ControllerPeerOffer> initialize(
    ControllerPeerConfiguration configuration,
    ControllerPeerCallbacks callbacks,
  ) async {
    if (_peer != null || _closed) {
      throw const PeerSessionException(PeerSessionErrorCode.state);
    }
    configuration.validate();
    var operation = _PeerDebugOperation.initializeRenderer;
    try {
      final rendererInitialization = _renderer.initialize();
      _rendererInitialization = rendererInitialization;
      try {
        await rendererInitialization;
      } finally {
        if (identical(_rendererInitialization, rendererInitialization)) {
          _rendererInitialization = null;
        }
      }
      if (_closed) {
        throw const PeerSessionException(PeerSessionErrorCode.closed);
      }
      operation = _PeerDebugOperation.createPeerConnection;
      final peer = await createPeerConnection(
        <String, dynamic>{
          'sdpSemantics': 'unified-plan',
          'iceTransportPolicy': configuration.iceTransportPolicy.name,
          'iceServers': configuration.iceServers
              .map(
                (server) => <String, dynamic>{
                  'urls': server.urls,
                  if (server.username.isNotEmpty) 'username': server.username,
                  if (server.credential.isNotEmpty)
                    'credential': server.credential,
                },
              )
              .toList(growable: false),
        },
        const <String, dynamic>{
          'mandatory': <String, dynamic>{},
          'optional': <Map<String, dynamic>>[],
        },
      );
      if (_closed) {
        await _closeUnownedPeer(peer);
        throw const PeerSessionException(PeerSessionErrorCode.closed);
      }
      _peer = peer;
      peer.onIceCandidate = (candidate) {
        final value = candidate.candidate;
        if (!_closed && value != null && value.isNotEmpty) {
          callbacks.onLocalCandidate(
            IceCandidate(
              candidate: value,
              sdpMid: candidate.sdpMid ?? '',
              sdpMLineIndex: candidate.sdpMLineIndex ?? 0,
            ),
          );
        }
      };
      peer.onConnectionState = (state) {
        switch (state) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            _peerConnected = true;
            _reportConnectedWhenReady(callbacks);
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            _peerConnected = false;
            _reportTransportFailure(
              callbacks,
              ControllerPeerEvent.disconnected,
            );
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            _peerConnected = false;
            _reportTransportFailure(callbacks, ControllerPeerEvent.failed);
          case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
            _peerConnected = false;
            _reportedConnected = false;
          case RTCPeerConnectionState.RTCPeerConnectionStateNew:
          case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
            break;
        }
      };
      peer.onTrack = (event) {
        if (!_closed && event.track.kind == _videoMediaKind) {
          _startRemoteVideoBinding(event);
        }
      };

      operation = _PeerDebugOperation.addVideoTransceiver;
      final video = await peer.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      _throwIfClosed();
      operation = _PeerDebugOperation.readVideoCapabilities;
      final capabilities = await getRtpReceiverCapabilities('video');
      _throwIfClosed();
      final codecs = _preferCodecCapabilities(
        capabilities.codecs ?? const <RTCRtpCodecCapability>[],
        configuration.videoCodecPreference,
      );
      if (codecs.isNotEmpty) {
        operation = _PeerDebugOperation.setVideoCodecs;
        await video.setCodecPreferences(codecs);
        _throwIfClosed();
      }

      operation = _PeerDebugOperation.createReliableDataChannel;
      final reliable = await peer.createDataChannel(
        configuration.reliableChannel.label,
        _ExactDataChannelInit(
          ordered: configuration.reliableChannel.ordered,
          maxRetransmits: configuration.reliableChannel.maxRetransmits,
        ),
      );
      if (_closed) {
        await _closeUnownedChannel(reliable);
        throw const PeerSessionException(PeerSessionErrorCode.closed);
      }
      _reliable = reliable;
      operation = _PeerDebugOperation.createFastDataChannel;
      final fast = await peer.createDataChannel(
        configuration.fastChannel.label,
        _ExactDataChannelInit(
          ordered: configuration.fastChannel.ordered,
          maxRetransmits: configuration.fastChannel.maxRetransmits,
        ),
      );
      if (_closed) {
        await _closeUnownedChannel(fast);
        throw const PeerSessionException(PeerSessionErrorCode.closed);
      }
      _fast = fast;
      _observeInputChannel(_reliable!, callbacks);
      _observeInputChannel(_fast!, callbacks);
      operation = _PeerDebugOperation.createOffer;
      final created = await peer.createOffer(_receiveVideoOfferConstraints);
      _throwIfClosed();
      final preferredSdp = preferDesktopVideoCodecs(created.sdp ?? '');
      if (preferredSdp.isEmpty) {
        throw const PeerSessionException(PeerSessionErrorCode.peer);
      }
      operation = _PeerDebugOperation.setLocalDescription;
      await peer.setLocalDescription(
        RTCSessionDescription(preferredSdp, 'offer'),
      );
      _throwIfClosed();
      return ControllerPeerOffer(
        sdp: preferredSdp,
        dtlsFingerprintSha256: extractSha256DtlsFingerprint(preferredSdp),
      );
    } catch (error) {
      _debugPeerFailure(operation, error);
      await close();
      rethrow;
    }
  }

  @override
  Future<void> setRemoteAnswer(String sdp) async {
    final peer = _peer;
    if (_closed || peer == null) {
      throw const PeerSessionException(PeerSessionErrorCode.closed);
    }
    try {
      await peer.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    } catch (error) {
      _debugPeerFailure(_PeerDebugOperation.setRemoteAnswer, error);
      rethrow;
    }
  }

  @override
  Future<ControllerPeerOffer> restartIce() async {
    final peer = _peer;
    if (_closed || peer == null) {
      throw const PeerSessionException(PeerSessionErrorCode.closed);
    }
    await peer.restartIce();
    final created = await peer.createOffer(_receiveVideoOfferConstraints);
    final preferredSdp = preferDesktopVideoCodecs(created.sdp ?? '');
    if (preferredSdp.isEmpty) {
      throw const PeerSessionException(PeerSessionErrorCode.peer);
    }
    await peer.setLocalDescription(
      RTCSessionDescription(preferredSdp, 'offer'),
    );
    return ControllerPeerOffer(
      sdp: preferredSdp,
      dtlsFingerprintSha256: extractSha256DtlsFingerprint(preferredSdp),
    );
  }

  @override
  Future<void> addRemoteCandidate(IceCandidate candidate) async {
    final peer = _peer;
    if (_closed || peer == null) {
      throw const PeerSessionException(PeerSessionErrorCode.closed);
    }
    try {
      await peer.addCandidate(
        RTCIceCandidate(
          candidate.candidate,
          candidate.sdpMid,
          candidate.sdpMLineIndex,
        ),
      );
    } catch (error) {
      _debugPeerFailure(_PeerDebugOperation.addRemoteCandidate, error);
      rethrow;
    }
  }

  @override
  Future<void> sendReliable(Uint8List bytes) async {
    final channel = _reliable;
    await _send(channel, bytes);
    // Native send completion only acknowledges enqueueing. Refresh the actual
    // queue size before admitting the next reliable message.
    await channel!.getBufferedAmount();
  }

  @override
  Future<void> sendFast(Uint8List bytes) => _send(_fast, bytes);

  @override
  Future<PeerAggregateStats?> getAggregateStats() async {
    final peer = _peer;
    if (_closed || peer == null) {
      return null;
    }
    final reports = await peer.getStats();
    return _statsParser.parse(
      reports.map(
        (report) => PeerStatsRecord(
          id: report.id,
          type: report.type,
          timestampMs: report.timestamp / 1000,
          values: Map<Object?, Object?>.from(report.values),
        ),
      ),
    );
  }

  Future<void> _bindRemoteVideoTrack(RTCTrackEvent event) async {
    final hasRemoteStream = event.streams.isNotEmpty;
    MediaStream? ownedStream;
    try {
      final MediaStream stream;
      if (hasRemoteStream) {
        stream = event.streams.first;
      } else {
        // Unified Plan permits onTrack without an associated MediaStream. The
        // native renderer still needs a stream container to attach the track.
        ownedStream = await createLocalMediaStream(_localMediaStreamOwnerTag);
        await ownedStream.addTrack(event.track);
        stream = ownedStream;
      }
      if (_closed) {
        await ownedStream?.dispose();
        return;
      }

      await _renderer.setSrcObject(stream: stream, trackId: event.track.id);
      if (_closed) {
        await _bestEffortPeerCleanup(
          () => _renderer.setSrcObject(stream: null),
        );
        await _bestEffortPeerCleanup(() async => ownedStream?.dispose());
        return;
      }
      final previousOwnedStream = _ownedRemoteVideoStream;
      _ownedRemoteVideoStream = ownedStream;
      if (previousOwnedStream != null && previousOwnedStream != ownedStream) {
        await previousOwnedStream.dispose();
      }
    } catch (error) {
      if (ownedStream != null && ownedStream != _ownedRemoteVideoStream) {
        try {
          await ownedStream.dispose();
        } catch (_) {}
      }
      _debugPeerFailure(_PeerDebugOperation.bindRemoteVideo, error);
    }
  }

  void _startRemoteVideoBinding(RTCTrackEvent event) {
    late final Future<void> task;
    task = _bindRemoteVideoTrack(event);
    _videoBindingTasks.add(task);
    unawaited(
      task.whenComplete(() {
        _videoBindingTasks.remove(task);
      }),
    );
  }

  Future<void> _send(RTCDataChannel? channel, Uint8List bytes) async {
    if (_closed ||
        channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw const PeerSessionException(PeerSessionErrorCode.peer);
    }
    await channel.send(RTCDataChannelMessage.fromBinary(bytes));
  }

  void _observeInputChannel(
    RTCDataChannel channel,
    ControllerPeerCallbacks callbacks,
  ) {
    channel.onDataChannelState = (state) {
      if (_closed) return;
      switch (state) {
        case RTCDataChannelState.RTCDataChannelClosing:
        case RTCDataChannelState.RTCDataChannelClosed:
          _reportTransportFailure(callbacks, ControllerPeerEvent.disconnected);
        case RTCDataChannelState.RTCDataChannelConnecting:
        case RTCDataChannelState.RTCDataChannelOpen:
          _reportConnectedWhenReady(callbacks);
      }
    };
  }

  void _reportTransportFailure(
    ControllerPeerCallbacks callbacks,
    ControllerPeerEvent event,
  ) {
    _reportedConnected = false;
    if (_closed || _transportFailureReported) {
      return;
    }
    _transportFailureReported = true;
    callbacks.onEvent(event);
  }

  void _reportConnectedWhenReady(ControllerPeerCallbacks callbacks) {
    if (_closed ||
        _reportedConnected ||
        !_peerConnected ||
        !_inputChannelIsOpen(_reliable) ||
        !_inputChannelIsOpen(_fast)) {
      return;
    }
    _transportFailureReported = false;
    _reportedConnected = true;
    callbacks.onEvent(ControllerPeerEvent.connected);
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    final reliable = _reliable;
    final fast = _fast;
    final peer = _peer;
    _reliable = null;
    _fast = null;
    _peer = null;
    _peerConnected = false;
    _reportedConnected = false;
    _transportFailureReported = false;
    if (reliable != null) reliable.onDataChannelState = null;
    if (fast != null) fast.onDataChannelState = null;
    if (peer != null) {
      peer.onIceCandidate = null;
      peer.onConnectionState = null;
      peer.onTrack = null;
    }
    await _bestEffortPeerCleanup(() async => reliable?.close());
    await _bestEffortPeerCleanup(() async => fast?.close());
    await _bestEffortPeerCleanup(() async => peer?.close());
    await _bestEffortPeerCleanup(() async => peer?.dispose());
    final rendererInitialization = _rendererInitialization;
    if (rendererInitialization != null) {
      await _bestEffortPeerCleanup(() => rendererInitialization);
    }
    if (_videoBindingTasks.isNotEmpty) {
      await Future.wait<void>(List<Future<void>>.of(_videoBindingTasks));
    }
    final ownedRemoteVideoStream = _ownedRemoteVideoStream;
    _ownedRemoteVideoStream = null;
    await _bestEffortPeerCleanup(() => _renderer.setSrcObject(stream: null));
    await _bestEffortPeerCleanup(_renderer.dispose);
    await _bestEffortPeerCleanup(() async => ownedRemoteVideoStream?.dispose());
  }

  void _throwIfClosed() {
    if (_closed) {
      throw const PeerSessionException(PeerSessionErrorCode.closed);
    }
  }
}

Future<void> _closeUnownedPeer(RTCPeerConnection peer) async {
  await _bestEffortPeerCleanup(peer.close);
  await _bestEffortPeerCleanup(peer.dispose);
}

Future<void> _closeUnownedChannel(RTCDataChannel channel) =>
    _bestEffortPeerCleanup(channel.close);

Future<void> _bestEffortPeerCleanup(Future<void> Function() cleanup) async {
  try {
    await cleanup();
  } catch (_) {
    // Every native resource is released independently during teardown.
  }
}

enum _PeerDebugOperation {
  initializeRenderer,
  createPeerConnection,
  addVideoTransceiver,
  readVideoCapabilities,
  setVideoCodecs,
  createReliableDataChannel,
  createFastDataChannel,
  createOffer,
  setLocalDescription,
  setRemoteAnswer,
  addRemoteCandidate,
  bindRemoteVideo,
}

bool _inputChannelIsOpen(RTCDataChannel? channel) =>
    channel?.state == RTCDataChannelState.RTCDataChannelOpen;

void _debugPeerFailure(_PeerDebugOperation operation, Object error) {
  if (!kDebugMode) return;
  final cause = switch (error) {
    PeerSessionException(:final code) => code.name,
    _ => error.runtimeType.toString(),
  };
  debugPrint('[remote] peer_operation=${operation.name} cause=$cause');
}

final class _ExactDataChannelInit extends RTCDataChannelInit {
  _ExactDataChannelInit({required bool ordered, required int? maxRetransmits}) {
    this.ordered = ordered;
    this.maxRetransmits = maxRetransmits ?? -1;
    binaryType = 'binary';
  }

  @override
  Map<String, dynamic> toMap() => <String, dynamic>{
    'ordered': ordered,
    if (maxRetransmits >= 0) 'maxRetransmits': maxRetransmits,
    'protocol': protocol,
    'negotiated': negotiated,
    'id': id,
  };
}

List<RTCRtpCodecCapability> _preferCodecCapabilities(
  List<RTCRtpCodecCapability> codecs,
  List<String> preference,
) {
  final ordered = <RTCRtpCodecCapability>[];
  final seen = <RTCRtpCodecCapability>{};
  for (final name in preference) {
    for (final codec in codecs) {
      if (codec.mimeType.toUpperCase() == 'VIDEO/${name.toUpperCase()}') {
        ordered.add(codec);
        seen.add(codec);
      }
    }
  }
  ordered.addAll(codecs.where((codec) => !seen.contains(codec)));
  return ordered;
}

String preferDesktopVideoCodecs(String sdp) {
  final lines = sdp.split('\r\n');
  final payloadCodec = <String, String>{};
  final rtpMap = RegExp(r'^a=rtpmap:(\d+)\s+([^/\s]+)', caseSensitive: false);
  for (final line in lines) {
    final match = rtpMap.firstMatch(line);
    if (match != null) {
      payloadCodec[match.group(1)!] = match.group(2)!.toUpperCase();
    }
  }
  for (var index = 0; index < lines.length; index += 1) {
    if (!lines[index].startsWith('m=video ')) {
      continue;
    }
    final parts = lines[index].split(' ');
    if (parts.length <= 3) {
      continue;
    }
    final payloads = parts.sublist(3);
    final preferred = <String>[];
    for (final codec in const <String>['H264', 'VP8']) {
      preferred.addAll(
        payloads.where((payload) => payloadCodec[payload] == codec),
      );
    }
    preferred.addAll(payloads.where((payload) => !preferred.contains(payload)));
    lines[index] = <String>[...parts.take(3), ...preferred].join(' ');
    break;
  }
  return lines.join('\r\n');
}

Uint8List extractSha256DtlsFingerprint(String sdp) {
  final match = RegExp(
    r'^a=fingerprint:sha-256\s+([0-9A-Fa-f:]+)\s*$',
    multiLine: true,
  ).firstMatch(sdp.replaceAll('\r\n', '\n'));
  if (match == null) {
    throw const PeerSessionException(PeerSessionErrorCode.peer);
  }
  final values = match.group(1)!.split(':');
  if (values.length != 32) {
    throw const PeerSessionException(PeerSessionErrorCode.peer);
  }
  try {
    return Uint8List.fromList(
      values
          .map((value) {
            if (value.length != 2) {
              throw const FormatException();
            }
            return int.parse(value, radix: 16);
          })
          .toList(growable: false),
    );
  } on FormatException {
    throw const PeerSessionException(PeerSessionErrorCode.peer);
  }
}
