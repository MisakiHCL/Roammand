// SPDX-License-Identifier: MPL-2.0

use std::sync::{Arc, Mutex};

use roammand_host_webrtc::{PeerAnswer, PeerIceCandidate};
use roammand_privileged_bridge::{
    helper::{HelperBackend, HelperProtocol, HelperProtocolError},
    proxy::{ProxyEvent, ProxyRoute},
};
use roammand_protocol::roammand::v1::{
    ClosePrivilegedPeerRequest, IceCandidate, PrivilegedBridgeClientFrame, PrivilegedInputCommand,
    PrivilegedPeerConfiguration, PrivilegedPeerState, ProtocolVersion, ReleaseAllInput,
    ReleasePrivilegedLeaseRequest, SessionDescriptionType, StartPrivilegedPeerRequest,
    WebRtcSessionDescription, privileged_bridge_client_frame, privileged_bridge_server_frame,
    privileged_input_command,
};

#[derive(Default)]
struct FakeBackend {
    operations: Arc<Mutex<Vec<&'static str>>>,
    local_stop: bool,
    event_failure: bool,
}

impl HelperBackend for FakeBackend {
    fn start(
        &mut self,
        _configuration: &PrivilegedPeerConfiguration,
        _offer: &WebRtcSessionDescription,
        _controller_display_name: &str,
    ) -> Result<PeerAnswer, HelperProtocolError> {
        self.operations.lock().expect("operations").push("start");
        Ok(PeerAnswer {
            sdp: "answer".to_owned(),
            dtls_fingerprint_sha256: vec![0x31; 32],
        })
    }

    fn restart(
        &mut self,
        _configuration: &PrivilegedPeerConfiguration,
        _offer: &WebRtcSessionDescription,
        _controller_display_name: &str,
    ) -> Result<PeerAnswer, HelperProtocolError> {
        Err(HelperProtocolError::Backend)
    }

    fn add_candidate(&mut self, _candidate: &IceCandidate) -> Result<(), HelperProtocolError> {
        self.operations
            .lock()
            .expect("operations")
            .push("candidate");
        Ok(())
    }

    fn input(&mut self, _input: &PrivilegedInputCommand) -> Result<(), HelperProtocolError> {
        self.operations.lock().expect("operations").push("input");
        Ok(())
    }

    fn secure_attention(&mut self) -> Result<(), HelperProtocolError> {
        Err(HelperProtocolError::Backend)
    }

    fn close(&mut self) -> Result<(), HelperProtocolError> {
        self.operations.lock().expect("operations").push("close");
        Ok(())
    }

    fn try_event(&mut self) -> Result<Option<ProxyEvent>, HelperProtocolError> {
        if self.event_failure {
            return Err(HelperProtocolError::Backend);
        }
        if self.local_stop {
            self.local_stop = false;
            return Ok(Some(ProxyEvent::LocalStop));
        }
        Ok(Some(ProxyEvent::LocalIceCandidate(PeerIceCandidate {
            candidate: "candidate:local".to_owned(),
            sdp_mid: "0".to_owned(),
            sdp_m_line_index: 0,
        })))
    }

    fn fail_closed(&mut self) {
        self.operations
            .lock()
            .expect("operations")
            .push("fail-closed");
    }
}

#[test]
fn attaches_one_route_and_executes_only_typed_peer_commands() {
    let operations = Arc::new(Mutex::new(Vec::new()));
    let backend = FakeBackend {
        operations: Arc::clone(&operations),
        local_stop: false,
        event_failure: false,
    };
    let mut helper = HelperProtocol::new(Box::new(backend));
    let route = ProxyRoute::new(
        roammand_privileged_bridge::lease::LeaseId::new([0x11; 16]),
        7,
    );

    let answer = helper
        .handle(&start_request(route, 1))
        .expect("start response");
    assert!(matches!(
        answer.payload,
        Some(privileged_bridge_server_frame::Payload::PeerAnswer(_))
    ));
    let input = client_frame(
        2,
        privileged_bridge_client_frame::Payload::InputCommand(PrivilegedInputCommand {
            lease_id: route.lease_id.into_bytes().to_vec(),
            generation: route.generation,
            input: Some(privileged_input_command::Input::ReleaseAll(
                ReleaseAllInput {},
            )),
        }),
    );
    assert!(matches!(
        helper.handle(&input).expect("input").payload,
        Some(privileged_bridge_server_frame::Payload::CommandAccepted(_))
    ));

    let event = helper.try_event().expect("event").expect("some event");
    assert!(matches!(
        event.payload,
        Some(privileged_bridge_server_frame::Payload::LocalIceCandidate(
            _
        ))
    ));
    assert_eq!(event.sequence, 1);

    let release = client_frame(
        3,
        privileged_bridge_client_frame::Payload::ReleaseLease(ReleasePrivilegedLeaseRequest {
            lease_id: route.lease_id.into_bytes().to_vec(),
            generation: route.generation,
        }),
    );
    helper.handle(&release).expect("release");
    assert_eq!(
        *operations.lock().expect("operations"),
        ["start", "input", "close"]
    );
}

#[test]
fn rejects_stale_commands_after_release_without_touching_the_backend() {
    let operations = Arc::new(Mutex::new(Vec::new()));
    let backend = FakeBackend {
        operations: Arc::clone(&operations),
        local_stop: false,
        event_failure: false,
    };
    let mut helper = HelperProtocol::new(Box::new(backend));
    let route = ProxyRoute::new(
        roammand_privileged_bridge::lease::LeaseId::new([0x21; 16]),
        8,
    );
    helper.handle(&start_request(route, 1)).expect("start");
    helper
        .handle(&client_frame(
            2,
            privileged_bridge_client_frame::Payload::ReleaseLease(ReleasePrivilegedLeaseRequest {
                lease_id: route.lease_id.into_bytes().to_vec(),
                generation: route.generation,
            }),
        ))
        .expect("release");
    let stale = client_frame(
        3,
        privileged_bridge_client_frame::Payload::ClosePeer(ClosePrivilegedPeerRequest {
            lease_id: route.lease_id.into_bytes().to_vec(),
            generation: route.generation,
        }),
    );

    assert_eq!(helper.handle(&stale), Err(HelperProtocolError::StaleRoute));
    assert_eq!(*operations.lock().expect("operations"), ["start", "close"]);
}

#[test]
fn encodes_a_local_stop_as_a_terminal_peer_state() {
    let route = ProxyRoute::new(
        roammand_privileged_bridge::lease::LeaseId::new([0x31; 16]),
        9,
    );
    let mut helper = HelperProtocol::new(Box::new(FakeBackend {
        operations: Arc::new(Mutex::new(Vec::new())),
        local_stop: true,
        event_failure: false,
    }));
    helper.handle(&start_request(route, 1)).expect("start");

    let event = helper.try_event().expect("event").expect("local stop");

    let Some(privileged_bridge_server_frame::Payload::PeerStateChanged(state)) = event.payload
    else {
        panic!("expected peer state");
    };
    assert_eq!(
        PrivilegedPeerState::try_from(state.state),
        Ok(PrivilegedPeerState::Closed)
    );
}

#[test]
fn native_event_failure_cleans_up_once_and_rejects_later_commands() {
    let operations = Arc::new(Mutex::new(Vec::new()));
    let mut helper = HelperProtocol::new(Box::new(FakeBackend {
        operations: Arc::clone(&operations),
        local_stop: false,
        event_failure: true,
    }));
    let route = ProxyRoute::new(
        roammand_privileged_bridge::lease::LeaseId::new([0x41; 16]),
        10,
    );
    helper.handle(&start_request(route, 1)).expect("start");

    assert_eq!(helper.try_event(), Err(HelperProtocolError::Backend));
    assert_eq!(helper.try_event(), Err(HelperProtocolError::Backend));
    assert_eq!(
        helper.handle(&start_request(route, 2)),
        Err(HelperProtocolError::Backend)
    );
    helper.shutdown();
    assert_eq!(
        *operations.lock().expect("operations"),
        ["start", "fail-closed"]
    );
}

fn start_request(route: ProxyRoute, sequence: u64) -> PrivilegedBridgeClientFrame {
    client_frame(
        sequence,
        privileged_bridge_client_frame::Payload::StartPeer(StartPrivilegedPeerRequest {
            lease_id: route.lease_id.into_bytes().to_vec(),
            generation: route.generation,
            configuration: Some(PrivilegedPeerConfiguration {
                ice_transport_policy: 1,
                ice_servers: Vec::new(),
            }),
            offer: Some(WebRtcSessionDescription {
                r#type: SessionDescriptionType::Offer as i32,
                sdp: "offer".to_owned(),
                dtls_fingerprint_sha256: vec![0x41; 32],
            }),
            controller_display_name: "Controller".to_owned(),
        }),
    )
}

fn client_frame(
    sequence: u64,
    payload: privileged_bridge_client_frame::Payload,
) -> PrivilegedBridgeClientFrame {
    PrivilegedBridgeClientFrame {
        protocol_version: Some(ProtocolVersion { major: 1, minor: 0 }),
        request_id: format!("request-{sequence}"),
        sequence,
        payload: Some(payload),
    }
}
