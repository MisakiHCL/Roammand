// SPDX-License-Identifier: MPL-2.0

use std::{collections::VecDeque, sync::Mutex};

use prost::Message;

use roammand_host_platform::MemorySecretStore;
use roammand_host_webrtc::{
    HostPeerSession, HostWebRtcError, PeerAnswer, PeerBackend, PeerIceCandidate, RemoteInputSink,
    SessionConfig,
};
use roammand_protocol::roammand::v1::{
    DevicePlatform, EmergencyStopRemoteSessionRequest, LocalIpcClientFrame, PairingInvitationKind,
    SessionPermission, SignalingEnvelope, local_ipc_client_frame, signaling_envelope,
    web_rtc_negotiation,
};

use super::*;
use crate::{
    AuthorizationRegistry, HostIdentity, MemoryGrantStore, RemotePeerEvent, RemotePeerEventSource,
    RemoteSessionContext, RemoteSessionFactory, RemoteSessionParts,
    remote_session_state::ActiveSession,
};

struct TestResources(Arc<Mutex<bool>>);

impl PeerBackend for TestResources {
    fn start(&mut self, _: &SessionConfig, _: &str) -> Result<PeerAnswer, HostWebRtcError> {
        Ok(PeerAnswer {
            sdp: "v=0\r\n".to_owned(),
            dtls_fingerprint_sha256: vec![4; 32],
        })
    }
    fn close(&mut self) -> Result<(), HostWebRtcError> {
        *self.0.lock().unwrap() = true;
        Ok(())
    }
}

impl RemoteInputSink for TestResources {
    fn release_all(&mut self) -> Result<(), HostWebRtcError> {
        Ok(())
    }
}

struct NoFactory;
impl RemoteSessionFactory for NoFactory {
    fn create(
        &mut self,
        _: &SessionConfig,
        _: &RemoteSessionContext,
    ) -> Result<RemoteSessionParts, RemoteSessionError> {
        Err(RemoteSessionError::Peer)
    }
}

struct QueuedEvents(Arc<Mutex<VecDeque<RemotePeerEvent>>>);
impl RemotePeerEventSource for QueuedEvents {
    fn try_recv(&self) -> Result<Option<RemotePeerEvent>, RemoteSessionError> {
        Ok(self.0.lock().unwrap().pop_front())
    }
}

fn service() -> Arc<HostService> {
    let identity = HostIdentity::load_or_create(
        &MemorySecretStore::new(),
        "Test Host",
        DevicePlatform::Macos,
    )
    .unwrap();
    let authorization = AuthorizationRegistry::load(
        identity.device_identity().device_id.clone(),
        Arc::new(MemoryGrantStore::new()),
    )
    .unwrap();
    Arc::new(HostService::new(identity, authorization, [1; 16], 1))
}

struct ActiveFixture {
    coordinator: RemoteSessionCoordinator,
    closed: Arc<Mutex<bool>>,
    events: Arc<Mutex<VecDeque<RemotePeerEvent>>>,
}

fn active_coordinator(deadline: Option<u64>, events: VecDeque<RemotePeerEvent>) -> ActiveFixture {
    let service = service();
    let session_id = vec![2; 16];
    let controller_device_id = vec![3; 32];
    service
        .register_active_session(session_id.clone(), controller_device_id.clone())
        .unwrap();
    let closed = Arc::new(Mutex::new(false));
    let events = Arc::new(Mutex::new(events));
    let config = SessionConfig::new(IceTransportPolicy::All);
    let mut session = HostPeerSession::new(
        session_id.clone(),
        &[
            SessionPermission::ViewScreen,
            SessionPermission::ControlInput,
        ],
        config,
        Box::new(TestResources(Arc::clone(&closed))),
        Box::new(TestResources(Arc::clone(&closed))),
    )
    .unwrap();
    session.accept_offer("v=0\r\n").unwrap();
    session.mark_connected().unwrap();
    if deadline.is_some() {
        session.begin_reconnect().unwrap();
    }
    let mut coordinator = RemoteSessionCoordinator::new(service, Box::new(NoFactory)).unwrap();
    coordinator.active = Some(ActiveSession {
        controller_device_id,
        session_id,
        session,
        events: Box::new(QueuedEvents(Arc::clone(&events))),
        reconnect: None,
        reconnect_generation: 0,
        reconnect_deadline_unix_ms: deadline,
    });
    ActiveFixture {
        coordinator,
        closed,
        events,
    }
}

#[test]
fn signaling_backoff_grows_is_bounded_and_resets() {
    let mut low = SignalingBackoff::default();
    let mut high = SignalingBackoff::default();
    for maximum in [2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000] {
        let minimum = maximum / 2;
        assert_eq!(low.delay_with_sample(0), Duration::from_millis(minimum));
        assert_eq!(
            high.delay_with_sample(maximum - minimum),
            Duration::from_millis(maximum)
        );
    }
    high.reset();
    assert_eq!(high.delay_with_sample(0), Duration::from_secs(1));
    assert_ne!(
        SignalingBackoff::default().delay_with_sample(1),
        SignalingBackoff::default().delay_with_sample(999)
    );
}

#[tokio::test(start_paused = true)]
async fn offline_operation_expires_resources_without_signaling_or_peer_events() {
    let now = now_unix_ms().unwrap();
    let ActiveFixture {
        mut coordinator,
        closed,
        ..
    } = active_coordinator(Some(now + 45_000), VecDeque::new());
    let mut terminations = coordinator.subscribe_session_terminations();
    let (_shutdown, mut shutdown) = watch::channel(false);
    let operation = async {
        sleep(Duration::from_mins(1)).await;
        Ok(7)
    };
    let check = async {
        sleep(Duration::from_secs(44)).await;
        assert!(!*closed.lock().unwrap());
        sleep(Duration::from_secs(2)).await;
        assert!(
            *closed.lock().unwrap(),
            "capture must close before the connection attempt completes"
        );
    };
    let (result, ()) = tokio::join!(
        await_offline_operation(
            operation,
            &mut coordinator,
            &mut terminations,
            &mut shutdown
        ),
        check
    );
    assert_eq!(result.unwrap(), Some(7));
    assert!(!coordinator.has_active_session());
    assert_eq!(coordinator.service.active_session_count(), 0);
}

#[tokio::test(start_paused = true)]
async fn offline_operation_still_honors_local_stop_and_shutdown() {
    let ActiveFixture {
        mut coordinator,
        closed,
        ..
    } = active_coordinator(None, VecDeque::new());
    let service = Arc::clone(&coordinator.service);
    let mut terminations = coordinator.subscribe_session_terminations();
    let (shutdown, mut receiver) = watch::channel(false);
    let stop = async {
        sleep(Duration::from_secs(1)).await;
        let _ = service.handle_frame(
            &LocalIpcClientFrame {
                payload: Some(local_ipc_client_frame::Payload::EmergencyStopRemoteSession(
                    EmergencyStopRemoteSessionRequest {},
                )),
                ..Default::default()
            },
            now_unix_ms().unwrap(),
        );
        sleep(Duration::from_secs(1)).await;
        assert!(*closed.lock().unwrap());
        shutdown.send(true).unwrap();
    };
    let (result, ()) = tokio::join!(
        await_offline_operation(
            std::future::pending::<Result<(), RuntimeError>>(),
            &mut coordinator,
            &mut terminations,
            &mut receiver
        ),
        stop
    );
    assert_eq!(result.unwrap(), None);
    assert!(!coordinator.has_active_session());
}

#[test]
fn peer_input_batches_preserve_reliable_sequences_and_yield_after_a_bounded_count() {
    use roammand_protocol::roammand::v1::{
        ProtocolVersion, ReleaseAllInput, ReliableInputEnvelope,
    };
    let now = now_unix_ms().unwrap();
    let events = (1..=100).map(|sequence| RemotePeerEvent::ReliableInput(ReliableInputEnvelope {
        protocol_version: Some(ProtocolVersion { major: 1, minor: 0 }),
        session_id: vec![2; 16],
        sequence,
        event: Some(roammand_protocol::roammand::v1::reliable_input_envelope::Event::ReleaseAllInput(ReleaseAllInput {})),
    }.encode_to_vec())).collect();
    let ActiveFixture {
        mut coordinator,
        events: queued,
        closed,
    } = active_coordinator(None, events);
    assert!(
        coordinator
            .poll_peer_events_with_budget(now, Duration::MAX)
            .unwrap()
            .is_empty()
    );
    assert_eq!(queued.lock().unwrap().len(), 36);
    assert!(
        coordinator
            .poll_peer_events_with_budget(now, Duration::MAX)
            .unwrap()
            .is_empty()
    );
    assert!(queued.lock().unwrap().is_empty());
    assert!(!*closed.lock().unwrap());
}

#[test]
fn peer_batches_yield_before_network_sends_and_preserve_ice_order() {
    let events = (0..3)
        .map(|index| {
            RemotePeerEvent::LocalIceCandidate(PeerIceCandidate {
                candidate: format!("candidate:{index}"),
                sdp_mid: "0".to_owned(),
                sdp_m_line_index: 0,
            })
        })
        .collect();
    let ActiveFixture {
        mut coordinator,
        events: queued,
        ..
    } = active_coordinator(None, events);
    for index in 0..3 {
        let outbound = coordinator
            .poll_peer_events_with_budget(now_unix_ms().unwrap(), Duration::MAX)
            .unwrap();
        assert_eq!(outbound.len(), 1);
        assert_eq!(queued.lock().unwrap().len(), 2 - index);
        let frame = SignalingEnvelope::decode(outbound[0].opaque_envelope.as_slice()).unwrap();
        let Some(signaling_envelope::Payload::WebrtcNegotiation(negotiation)) = frame.payload
        else {
            panic!("expected negotiation")
        };
        let Some(web_rtc_negotiation::Payload::IceCandidate(candidate)) = negotiation.payload
        else {
            panic!("expected ICE")
        };
        assert_eq!(candidate.candidate, format!("candidate:{index}"));
    }
    assert!(
        coordinator
            .poll_peer_events(now_unix_ms().unwrap())
            .unwrap()
            .is_empty()
    );
}

#[tokio::test(start_paused = true)]
async fn pairing_notifies_work_and_deadlines_without_idle_polling() {
    let service = service();
    assert!(
        timeout(Duration::from_secs(1), service.pairing_activity())
            .await
            .is_err()
    );
    assert_eq!(service.pairing_deadline_unix_ms().unwrap(), None);
    service.pairing_signaling_connected().unwrap();
    let mut notifications = service.subscribe_host_pairing_states();
    let status = service
        .start_host_pairing(
            PairingInvitationKind::Qr,
            "wss://signal.example.test/ws",
            1_000,
        )
        .unwrap();
    assert_eq!(service.pairing_deadline_unix_ms().unwrap(), Some(121_000));
    timeout(Duration::from_secs(1), service.pairing_activity())
        .await
        .unwrap();
    assert_eq!(notifications.try_recv().unwrap(), status);
    assert_eq!(service.poll_pairing_outbound(1_001).unwrap().len(), 1);
    // A queued notification can coalesce while the outbound frame is drained.
    let _ = timeout(Duration::from_millis(1), service.pairing_activity()).await;
    for _ in 0..100 {
        assert!(service.poll_pairing_outbound(1_002).unwrap().is_empty());
    }
    assert!(notifications.try_recv().is_err());
    assert!(
        timeout(Duration::from_secs(1), service.pairing_activity())
            .await
            .is_err()
    );
    service.poll_pairing_outbound(121_000).unwrap();
    assert_eq!(service.pairing_deadline_unix_ms().unwrap(), None);
    assert!(notifications.try_recv().unwrap().revision > status.revision);
    timeout(Duration::from_secs(1), service.pairing_activity())
        .await
        .unwrap();
}
