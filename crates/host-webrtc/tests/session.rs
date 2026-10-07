// SPDX-License-Identifier: MPL-2.0

use std::sync::{Arc, Mutex};

use roammand_host_webrtc::{
    DATA_CHANNEL_INPUT_RELIABLE, DATA_CHANNEL_POINTER_FAST, DataChannelReliability,
    HostPeerSession, HostSessionState, HostWebRtcError, IceTransportPolicy, PeerAnswer,
    PeerBackend, PeerIceCandidate, RemoteInputSink, SessionConfig, SessionGate, VideoCodec,
};
use roammand_protocol::roammand::v1::SessionPermission;

#[test]
fn configures_codecs_ice_and_exact_data_channels() {
    let direct = SessionConfig::new(IceTransportPolicy::All);
    assert_eq!(
        direct.codec_preferences(),
        &[VideoCodec::H264, VideoCodec::Vp8]
    );
    assert_eq!(direct.ice_transport_policy(), IceTransportPolicy::All);
    assert_eq!(direct.data_channels()[0].label, DATA_CHANNEL_INPUT_RELIABLE);
    assert_eq!(
        direct.data_channels()[0].reliability,
        DataChannelReliability::OrderedReliable
    );
    assert_eq!(direct.data_channels()[1].label, DATA_CHANNEL_POINTER_FAST);
    assert_eq!(
        direct.data_channels()[1].reliability,
        DataChannelReliability::UnorderedNoRetransmits
    );
    assert_eq!(
        SessionConfig::new(IceTransportPolicy::Relay).ice_transport_policy(),
        IceTransportPolicy::Relay
    );
}

#[test]
fn negotiates_and_closes_in_a_deterministic_order() {
    let operations = Arc::new(Mutex::new(Vec::<&'static str>::new()));
    let mut session = HostPeerSession::new(
        vec![0x71; 16],
        &[
            SessionPermission::ViewScreen,
            SessionPermission::ControlInput,
        ],
        SessionConfig::new(IceTransportPolicy::All),
        Box::new(FakePeer::new(Arc::clone(&operations))),
        Box::new(FakeInput::new(Arc::clone(&operations))),
    )
    .expect("session inputs must be valid");

    assert_eq!(session.state(), HostSessionState::New);
    let answer = session
        .accept_offer("v=0\r\n")
        .expect("offer must negotiate");
    assert_eq!(answer.sdp, "v=0\r\nanswer\r\n");
    assert_eq!(answer.dtls_fingerprint_sha256, vec![0x41; 32]);
    assert_eq!(session.state(), HostSessionState::Negotiating);
    session.mark_connected().expect("session must connect");
    assert_eq!(session.state(), HostSessionState::Connected);
    session.close().expect("session must close");
    session.close().expect("repeated close must be idempotent");
    assert_eq!(session.state(), HostSessionState::Closed);
    assert_eq!(
        *operations.lock().expect("operations lock"),
        vec!["peer-start", "input-release-all", "peer-close"]
    );
}

#[test]
fn failed_peer_start_closes_every_partially_created_resource() {
    let operations = Arc::new(Mutex::new(Vec::<&'static str>::new()));
    let mut session = HostPeerSession::new(
        vec![0x71; 16],
        &[SessionPermission::ViewScreen],
        SessionConfig::new(IceTransportPolicy::All),
        Box::new(FailingStartPeer::new(Arc::clone(&operations))),
        Box::new(FakeInput::new(Arc::clone(&operations))),
    )
    .expect("session inputs must be valid");

    assert_eq!(
        session.accept_offer("v=0\r\n"),
        Err(roammand_host_webrtc::HostWebRtcError::PeerFailure)
    );
    assert_eq!(session.state(), HostSessionState::Closed);
    assert_eq!(
        *operations.lock().expect("operations lock"),
        vec!["peer-start", "input-release-all", "peer-close"]
    );
}

#[test]
fn closed_session_retries_failed_input_cleanup_on_close_or_drop() {
    for retry_on_drop in [false, true] {
        let operations = Arc::new(Mutex::new(Vec::<&'static str>::new()));
        let mut input = FakeInput::new(Arc::clone(&operations));
        input.fail_release_once = true;
        let mut session = HostPeerSession::new(
            vec![0x71; 16],
            &[
                SessionPermission::ViewScreen,
                SessionPermission::ControlInput,
            ],
            SessionConfig::new(IceTransportPolicy::All),
            Box::new(FakePeer::new(Arc::clone(&operations))),
            Box::new(input),
        )
        .expect("session inputs must be valid");
        session
            .accept_offer("v=0\r\n")
            .expect("offer must negotiate");
        session.mark_connected().expect("session must connect");

        assert_eq!(session.close(), Err(HostWebRtcError::InputFailure));
        assert_eq!(session.state(), HostSessionState::Closed);
        assert!(session.mark_connected().is_err());
        if !retry_on_drop {
            session.close().expect("failed input cleanup must retry");
            session
                .close()
                .expect("successful cleanup must be idempotent");
        }
        drop(session);
        assert_eq!(
            *operations.lock().expect("operations lock"),
            vec![
                "peer-start",
                "input-release-all",
                "peer-close",
                "input-release-all"
            ],
            "retry_on_drop={retry_on_drop}"
        );
    }
}

#[test]
fn admits_only_one_inbound_session() {
    let mut gate = SessionGate::new();
    let first = vec![0x71; 16];
    let second = vec![0x72; 16];
    let lease = gate.acquire(&first).expect("first session must acquire");
    assert!(gate.acquire(&second).is_err());
    gate.release(&lease).expect("matching lease must release");
    assert!(gate.acquire(&second).is_ok());
}

#[test]
fn forwards_remote_ice_only_after_offer_authentication_and_negotiation() {
    let operations = Arc::new(Mutex::new(Vec::<&'static str>::new()));
    let mut session = HostPeerSession::new(
        vec![0x71; 16],
        &[SessionPermission::ViewScreen],
        SessionConfig::new(IceTransportPolicy::All),
        Box::new(FakePeer::new(Arc::clone(&operations))),
        Box::new(FakeInput::new(Arc::clone(&operations))),
    )
    .expect("session inputs must be valid");
    let candidate = PeerIceCandidate {
        candidate: "candidate:1 1 udp 1 127.0.0.1 9000 typ host".to_owned(),
        sdp_mid: "0".to_owned(),
        sdp_m_line_index: 0,
    };

    assert!(session.add_remote_ice_candidate(&candidate).is_err());
    session
        .accept_offer("v=0\r\n")
        .expect("offer must negotiate");
    session
        .add_remote_ice_candidate(&candidate)
        .expect("candidate must be forwarded");
    assert_eq!(
        *operations.lock().expect("operations lock"),
        vec!["peer-start", "peer-candidate"]
    );
}

#[test]
fn reconnect_releases_input_and_reuses_the_existing_peer() {
    let operations = Arc::new(Mutex::new(Vec::<&'static str>::new()));
    let mut session = HostPeerSession::new(
        vec![0x71; 16],
        &[
            SessionPermission::ViewScreen,
            SessionPermission::ControlInput,
        ],
        SessionConfig::new(IceTransportPolicy::All),
        Box::new(FakePeer::new(Arc::clone(&operations))),
        Box::new(FakeInput::new(Arc::clone(&operations))),
    )
    .expect("session inputs must be valid");
    session
        .accept_offer("v=0\r\n")
        .expect("initial offer must negotiate");
    session.mark_connected().expect("session must connect");

    session
        .begin_reconnect()
        .expect("reconnect must release input");
    assert_eq!(session.state(), HostSessionState::Reconnecting);
    let answer = session
        .accept_reconnect_offer("v=0\r\nrestart\r\n")
        .expect("restart offer must negotiate on the same peer");
    assert_eq!(answer.sdp, "v=0\r\nrestart-answer\r\n");
    assert_eq!(session.state(), HostSessionState::Negotiating);
    session.mark_connected().expect("restart must connect");

    assert_eq!(
        *operations.lock().expect("operations lock"),
        vec!["peer-start", "input-release-all", "peer-restart"]
    );
    session.close().expect("session must close");
}

#[test]
fn reconnect_accepts_spontaneous_and_duplicate_connected_events() {
    let operations = Arc::new(Mutex::new(Vec::<&'static str>::new()));
    let mut session = HostPeerSession::new(
        vec![0x72; 16],
        &[SessionPermission::ViewScreen],
        SessionConfig::new(IceTransportPolicy::All),
        Box::new(FakePeer::new(Arc::clone(&operations))),
        Box::new(FakeInput::new(Arc::clone(&operations))),
    )
    .expect("session inputs must be valid");
    session
        .accept_offer("v=0\r\n")
        .expect("initial offer must negotiate");
    session.mark_connected().expect("session must connect");
    session
        .mark_connected()
        .expect("duplicate connected callbacks must be idempotent");

    session
        .begin_reconnect()
        .expect("disconnect must enter reconnect");
    session
        .mark_connected()
        .expect("the existing ICE path may recover before a restart offer");

    assert_eq!(session.state(), HostSessionState::Connected);
    session.close().expect("session must close");
}

struct FakePeer {
    operations: Arc<Mutex<Vec<&'static str>>>,
}

impl FakePeer {
    fn new(operations: Arc<Mutex<Vec<&'static str>>>) -> Self {
        Self { operations }
    }
}

impl PeerBackend for FakePeer {
    fn start(
        &mut self,
        _config: &SessionConfig,
        _offer_sdp: &str,
    ) -> Result<PeerAnswer, roammand_host_webrtc::HostWebRtcError> {
        self.operations
            .lock()
            .expect("operations lock")
            .push("peer-start");
        Ok(PeerAnswer {
            sdp: "v=0\r\nanswer\r\n".to_owned(),
            dtls_fingerprint_sha256: vec![0x41; 32],
        })
    }

    fn restart(
        &mut self,
        _config: &SessionConfig,
        _offer_sdp: &str,
    ) -> Result<PeerAnswer, roammand_host_webrtc::HostWebRtcError> {
        self.operations
            .lock()
            .expect("operations lock")
            .push("peer-restart");
        Ok(PeerAnswer {
            sdp: "v=0\r\nrestart-answer\r\n".to_owned(),
            dtls_fingerprint_sha256: vec![0x42; 32],
        })
    }

    fn close(&mut self) -> Result<(), roammand_host_webrtc::HostWebRtcError> {
        self.operations
            .lock()
            .expect("operations lock")
            .push("peer-close");
        Ok(())
    }

    fn add_remote_ice_candidate(
        &mut self,
        _candidate: &PeerIceCandidate,
    ) -> Result<(), roammand_host_webrtc::HostWebRtcError> {
        self.operations
            .lock()
            .expect("operations lock")
            .push("peer-candidate");
        Ok(())
    }
}

struct FakeInput {
    operations: Arc<Mutex<Vec<&'static str>>>,
    fail_release_once: bool,
}

struct FailingStartPeer {
    operations: Arc<Mutex<Vec<&'static str>>>,
}

impl FailingStartPeer {
    fn new(operations: Arc<Mutex<Vec<&'static str>>>) -> Self {
        Self { operations }
    }
}

impl PeerBackend for FailingStartPeer {
    fn start(
        &mut self,
        _config: &SessionConfig,
        _offer_sdp: &str,
    ) -> Result<PeerAnswer, roammand_host_webrtc::HostWebRtcError> {
        self.operations
            .lock()
            .expect("operations lock")
            .push("peer-start");
        Err(roammand_host_webrtc::HostWebRtcError::PeerFailure)
    }

    fn close(&mut self) -> Result<(), roammand_host_webrtc::HostWebRtcError> {
        self.operations
            .lock()
            .expect("operations lock")
            .push("peer-close");
        Ok(())
    }
}

impl FakeInput {
    fn new(operations: Arc<Mutex<Vec<&'static str>>>) -> Self {
        Self {
            operations,
            fail_release_once: false,
        }
    }
}

impl RemoteInputSink for FakeInput {
    fn release_all(&mut self) -> Result<(), roammand_host_webrtc::HostWebRtcError> {
        self.operations
            .lock()
            .expect("operations lock")
            .push("input-release-all");
        if self.fail_release_once {
            self.fail_release_once = false;
            return Err(HostWebRtcError::InputFailure);
        }
        Ok(())
    }
}
