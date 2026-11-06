// SPDX-License-Identifier: MPL-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

import 'host_agent_models.dart';
import 'local_ipc_framer.dart';
import 'local_ipc_transport.dart';

export 'host_agent_models.dart';

const maxLocalIpcPendingRequests = 32;
const _nonceBytes = 32;
const _clientProofDomain = 'PRD-IPC-CLIENT-V1';
const _serverProofDomain = 'PRD-IPC-SERVER-V1';
const _authenticationRequestId = 'authenticate';
const _defaultHandshakeTimeout = Duration(seconds: 3);
const _defaultRequestTimeout = Duration(seconds: 5);
const _cleanupTimeout = Duration(seconds: 2);

enum _ClientState {
  disconnected,
  connecting,
  authenticating,
  ready,
  closing,
  closed,
}

final class HostAgentClient implements HostAgentApi {
  HostAgentClient({
    HostAgentConnector? connector,
    Uint8List Function(int length)? randomBytes,
    this.handshakeTimeout = _defaultHandshakeTimeout,
    this.requestTimeout = _defaultRequestTimeout,
    this.requestIdFactory,
  }) : _connector = connector ?? const DefaultHostAgentConnector(),
       _randomBytes = randomBytes ?? _secureRandomBytes,
       assert(handshakeTimeout > Duration.zero),
       assert(requestTimeout > Duration.zero);

  final HostAgentConnector _connector;
  final Uint8List Function(int length) _randomBytes;
  final Duration handshakeTimeout;
  final Duration requestTimeout;
  final String Function()? requestIdFactory;
  final LocalIpcFramer _framer = LocalIpcFramer();
  final Map<String, _PendingRequest> _pending = <String, _PendingRequest>{};
  final StreamController<SessionTerminatedEvent> _sessionTerminations =
      StreamController<SessionTerminatedEvent>.broadcast();
  final StreamController<HostPairingStatusSnapshot> _hostPairingStates =
      StreamController<HostPairingStatusSnapshot>.broadcast();
  final StreamController<PrivilegedBridgeStatusSnapshot>
  _privilegedBridgeStates =
      StreamController<PrivilegedBridgeStatusSnapshot>.broadcast();

  _ClientState _state = _ClientState.disconnected;
  LocalIpcTransport? _transport;
  StreamSubscription<List<int>>? _subscription;
  Completer<LocalIpcChallenge>? _challenge;
  Completer<LocalIpcAuthenticated>? _authenticated;
  Future<void>? _closeFuture;
  int _requestSequence = 0;

  @override
  Stream<SessionTerminatedEvent> get sessionTerminations =>
      _sessionTerminations.stream;

  @override
  Stream<HostPairingStatusSnapshot> get hostPairingStates =>
      _hostPairingStates.stream;

  @override
  Stream<PrivilegedBridgeStatusSnapshot> get privilegedBridgeStates =>
      _privilegedBridgeStates.stream;

  bool get isReady => _state == _ClientState.ready;

  @override
  Future<void> connect() async {
    if (_state != _ClientState.disconnected) {
      throw const HostAgentProtocolException(
        'Host Agent client already started',
      );
    }
    _state = _ClientState.connecting;
    Uint8List? token;
    Uint8List? clientNonce;
    List<int>? clientProof;
    List<int>? expectedServerProof;
    try {
      final pendingConnection = _connector.connect();
      final connection = await pendingConnection.timeout(
        handshakeTimeout,
        onTimeout: () {
          _discardLateConnection(pendingConnection);
          throw const HostAgentTimeoutException(
            'Host Agent connection timed out',
          );
        },
      );
      token = connection.token;
      if (_state != _ClientState.connecting) {
        await _bestEffortHostAgentCleanup(connection.transport.close);
        throw const HostAgentDisconnectedException();
      }
      _transport = connection.transport;
      if (token.length != localIpcTokenBytes) {
        throw const HostAgentProtocolException(
          'Host Agent token length is invalid',
        );
      }
      _challenge = Completer<LocalIpcChallenge>();
      _subscription = connection.transport.incoming.listen(
        _onData,
        onError: _onTransportError,
        onDone: _onTransportDone,
        cancelOnError: false,
      );
      final challenge = await _challenge!.future.timeout(
        handshakeTimeout,
        onTimeout: () => throw const HostAgentTimeoutException(
          'Host Agent handshake timed out',
        ),
      );
      if (_state != _ClientState.connecting) {
        throw const HostAgentDisconnectedException();
      }
      _validateChallenge(challenge, connection.expectedInstanceId);
      clientNonce = _randomBytes(_nonceBytes);
      if (clientNonce.length != _nonceBytes) {
        throw const HostAgentProtocolException(
          'Secure nonce length is invalid',
        );
      }
      clientProof = _proof(
        token,
        _clientProofDomain,
        challenge.agentInstanceId,
        challenge.serverNonce,
        clientNonce,
      );
      _state = _ClientState.authenticating;
      _authenticated = Completer<LocalIpcAuthenticated>();
      await Future.wait<void>(<Future<void>>[
        _write(
          LocalIpcClientFrame(
            protocolVersion: _version(),
            requestId: _authenticationRequestId,
            authenticate: LocalIpcAuthenticate(
              clientNonce: clientNonce,
              clientProof: clientProof,
            ),
          ),
        ).timeout(
          handshakeTimeout,
          onTimeout: () => throw const HostAgentTimeoutException(
            'Host Agent authentication write timed out',
          ),
        ),
        _authenticated!.future
            .timeout(
              handshakeTimeout,
              onTimeout: () => throw const HostAgentTimeoutException(
                'Host Agent proof timed out',
              ),
            )
            .then<void>((_) {}),
      ], eagerError: true);
      final authenticated = await _authenticated!.future;
      if (_state != _ClientState.authenticating) {
        throw const HostAgentDisconnectedException();
      }
      expectedServerProof = _proof(
        token,
        _serverProofDomain,
        challenge.agentInstanceId,
        challenge.serverNonce,
        clientNonce,
      );
      if (!_constantTimeEquals(
        authenticated.serverProof,
        expectedServerProof,
      )) {
        throw const HostAgentProtocolException('Host Agent proof is invalid');
      }
      _state = _ClientState.ready;
    } on HostAgentException {
      await close();
      rethrow;
    } catch (_) {
      await close();
      throw const HostAgentDisconnectedException();
    } finally {
      _clearBytes(expectedServerProof);
      _clearBytes(clientProof);
      _clearBytes(clientNonce);
      _clearBytes(token);
    }
  }

  @override
  Future<HostStatus> getHostStatus() => _sendRequest<HostStatus>(
    LocalIpcClientFrame(getHostStatus: GetHostStatusRequest()),
    (frame) {
      if (!frame.hasHostStatus()) {
        throw const HostAgentProtocolException('Expected Host status response');
      }
      final status = frame.hostStatus;
      if (!status.hasPrivilegedBridge()) {
        throw const HostAgentProtocolException(
          'Host status is missing privileged bridge state',
        );
      }
      validatePrivilegedBridgeStatusSnapshot(status.privilegedBridge);
      _privilegedBridgeStates.add(status.privilegedBridge.deepCopy());
      return status;
    },
  );

  @override
  Future<List<ControllerGrantView>> listControllerGrants() =>
      _sendRequest<List<ControllerGrantView>>(
        LocalIpcClientFrame(
          listControllerGrants: ListControllerGrantsRequest(),
        ),
        (frame) {
          if (!frame.hasControllerGrantList()) {
            throw const HostAgentProtocolException(
              'Expected Controller grant list',
            );
          }
          return List<ControllerGrantView>.unmodifiable(
            frame.controllerGrantList.grants,
          );
        },
      );

  @override
  Future<ControllerGrantView> createControllerGrant(
    DeviceIdentity controller,
    Iterable<SessionPermission> permissions,
  ) => _sendRequest<ControllerGrantView>(
    LocalIpcClientFrame(
      createControllerGrant: CreateControllerGrantRequest(
        controller: controller,
        permissions: permissions,
      ),
    ),
    (frame) {
      if (!frame.hasControllerGrantCreated() ||
          !frame.controllerGrantCreated.hasGrant()) {
        throw const HostAgentProtocolException(
          'Expected created Controller grant',
        );
      }
      return frame.controllerGrantCreated.grant;
    },
  );

  @override
  Future<ControllerGrantRevoked> revokeControllerGrant(List<int> grantId) =>
      _sendRequest<ControllerGrantRevoked>(
        LocalIpcClientFrame(
          revokeControllerGrant: RevokeControllerGrantRequest(grantId: grantId),
        ),
        (frame) {
          if (!frame.hasControllerGrantRevoked()) {
            throw const HostAgentProtocolException(
              'Expected revoked Controller grant',
            );
          }
          return frame.controllerGrantRevoked;
        },
      );

  @override
  Future<EmergencyStopRemoteSessionResult> emergencyStopRemoteSession() =>
      _sendRequest<EmergencyStopRemoteSessionResult>(
        LocalIpcClientFrame(
          emergencyStopRemoteSession: EmergencyStopRemoteSessionRequest(),
        ),
        (frame) {
          if (!frame.hasEmergencyStopRemoteSessionResult()) {
            throw const HostAgentProtocolException(
              'Expected emergency stop response',
            );
          }
          return frame.emergencyStopRemoteSessionResult;
        },
      );

  @override
  Future<CanonicalTranscriptSignature> signCanonicalTranscript(
    List<int> canonicalTranscript,
  ) => _sendRequest<CanonicalTranscriptSignature>(
    LocalIpcClientFrame(
      signCanonicalTranscript: SignCanonicalTranscriptRequest(
        canonicalTranscript: canonicalTranscript,
      ),
    ),
    (frame) {
      if (!frame.hasCanonicalTranscriptSignature()) {
        throw const HostAgentProtocolException('Expected transcript signature');
      }
      return frame.canonicalTranscriptSignature;
    },
  );

  @override
  Future<SessionOfferSignature> signSessionOffer(
    List<int> canonicalTranscript,
  ) => _sendRequest<SessionOfferSignature>(
    LocalIpcClientFrame(
      signSessionOffer: SignSessionOfferRequest(
        canonicalTranscript: canonicalTranscript,
      ),
    ),
    (frame) {
      if (!frame.hasSessionOfferSignature()) {
        throw const HostAgentProtocolException(
          'Expected Controller offer signature',
        );
      }
      return frame.sessionOfferSignature;
    },
  );

  @override
  Future<PairingTranscriptSignature> signPairingTranscript(
    List<int> canonicalTranscript,
    PairingIdentityRole role,
  ) => _sendRequest<PairingTranscriptSignature>(
    LocalIpcClientFrame(
      signPairingTranscript: SignPairingTranscriptRequest(
        canonicalTranscript: canonicalTranscript,
        role: role,
      ),
    ),
    (frame) {
      if (!frame.hasPairingTranscriptSignature()) {
        throw const HostAgentProtocolException(
          'Expected pairing transcript signature',
        );
      }
      return frame.pairingTranscriptSignature;
    },
  );

  @override
  Future<HostPairingStatusSnapshot> startHostQrPairing(
    String signalingEndpoint,
  ) => _sendPairingRequest(
    LocalIpcClientFrame(
      startHostQrPairing: StartHostQrPairingRequest(
        signalingEndpoint: signalingEndpoint,
      ),
    ),
  );

  @override
  Future<HostPairingStatusSnapshot> startHostDesktopCodePairing(
    String signalingEndpoint,
  ) => _sendPairingRequest(
    LocalIpcClientFrame(
      startHostDesktopCodePairing: StartHostDesktopCodePairingRequest(
        signalingEndpoint: signalingEndpoint,
      ),
    ),
  );

  @override
  Future<HostPairingStatusSnapshot> getHostPairingStatus() =>
      _sendPairingRequest(
        LocalIpcClientFrame(
          getHostPairingStatus: GetHostPairingStatusRequest(),
        ),
      );

  @override
  Future<HostPairingStatusSnapshot> cancelHostPairing(List<int> rendezvousId) =>
      _sendPairingRequest(
        LocalIpcClientFrame(
          cancelHostPairing: CancelHostPairingRequest(
            rendezvousId: rendezvousId,
          ),
        ),
      );

  @override
  Future<HostPairingStatusSnapshot> acceptHostPairing(
    List<int> rendezvousId,
    List<int> controllerDeviceId,
  ) => _sendPairingRequest(
    LocalIpcClientFrame(
      acceptHostPairing: AcceptHostPairingRequest(
        rendezvousId: rendezvousId,
        controllerDeviceId: controllerDeviceId,
      ),
    ),
  );

  @override
  Future<HostPairingStatusSnapshot> rejectHostPairing(
    List<int> rendezvousId,
    List<int> controllerDeviceId,
  ) => _sendPairingRequest(
    LocalIpcClientFrame(
      rejectHostPairing: RejectHostPairingRequest(
        rendezvousId: rendezvousId,
        controllerDeviceId: controllerDeviceId,
      ),
    ),
  );

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<HostPairingStatusSnapshot> _sendPairingRequest(
    LocalIpcClientFrame frame,
  ) => _sendRequest<HostPairingStatusSnapshot>(frame, (response) {
    if (!response.hasHostPairingStatus()) {
      throw const HostAgentProtocolException('Expected Host pairing status');
    }
    return response.hostPairingStatus;
  });

  Future<T> _sendRequest<T>(
    LocalIpcClientFrame frame,
    T Function(LocalIpcServerFrame frame) decode,
  ) async {
    if (_state != _ClientState.ready) {
      throw const HostAgentDisconnectedException();
    }
    if (_pending.length >= maxLocalIpcPendingRequests) {
      throw const HostAgentBusyException();
    }
    final requestId = _nextRequestId();
    if (_pending.containsKey(requestId)) {
      throw const HostAgentProtocolException(
        'Duplicate local request identifier',
      );
    }
    frame
      ..protocolVersion = _version()
      ..requestId = requestId;
    final pending = _TypedPendingRequest<T>(decode);
    _pending[requestId] = pending;
    pending.timer = Timer(requestTimeout, () {
      if (_pending.remove(requestId) != null) {
        pending.fail(const HostAgentTimeoutException());
      }
    });
    // Observe the response immediately: a blocked native write must not delay
    // delivery of the request timeout or leave its error without a listener.
    unawaited(
      _write(frame).catchError((Object _) {
        if (identical(_pending[requestId], pending)) {
          _pending.remove(requestId);
          pending.fail(const HostAgentDisconnectedException());
        }
      }),
    );
    return pending.future;
  }

  Future<void> _write(LocalIpcClientFrame frame) async {
    final transport = _transport;
    if (transport == null) {
      throw const HostAgentDisconnectedException();
    }
    await transport.write(LocalIpcFramer.encodePayload(frame.writeToBuffer()));
  }

  void _onData(List<int> chunk) {
    try {
      for (final payload in _framer.add(Uint8List.fromList(chunk))) {
        _handleFrame(LocalIpcServerFrame.fromBuffer(payload));
      }
    } catch (_) {
      _fail(const HostAgentProtocolException());
    }
  }

  void _handleFrame(LocalIpcServerFrame frame) {
    if (!_hasSupportedVersion(frame)) {
      _fail(const HostAgentProtocolException('Unsupported Host Agent version'));
      return;
    }
    switch (_state) {
      case _ClientState.connecting:
        if (!frame.hasChallenge() || frame.requestId.isNotEmpty) {
          _fail(
            const HostAgentProtocolException('Expected Host Agent challenge'),
          );
          return;
        }
        final challenge = _challenge;
        if (challenge == null || challenge.isCompleted) {
          _fail(
            const HostAgentProtocolException('Repeated Host Agent challenge'),
          );
          return;
        }
        challenge.complete(frame.challenge);
      case _ClientState.authenticating:
        if (frame.requestId != _authenticationRequestId) {
          _fail(
            const HostAgentProtocolException(
              'Unexpected authentication response',
            ),
          );
          return;
        }
        if (frame.hasError()) {
          _authenticated?.completeError(HostAgentRemoteException(frame.error));
          return;
        }
        if (!frame.hasAuthenticated()) {
          _fail(const HostAgentProtocolException('Expected Host Agent proof'));
          return;
        }
        final authenticated = _authenticated;
        if (authenticated == null || authenticated.isCompleted) {
          _fail(const HostAgentProtocolException('Repeated Host Agent proof'));
          return;
        }
        authenticated.complete(frame.authenticated);
      case _ClientState.ready:
        if (frame.hasHostPairingStateChanged()) {
          if (frame.requestId.isNotEmpty ||
              !frame.hostPairingStateChanged.hasStatus()) {
            _fail(
              const HostAgentProtocolException('Host pairing event is invalid'),
            );
            return;
          }
          _hostPairingStates.add(frame.hostPairingStateChanged.status);
          return;
        }
        if (frame.hasSessionTerminated()) {
          if (frame.requestId.isNotEmpty) {
            _fail(
              const HostAgentProtocolException(
                'Event contains a request identifier',
              ),
            );
            return;
          }
          _sessionTerminations.add(frame.sessionTerminated);
          return;
        }
        final pending = _pending.remove(frame.requestId);
        if (frame.requestId.isEmpty || pending == null) {
          _fail(
            const HostAgentProtocolException('Unknown Host Agent response'),
          );
          return;
        }
        if (frame.hasError()) {
          pending.fail(HostAgentRemoteException(frame.error));
        } else {
          pending.complete(frame);
        }
      case _ClientState.disconnected:
      case _ClientState.closing:
      case _ClientState.closed:
        return;
    }
  }

  void _onTransportError(Object _) {
    _fail(const HostAgentDisconnectedException());
  }

  void _onTransportDone() {
    try {
      _framer.close();
    } catch (_) {
      _fail(const HostAgentProtocolException());
      return;
    }
    _fail(const HostAgentDisconnectedException());
  }

  void _fail(HostAgentException error) {
    if (_state == _ClientState.closing || _state == _ClientState.closed) {
      return;
    }
    final challenge = _challenge;
    if (challenge != null && !challenge.isCompleted) {
      challenge.completeError(error);
    }
    final authenticated = _authenticated;
    if (authenticated != null && !authenticated.isCompleted) {
      authenticated.completeError(error);
    }
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final request in pending) {
      request.fail(error);
    }
    unawaited(close());
  }

  Future<void> _close() async {
    if (_state == _ClientState.closed) {
      return;
    }
    _state = _ClientState.closing;
    const disconnected = HostAgentDisconnectedException();
    final challenge = _challenge;
    if (challenge != null && !challenge.isCompleted) {
      challenge.completeError(disconnected);
    }
    final authenticated = _authenticated;
    if (authenticated != null && !authenticated.isCompleted) {
      authenticated.completeError(disconnected);
    }
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final request in pending) {
      request.fail(disconnected);
    }
    final subscription = _subscription;
    _subscription = null;
    final transport = _transport;
    _transport = null;
    await _bestEffortHostAgentCleanup(() async => subscription?.cancel());
    await _bestEffortHostAgentCleanup(() async => transport?.close());
    if (!_sessionTerminations.isClosed) {
      await _bestEffortHostAgentCleanup(_sessionTerminations.close);
    }
    if (!_hostPairingStates.isClosed) {
      await _bestEffortHostAgentCleanup(_hostPairingStates.close);
    }
    if (!_privilegedBridgeStates.isClosed) {
      await _bestEffortHostAgentCleanup(_privilegedBridgeStates.close);
    }
    _state = _ClientState.closed;
  }

  String _nextRequestId() {
    final requestId =
        requestIdFactory?.call() ?? 'request-${_requestSequence++}';
    if (requestId.isEmpty ||
        utf8.encode(requestId).length > maxRequestIdUtf8Bytes) {
      throw const HostAgentProtocolException(
        'Invalid local request identifier',
      );
    }
    return requestId;
  }

  static void _validateChallenge(
    LocalIpcChallenge challenge,
    Uint8List? expectedInstanceId,
  ) {
    if (challenge.agentInstanceId.length != agentInstanceIdBytes ||
        challenge.serverNonce.length != _nonceBytes ||
        (expectedInstanceId != null &&
            !_constantTimeEquals(
              challenge.agentInstanceId,
              expectedInstanceId,
            ))) {
      throw const HostAgentProtocolException('Host Agent challenge is invalid');
    }
  }

  static bool _hasSupportedVersion(LocalIpcServerFrame frame) =>
      frame.hasProtocolVersion() &&
      frame.protocolVersion.major == protocolMajorVersion &&
      frame.protocolVersion.minor == minimumProtocolMinorVersion;
}

Future<void> _bestEffortHostAgentCleanup(
  Future<void> Function() cleanup,
) async {
  try {
    await cleanup().timeout(_cleanupTimeout);
  } catch (_) {
    // A failed cleanup must not leave other IPC resources reachable.
  }
}

void _discardLateConnection(Future<LocalIpcConnection> pending) {
  unawaited(
    pending.then<void>((connection) async {
      _clearBytes(connection.token);
      await _bestEffortHostAgentCleanup(connection.transport.close);
    }, onError: (_) {}),
  );
}

void _clearBytes(List<int>? bytes) {
  bytes?.fillRange(0, bytes.length, 0);
}

abstract class _PendingRequest {
  Timer? timer;

  void complete(LocalIpcServerFrame frame);

  void fail(Object error);
}

final class _TypedPendingRequest<T> extends _PendingRequest {
  _TypedPendingRequest(this._decode);

  final T Function(LocalIpcServerFrame frame) _decode;
  final Completer<T> _completer = Completer<T>();

  Future<T> get future => _completer.future;

  @override
  void complete(LocalIpcServerFrame frame) {
    timer?.cancel();
    if (_completer.isCompleted) {
      return;
    }
    try {
      _completer.complete(_decode(frame));
    } catch (error, stackTrace) {
      _completer.completeError(error, stackTrace);
    }
  }

  @override
  void fail(Object error) {
    timer?.cancel();
    if (!_completer.isCompleted) {
      _completer.completeError(error);
    }
  }
}

Uint8List _secureRandomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256), growable: false),
  );
}

List<int> _proof(
  List<int> token,
  String domain,
  List<int> instanceId,
  List<int> serverNonce,
  List<int> clientNonce,
) => Hmac(sha256, token).convert(<int>[
  ...ascii.encode(domain),
  ...instanceId,
  ...serverNonce,
  ...clientNonce,
]).bytes;

bool _constantTimeEquals(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

ProtocolVersion _version() => ProtocolVersion(
  major: protocolMajorVersion,
  minor: minimumProtocolMinorVersion,
);
