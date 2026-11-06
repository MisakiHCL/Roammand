// SPDX-License-Identifier: MPL-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roammand/desktop/host_agent/host_agent_client.dart';
import 'package:roammand/desktop/host_agent/local_ipc_framer.dart';
import 'package:roammand/desktop/host_agent/local_ipc_transport.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

const _instanceId = <int>[
  0x11,
  0x11,
  0x11,
  0x11,
  0x11,
  0x11,
  0x11,
  0x11,
  0x11,
  0x11,
  0x11,
  0x11,
  0x11,
  0x11,
  0x11,
  0x11,
];
const _serverNonce = <int>[
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
  0x22,
];
const _clientNonce = <int>[
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
  0x33,
];
const _tokenBytes = <int>[
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
  0x44,
];

void main() {
  test('close seals a connection whose connector completes late', () async {
    final connector = _DelayedConnector();
    final client = HostAgentClient(
      connector: connector,
      randomBytes: (_) => Uint8List.fromList(_clientNonce),
    );
    final connecting = client.connect();
    final expectation = expectLater(
      connecting,
      throwsA(isA<HostAgentDisconnectedException>()),
    );

    await client.close();
    final transport = _LateLocalIpcTransport();
    final token = Uint8List.fromList(_tokenBytes);
    connector.complete(LocalIpcConnection(transport, token));
    await expectation;

    expect(transport.closeCount, 1);
    expect(token, everyElement(0));
    expect(client.isReady, isFalse);
  });

  test('invalid connector token still closes the accepted transport', () async {
    final transport = _LateLocalIpcTransport();
    final token = Uint8List.fromList(<int>[0x44]);
    final client = HostAgentClient(
      connector: FakeConnector(transport, token),
      randomBytes: (_) => Uint8List.fromList(_clientNonce),
    );

    await expectLater(
      client.connect(),
      throwsA(isA<HostAgentProtocolException>()),
    );

    expect(transport.closeCount, 1);
    expect(token, everyElement(0));
    expect(client.isReady, isFalse);
  });

  test('times out connector and discards a late connection', () async {
    final connector = _DelayedConnector();
    final client = HostAgentClient(
      connector: connector,
      randomBytes: (_) => Uint8List.fromList(_clientNonce),
      handshakeTimeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      client.connect(),
      throwsA(isA<HostAgentTimeoutException>()),
    );

    final transport = _LateLocalIpcTransport();
    final token = Uint8List.fromList(_tokenBytes);
    connector.complete(LocalIpcConnection(transport, token));
    await pumpEventQueue();
    expect(transport.closeCount, 1);
    expect(token, everyElement(0));
  });

  test('clears the client nonce when proof authentication times out', () async {
    final transport = FakeLocalIpcTransport();
    final nonce = Uint8List.fromList(_clientNonce);
    final client = HostAgentClient(
      connector: FakeConnector(transport, Uint8List.fromList(_tokenBytes)),
      randomBytes: (_) => nonce,
      handshakeTimeout: const Duration(milliseconds: 10),
    );
    final connecting = client.connect();
    await _sendChallenge(transport);
    final authentication = await transport.takeClientFrame();
    expect(authentication.authenticate.clientNonce, _clientNonce);

    await expectLater(connecting, throwsA(isA<HostAgentTimeoutException>()));

    expect(nonce, everyElement(0));
    expect(transport.closeCount, 1);
  });

  test(
    'authenticates, correlates out-of-order responses, and routes events',
    () async {
      final fixture = await _connectedFixture();
      final eventFuture = fixture.client.sessionTerminations.first;
      final statusFuture = fixture.client.getHostStatus();
      final grantsFuture = fixture.client.listControllerGrants();
      final first = await fixture.transport.takeClientFrame();
      final second = await fixture.transport.takeClientFrame();
      final statusRequest = first.hasGetHostStatus() ? first : second;
      final grantsRequest = first.hasListControllerGrants() ? first : second;

      fixture.transport.sendServerFrame(
        LocalIpcServerFrame(
          protocolVersion: _version(),
          sessionTerminated: SessionTerminatedEvent(
            sessionId: List<int>.filled(16, 0x51),
            controllerDeviceId: List<int>.filled(32, 0x61),
            reason: ErrorCode.ERROR_CODE_AUTH_REVOKED,
          ),
        ),
      );
      fixture.transport.sendServerFrame(
        LocalIpcServerFrame(
          protocolVersion: _version(),
          requestId: grantsRequest.requestId,
          controllerGrantList: ControllerGrantList(),
        ),
      );
      fixture.transport.sendServerFrame(
        LocalIpcServerFrame(
          protocolVersion: _version(),
          requestId: statusRequest.requestId,
          hostStatus: HostStatus(
            identity: DeviceIdentity(displayName: 'Test Host'),
            agentInstanceId: _instanceId,
            controllerGrantCount: 0,
            privilegedBridge: PrivilegedBridgeStatusSnapshot(
              state: PrivilegedBridgeState
                  .PRIVILEGED_BRIDGE_STATE_USER_SESSION_ONLY,
            ),
          ),
        ),
      );

      expect((await statusFuture).identity.displayName, 'Test Host');
      expect(await grantsFuture, isEmpty);
      expect((await eventFuture).reason, ErrorCode.ERROR_CODE_AUTH_REVOKED);
      await fixture.client.close();
    },
  );

  test('publishes bridge status and sends local emergency stop', () async {
    final fixture = await _connectedFixture();
    final bridgeStatus = fixture.client.privilegedBridgeStates.first;
    final hostStatus = fixture.client.getHostStatus();
    final statusRequest = await fixture.transport.takeClientFrame();
    fixture.transport.sendServerFrame(
      LocalIpcServerFrame(
        protocolVersion: _version(),
        requestId: statusRequest.requestId,
        hostStatus: HostStatus(
          identity: DeviceIdentity(displayName: 'Test Host'),
          agentInstanceId: _instanceId,
          privilegedBridge: PrivilegedBridgeStatusSnapshot(
            state: PrivilegedBridgeState.PRIVILEGED_BRIDGE_STATE_READY,
            interactiveSession: PrivilegedSessionDescriptor(
              platform: DevicePlatform.DEVICE_PLATFORM_MACOS,
              osSessionId: Int64(501),
              desktopKind:
                  InteractiveDesktopKind.INTERACTIVE_DESKTOP_KIND_NORMAL,
              generation: Int64.ONE,
            ),
            helperConnected: true,
          ),
        ),
      ),
    );

    expect(
      (await hostStatus).privilegedBridge.state,
      PrivilegedBridgeState.PRIVILEGED_BRIDGE_STATE_READY,
    );
    expect(
      (await bridgeStatus).state,
      PrivilegedBridgeState.PRIVILEGED_BRIDGE_STATE_READY,
    );

    final stopping = fixture.client.emergencyStopRemoteSession();
    final stopRequest = await fixture.transport.takeClientFrame();
    expect(stopRequest.hasEmergencyStopRemoteSession(), isTrue);
    fixture.transport.sendServerFrame(
      LocalIpcServerFrame(
        protocolVersion: _version(),
        requestId: stopRequest.requestId,
        emergencyStopRemoteSessionResult: EmergencyStopRemoteSessionResult(
          terminatedSessionCount: 1,
        ),
      ),
    );
    expect((await stopping).terminatedSessionCount, 1);
    await fixture.client.close();
  });

  test(
    'rejects a wrong server proof, clears token, and closes idempotently',
    () async {
      final transport = FakeLocalIpcTransport();
      final token = Uint8List.fromList(_tokenBytes);
      final client = HostAgentClient(
        connector: FakeConnector(transport, token),
        randomBytes: (_) => Uint8List.fromList(_clientNonce),
      );
      final connecting = client.connect();
      await _sendChallenge(transport);
      final authentication = await transport.takeClientFrame();
      expect(
        authentication.authenticate.clientProof,
        _proof('PRD-IPC-CLIENT-V1'),
      );
      transport.sendServerFrame(
        LocalIpcServerFrame(
          protocolVersion: _version(),
          requestId: authentication.requestId,
          authenticated: LocalIpcAuthenticated(
            serverProof: List<int>.filled(32, 0xff),
          ),
        ),
      );

      await expectLater(connecting, throwsA(isA<HostAgentProtocolException>()));
      expect(token, everyElement(0));
      await client.close();
      await client.close();
      expect(transport.closeCount, 1);
    },
  );

  test(
    'times out, rejects duplicate IDs and the pending request overflow',
    () async {
      final timeoutFixture = await _connectedFixture(
        requestTimeout: const Duration(milliseconds: 10),
      );
      await expectLater(
        timeoutFixture.client.getHostStatus(),
        throwsA(isA<HostAgentTimeoutException>()),
      );
      await timeoutFixture.client.close();

      final duplicateFixture = await _connectedFixture(
        requestIdFactory: () => 'duplicate',
      );
      final first = duplicateFixture.client.getHostStatus();
      unawaited(first.then<void>((_) {}, onError: (_) {}));
      await expectLater(
        duplicateFixture.client.listControllerGrants(),
        throwsA(isA<HostAgentProtocolException>()),
      );
      await duplicateFixture.client.close();

      var requestIndex = 0;
      final pendingFixture = await _connectedFixture(
        requestIdFactory: () => 'pending-${requestIndex++}',
      );
      final pending = <Future<HostStatus>>[];
      for (var index = 0; index < maxLocalIpcPendingRequests; index += 1) {
        final request = pendingFixture.client.getHostStatus();
        unawaited(request.then<void>((_) {}, onError: (_) {}));
        pending.add(request);
      }
      await expectLater(
        pendingFixture.client.getHostStatus(),
        throwsA(isA<HostAgentBusyException>()),
      );
      await pendingFixture.client.close();
    },
  );

  test('a stalled request write still delivers the request deadline', () async {
    final fixture = await _connectedFixture(
      requestTimeout: const Duration(milliseconds: 10),
    );
    final writeGate = Completer<void>();
    fixture.transport.writeGate = writeGate;
    addTearDown(() async {
      writeGate.complete();
      await fixture.client.close();
    });

    await expectLater(
      fixture.client.getHostStatus().timeout(const Duration(seconds: 1)),
      throwsA(isA<HostAgentTimeoutException>()),
    );
  });

  test(
    'a stalled authentication write respects the handshake deadline',
    () async {
      final writeGate = Completer<void>();
      final transport = FakeLocalIpcTransport()..writeGate = writeGate;
      final client = HostAgentClient(
        connector: FakeConnector(transport, Uint8List.fromList(_tokenBytes)),
        randomBytes: (_) => Uint8List.fromList(_clientNonce),
        handshakeTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(() async {
        writeGate.complete();
        await client.close();
      });
      final connecting = client.connect();
      final result = expectLater(
        connecting.timeout(const Duration(seconds: 1)),
        throwsA(isA<HostAgentTimeoutException>()),
      );
      await _sendChallenge(transport);
      await transport.takeClientFrame();
      await result;

      expect(client.isReady, isFalse);
      expect(transport.closeCount, 1);
    },
  );

  test(
    'disconnect completes every pending request with a stable error',
    () async {
      final fixture = await _connectedFixture();
      final status = fixture.client.getHostStatus();
      final grants = fixture.client.listControllerGrants();
      unawaited(status.then<void>((_) {}, onError: (_) {}));
      unawaited(grants.then<void>((_) {}, onError: (_) {}));

      await fixture.transport.disconnect();

      await expectLater(status, throwsA(isA<HostAgentDisconnectedException>()));
      await expectLater(grants, throwsA(isA<HostAgentDisconnectedException>()));
      await fixture.client.close();
    },
  );

  test('requests a role-specific Controller offer signature', () async {
    final fixture = await _connectedFixture();
    final transcript = List<int>.generate(128, (index) => index);
    final signing = fixture.client.signSessionOffer(transcript);
    final request = await fixture.transport.takeClientFrame();

    expect(request.hasSignSessionOffer(), isTrue);
    expect(request.signSessionOffer.canonicalTranscript, transcript);
    fixture.transport.sendServerFrame(
      LocalIpcServerFrame(
        protocolVersion: _version(),
        requestId: request.requestId,
        sessionOfferSignature: SessionOfferSignature(
          controllerDeviceId: List<int>.filled(32, 0x61),
          controllerPublicKey: List<int>.filled(32, 0x62),
          signature: List<int>.filled(64, 0x63),
          transcriptSha256: List<int>.filled(32, 0x64),
        ),
      ),
    );

    final signature = await signing;
    expect(signature.controllerDeviceId, hasLength(32));
    expect(signature.controllerPublicKey, hasLength(32));
    expect(signature.signature, hasLength(64));
    expect(signature.transcriptSha256, hasLength(32));
    await fixture.client.close();
  });

  test('requests a role-bound pairing transcript signature', () async {
    final fixture = await _connectedFixture();
    final transcript = List<int>.generate(196, (index) => index & 0xff);
    final signing = fixture.client.signPairingTranscript(
      transcript,
      PairingIdentityRole.PAIRING_IDENTITY_ROLE_HOST,
    );
    final request = await fixture.transport.takeClientFrame();

    expect(request.hasSignPairingTranscript(), isTrue);
    expect(request.signPairingTranscript.canonicalTranscript, transcript);
    expect(
      request.signPairingTranscript.role,
      PairingIdentityRole.PAIRING_IDENTITY_ROLE_HOST,
    );
    fixture.transport.sendServerFrame(
      LocalIpcServerFrame(
        protocolVersion: _version(),
        requestId: request.requestId,
        pairingTranscriptSignature: PairingTranscriptSignature(
          role: PairingIdentityRole.PAIRING_IDENTITY_ROLE_HOST,
          signerDeviceId: List<int>.filled(32, 0x61),
          signerPublicKey: List<int>.filled(32, 0x62),
          signature: List<int>.filled(64, 0x63),
          transcriptSha256: List<int>.filled(32, 0x64),
        ),
      ),
    );

    final signature = await signing;
    expect(signature.role, PairingIdentityRole.PAIRING_IDENTITY_ROLE_HOST);
    expect(signature.signerDeviceId, hasLength(32));
    expect(signature.signerPublicKey, hasLength(32));
    expect(signature.signature, hasLength(64));
    expect(signature.transcriptSha256, hasLength(32));
    await fixture.client.close();
  });

  test(
    'maps Host pairing controls and routes sanitized state events',
    () async {
      final fixture = await _connectedFixture();
      final rendezvousId = List<int>.filled(16, 0x51);
      final controllerId = List<int>.filled(32, 0x61);

      final startQr = fixture.client.startHostQrPairing(
        'wss://signal.example.test/v1/ws',
      );
      final startQrRequest = await fixture.transport.takeClientFrame();
      expect(startQrRequest.hasStartHostQrPairing(), isTrue);
      expect(
        startQrRequest.startHostQrPairing.signalingEndpoint,
        'wss://signal.example.test/v1/ws',
      );
      fixture.transport.sendServerFrame(
        LocalIpcServerFrame(
          protocolVersion: _version(),
          requestId: startQrRequest.requestId,
          hostPairingStatus: _pairingStatus(
            HostPairingState.HOST_PAIRING_STATE_CREATING,
            1,
            rendezvousId,
          ),
        ),
      );
      expect((await startQr).revision.toInt(), 1);

      final nextEvent = fixture.client.hostPairingStates.first;
      fixture.transport.sendServerFrame(
        LocalIpcServerFrame(
          protocolVersion: _version(),
          hostPairingStateChanged: HostPairingStateChangedEvent(
            status: _pairingStatus(
              HostPairingState.HOST_PAIRING_STATE_WAITING_LOCAL_DECISION,
              2,
              rendezvousId,
            ),
          ),
        ),
      );
      expect(
        (await nextEvent).state,
        HostPairingState.HOST_PAIRING_STATE_WAITING_LOCAL_DECISION,
      );

      final getStatus = fixture.client.getHostPairingStatus();
      final getRequest = await fixture.transport.takeClientFrame();
      expect(getRequest.hasGetHostPairingStatus(), isTrue);
      fixture.transport.sendServerFrame(
        LocalIpcServerFrame(
          protocolVersion: _version(),
          requestId: getRequest.requestId,
          hostPairingStatus: _pairingStatus(
            HostPairingState.HOST_PAIRING_STATE_WAITING_LOCAL_DECISION,
            2,
            rendezvousId,
          ),
        ),
      );
      expect((await getStatus).revision.toInt(), 2);

      final cancel = fixture.client.cancelHostPairing(rendezvousId);
      final cancelRequest = await fixture.transport.takeClientFrame();
      expect(cancelRequest.cancelHostPairing.rendezvousId, rendezvousId);
      fixture.transport.sendServerFrame(
        LocalIpcServerFrame(
          protocolVersion: _version(),
          requestId: cancelRequest.requestId,
          hostPairingStatus: _pairingStatus(
            HostPairingState.HOST_PAIRING_STATE_CANCELLED,
            3,
            rendezvousId,
          ),
        ),
      );
      expect(
        (await cancel).state,
        HostPairingState.HOST_PAIRING_STATE_CANCELLED,
      );

      final accept = fixture.client.acceptHostPairing(
        rendezvousId,
        controllerId,
      );
      final acceptRequest = await fixture.transport.takeClientFrame();
      expect(acceptRequest.acceptHostPairing.rendezvousId, rendezvousId);
      expect(acceptRequest.acceptHostPairing.controllerDeviceId, controllerId);
      fixture.transport.sendServerFrame(
        LocalIpcServerFrame(
          protocolVersion: _version(),
          requestId: acceptRequest.requestId,
          hostPairingStatus: _pairingStatus(
            HostPairingState.HOST_PAIRING_STATE_ACCEPTED,
            4,
            rendezvousId,
          ),
        ),
      );
      await accept;

      final reject = fixture.client.rejectHostPairing(
        rendezvousId,
        controllerId,
      );
      final rejectRequest = await fixture.transport.takeClientFrame();
      expect(rejectRequest.rejectHostPairing.rendezvousId, rendezvousId);
      expect(rejectRequest.rejectHostPairing.controllerDeviceId, controllerId);
      fixture.transport.sendServerFrame(
        LocalIpcServerFrame(
          protocolVersion: _version(),
          requestId: rejectRequest.requestId,
          hostPairingStatus: _pairingStatus(
            HostPairingState.HOST_PAIRING_STATE_REJECTED,
            5,
            rendezvousId,
          ),
        ),
      );
      await reject;

      final startCode = fixture.client.startHostDesktopCodePairing(
        'wss://signal.example.test/v1/ws',
      );
      final startCodeRequest = await fixture.transport.takeClientFrame();
      expect(startCodeRequest.hasStartHostDesktopCodePairing(), isTrue);
      fixture.transport.sendServerFrame(
        LocalIpcServerFrame(
          protocolVersion: _version(),
          requestId: startCodeRequest.requestId,
          hostPairingStatus: _pairingStatus(
            HostPairingState.HOST_PAIRING_STATE_CREATING,
            6,
            rendezvousId,
          ),
        ),
      );
      await startCode;
      await fixture.client.close();
    },
  );

  test('close completes an in-flight handshake immediately', () async {
    final transport = FakeLocalIpcTransport();
    final token = Uint8List.fromList(_tokenBytes);
    final client = HostAgentClient(
      connector: FakeConnector(transport, token),
      randomBytes: (_) => Uint8List.fromList(_clientNonce),
      handshakeTimeout: const Duration(seconds: 1),
    );
    final connecting = client.connect();
    unawaited(connecting.then<void>((_) {}, onError: (_) {}));
    await Future<void>.delayed(Duration.zero);

    await client.close();

    await expectLater(
      connecting,
      throwsA(isA<HostAgentDisconnectedException>()),
    );
    expect(token, everyElement(0));
  });

  test('decodes Rust frames and emits the shared Dart request bytes', () {
    final fixture =
        jsonDecode(
              File(
                '../../conformance/protocol_vectors/local_ipc_v1.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final challenge = LocalIpcServerFrame.fromBuffer(
      _hexDecode(fixture['challenge_server_frame_hex']! as String),
    );
    final authenticated = LocalIpcServerFrame.fromBuffer(
      _hexDecode(fixture['authenticated_server_frame_hex']! as String),
    );
    final status = LocalIpcServerFrame.fromBuffer(
      _hexDecode(fixture['status_response_server_frame_hex']! as String),
    );
    final signature = LocalIpcServerFrame.fromBuffer(
      _hexDecode(fixture['sign_response_server_frame_hex']! as String),
    );
    final pairingSignature = LocalIpcServerFrame.fromBuffer(
      _hexDecode(fixture['pairing_sign_response_server_frame_hex']! as String),
    );
    expect(challenge.challenge.agentInstanceId, _instanceId);
    expect(
      authenticated.authenticated.serverProof,
      _proof('PRD-IPC-SERVER-V1'),
    );
    expect(status.hostStatus.identity.displayName, 'Fixture Host');
    expect(signature.canonicalTranscriptSignature.signature, hasLength(64));
    expect(
      pairingSignature.pairingTranscriptSignature.role,
      PairingIdentityRole.PAIRING_IDENTITY_ROLE_HOST,
    );
    expect(
      pairingSignature.pairingTranscriptSignature.signature,
      hasLength(64),
    );

    final statusRequest = LocalIpcClientFrame(
      protocolVersion: _version(),
      requestId: 'status-1',
      getHostStatus: GetHostStatusRequest(),
    );
    expect(
      _hexEncode(statusRequest.writeToBuffer()),
      fixture['status_request_client_frame_hex'],
    );
    final signRequest = LocalIpcClientFrame.fromBuffer(
      _hexDecode(fixture['sign_request_client_frame_hex']! as String),
    );
    expect(signRequest.requestId, 'sign-1');
    expect(signRequest.signCanonicalTranscript.canonicalTranscript, isNotEmpty);
    final pairingSignRequest = LocalIpcClientFrame.fromBuffer(
      _hexDecode(fixture['pairing_sign_request_client_frame_hex']! as String),
    );
    expect(pairingSignRequest.requestId, 'pairing-sign-1');
    expect(
      pairingSignRequest.signPairingTranscript.role,
      PairingIdentityRole.PAIRING_IDENTITY_ROLE_HOST,
    );
    expect(
      pairingSignRequest.signPairingTranscript.canonicalTranscript,
      isNotEmpty,
    );
  });
}

Future<_Fixture> _connectedFixture({
  Duration requestTimeout = const Duration(seconds: 1),
  String Function()? requestIdFactory,
}) async {
  final transport = FakeLocalIpcTransport();
  final token = Uint8List.fromList(_tokenBytes);
  final client = HostAgentClient(
    connector: FakeConnector(transport, token),
    randomBytes: (_) => Uint8List.fromList(_clientNonce),
    requestTimeout: requestTimeout,
    requestIdFactory: requestIdFactory,
  );
  final connecting = client.connect();
  await _sendChallenge(transport);
  final authentication = await transport.takeClientFrame();
  expect(authentication.authenticate.clientProof, _proof('PRD-IPC-CLIENT-V1'));
  transport.sendServerFrame(
    LocalIpcServerFrame(
      protocolVersion: _version(),
      requestId: authentication.requestId,
      authenticated: LocalIpcAuthenticated(
        serverProof: _proof('PRD-IPC-SERVER-V1'),
      ),
    ),
  );
  await connecting;
  expect(token, everyElement(0));
  return _Fixture(client, transport);
}

Future<void> _sendChallenge(FakeLocalIpcTransport transport) async {
  await Future<void>.delayed(Duration.zero);
  transport.sendServerFrame(
    LocalIpcServerFrame(
      protocolVersion: _version(),
      challenge: LocalIpcChallenge(
        agentInstanceId: _instanceId,
        serverNonce: _serverNonce,
      ),
    ),
  );
}

List<int> _proof(String domain) {
  final hmac = Hmac(sha256, _tokenBytes);
  return hmac.convert(<int>[
    ...domain.codeUnits,
    ..._instanceId,
    ..._serverNonce,
    ..._clientNonce,
  ]).bytes;
}

ProtocolVersion _version() => ProtocolVersion(major: 1, minor: 0);

HostPairingStatusSnapshot _pairingStatus(
  HostPairingState state,
  int revision,
  List<int> rendezvousId,
) => HostPairingStatusSnapshot(
  state: state,
  revision: Int64(revision),
  invitation: HostPairingInvitation(rendezvousId: rendezvousId),
);

Uint8List _hexDecode(String value) => Uint8List.fromList(<int>[
  for (var index = 0; index < value.length; index += 2)
    int.parse(value.substring(index, index + 2), radix: 16),
]);

String _hexEncode(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

class _Fixture {
  const _Fixture(this.client, this.transport);

  final HostAgentClient client;
  final FakeLocalIpcTransport transport;
}

class FakeConnector implements HostAgentConnector {
  const FakeConnector(this.transport, this.token);

  final LocalIpcTransport transport;
  final Uint8List token;

  @override
  Future<LocalIpcConnection> connect() async =>
      LocalIpcConnection(transport, token);
}

class _DelayedConnector implements HostAgentConnector {
  final Completer<LocalIpcConnection> _connection =
      Completer<LocalIpcConnection>();

  void complete(LocalIpcConnection connection) {
    _connection.complete(connection);
  }

  @override
  Future<LocalIpcConnection> connect() => _connection.future;
}

class _LateLocalIpcTransport implements LocalIpcTransport {
  int closeCount = 0;

  @override
  Stream<List<int>> get incoming => const Stream<List<int>>.empty();

  @override
  Future<void> write(Uint8List bytes) async {
    throw StateError('late transport must not be used');
  }

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}

class FakeLocalIpcTransport implements LocalIpcTransport {
  final StreamController<List<int>> _incoming = StreamController<List<int>>();
  final List<Uint8List> _writes = <Uint8List>[];
  final List<Completer<Uint8List>> _writeWaiters = <Completer<Uint8List>>[];
  int closeCount = 0;
  Completer<void>? writeGate;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> write(Uint8List bytes) async {
    final copy = Uint8List.fromList(bytes);
    if (_writeWaiters.isNotEmpty) {
      _writeWaiters.removeAt(0).complete(copy);
    } else {
      _writes.add(copy);
    }
    await writeGate?.future;
  }

  Future<LocalIpcClientFrame> takeClientFrame() async {
    late final Uint8List bytes;
    if (_writes.isNotEmpty) {
      bytes = _writes.removeAt(0);
    } else {
      final waiter = Completer<Uint8List>();
      _writeWaiters.add(waiter);
      bytes = await waiter.future;
    }
    final framer = LocalIpcFramer();
    final frames = framer.add(bytes);
    framer.close();
    expect(frames, hasLength(1));
    return LocalIpcClientFrame.fromBuffer(frames.single);
  }

  void sendServerFrame(LocalIpcServerFrame frame) {
    _incoming.add(LocalIpcFramer.encodePayload(frame.writeToBuffer()));
  }

  Future<void> disconnect() => _incoming.close();

  @override
  Future<void> close() async {
    closeCount += 1;
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
  }
}
