// SPDX-License-Identifier: MPL-2.0

use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
};

use prost::Message;
use roammand_privileged_bridge::{
    client::BridgeRpc,
    rpc::FramedBridgeRpc,
    transport::{LocalBridgeTransport, TransportError},
};
use roammand_protocol::roammand::v1::{
    AcquirePrivilegedLeaseRequest, PrivilegedBridgeClientFrame, PrivilegedBridgeServerFrame,
    PrivilegedFastPointerEvent, PrivilegedLease, ProtocolVersion, SessionPermission,
    privileged_bridge_client_frame, privileged_bridge_server_frame,
};

struct FakeTransport {
    sent: Arc<Mutex<Vec<Vec<u8>>>>,
    incoming: VecDeque<Vec<u8>>,
    failed: Arc<Mutex<bool>>,
}

impl LocalBridgeTransport for FakeTransport {
    fn send(&mut self, frame: &[u8]) -> Result<(), TransportError> {
        self.sent.lock().expect("sent").push(frame.to_vec());
        Ok(())
    }

    fn receive(&mut self) -> Result<Vec<u8>, TransportError> {
        self.incoming
            .pop_front()
            .ok_or(TransportError::Disconnected)
    }

    fn try_receive(&mut self) -> Result<Option<Vec<u8>>, TransportError> {
        Ok(self.incoming.pop_front())
    }

    fn fail_closed(&mut self) {
        *self.failed.lock().expect("failed") = true;
    }
}

#[test]
fn strictly_decodes_frames_and_queues_events_while_waiting_for_a_response() {
    let sent = Arc::new(Mutex::new(Vec::new()));
    let failed = Arc::new(Mutex::new(false));
    let event = server_frame(
        "event-1",
        1,
        privileged_bridge_server_frame::Payload::FastPointer(PrivilegedFastPointerEvent {
            lease_id: vec![0x11; 16],
            generation: 3,
            encoded_envelope: vec![0x51; 8],
        }),
    );
    let response = server_frame(
        "lease-1",
        1,
        privileged_bridge_server_frame::Payload::Lease(PrivilegedLease {
            lease_id: vec![0x11; 16],
            generation: 3,
            issued_at_unix_ms: 10,
            expires_at_unix_ms: 20,
            session_id: vec![0x21; 16],
            permissions: vec![SessionPermission::ViewScreen as i32],
            controller_display_name: "Controller".to_owned(),
        }),
    );
    let transport = FakeTransport {
        sent: Arc::clone(&sent),
        incoming: VecDeque::from([event.encode_to_vec(), response.encode_to_vec()]),
        failed: Arc::clone(&failed),
    };
    let mut rpc = FramedBridgeRpc::new(Box::new(transport));
    let request = PrivilegedBridgeClientFrame {
        protocol_version: Some(version()),
        request_id: "lease-1".to_owned(),
        sequence: 1,
        payload: Some(privileged_bridge_client_frame::Payload::AcquireLease(
            AcquirePrivilegedLeaseRequest::default(),
        )),
    };

    assert_eq!(rpc.call(request.clone()).expect("response"), response);
    assert_eq!(rpc.try_event().expect("event"), Some(event));
    assert_eq!(
        PrivilegedBridgeClientFrame::decode(sent.lock().expect("sent")[0].as_slice())
            .expect("request"),
        request
    );
    assert!(!*failed.lock().expect("failed"));
}

#[test]
fn malformed_or_unsolicited_responses_fail_closed() {
    for incoming in [
        vec![0xff, 0xff],
        server_frame(
            "another-request",
            1,
            privileged_bridge_server_frame::Payload::Lease(PrivilegedLease {
                lease_id: vec![0x11; 16],
                generation: 3,
                issued_at_unix_ms: 10,
                expires_at_unix_ms: 20,
                session_id: vec![0x21; 16],
                permissions: vec![SessionPermission::ViewScreen as i32],
                controller_display_name: "Controller".to_owned(),
            }),
        )
        .encode_to_vec(),
        server_frame(
            "lease-1",
            2,
            privileged_bridge_server_frame::Payload::Lease(PrivilegedLease {
                lease_id: vec![0x11; 16],
                generation: 3,
                issued_at_unix_ms: 10,
                expires_at_unix_ms: 20,
                session_id: vec![0x21; 16],
                permissions: vec![SessionPermission::ViewScreen as i32],
                controller_display_name: "Controller".to_owned(),
            }),
        )
        .encode_to_vec(),
    ] {
        let failed = Arc::new(Mutex::new(false));
        let transport = FakeTransport {
            sent: Arc::new(Mutex::new(Vec::new())),
            incoming: VecDeque::from([incoming]),
            failed: Arc::clone(&failed),
        };
        let mut rpc = FramedBridgeRpc::new(Box::new(transport));
        let result = rpc.call(PrivilegedBridgeClientFrame {
            protocol_version: Some(version()),
            request_id: "lease-1".to_owned(),
            sequence: 1,
            payload: Some(privileged_bridge_client_frame::Payload::AcquireLease(
                AcquirePrivilegedLeaseRequest::default(),
            )),
        });

        assert!(result.is_err());
        assert!(*failed.lock().expect("failed"));
    }
}

fn server_frame(
    request_id: &str,
    sequence: u64,
    payload: privileged_bridge_server_frame::Payload,
) -> PrivilegedBridgeServerFrame {
    PrivilegedBridgeServerFrame {
        protocol_version: Some(version()),
        request_id: request_id.to_owned(),
        sequence,
        payload: Some(payload),
    }
}

const fn version() -> ProtocolVersion {
    ProtocolVersion { major: 1, minor: 0 }
}
