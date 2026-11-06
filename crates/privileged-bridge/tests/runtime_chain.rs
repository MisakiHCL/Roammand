// SPDX-License-Identifier: MPL-2.0

#![cfg(unix)]

use std::{
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};

use roammand_host_webrtc::{
    IceTransportPolicy, PeerAnswer, PeerBackend, RemoteInputSink, SessionConfig,
};
use roammand_ipc::IpcToken;
use roammand_privileged_bridge::{
    client::{AuthenticatedBridgeConnector, BridgePeerOptions, RpcProxyPartsFactory},
    helper::{HelperBackend, HelperProtocolError},
    installed::installed_file_sha256,
    proxy::{ProxyEvent, ProxyPartsFactory, ProxySessionContext},
    runtime::{BrokerRuntimeConfig, HelperClientConfig, run_unix_broker, run_unix_helper},
    unix_runtime::UnixBridgeTransportConnector,
};
use roammand_protocol::roammand::v1::{
    DevicePlatform, IceCandidate, InteractiveDesktopKind, PrivilegedInputCommand,
    PrivilegedPeerConfiguration, PrivilegedSessionDescriptor, SessionPermission,
    WebRtcSessionDescription,
};
use tempfile::TempDir;

const TOKEN: [u8; 32] = [0x11; 32];
const OFFER_SDP: &str = concat!(
    "v=0\r\n",
    "a=fingerprint:sha-256 ",
    "41:41:41:41:41:41:41:41:41:41:41:41:41:41:41:41:",
    "41:41:41:41:41:41:41:41:41:41:41:41:41:41:41:41\r\n"
);

struct RecordingBackend(Arc<Mutex<Vec<&'static str>>>);

impl HelperBackend for RecordingBackend {
    fn start(
        &mut self,
        _configuration: &PrivilegedPeerConfiguration,
        _offer: &WebRtcSessionDescription,
        _controller_display_name: &str,
    ) -> Result<PeerAnswer, HelperProtocolError> {
        self.0.lock().expect("operations").push("start");
        Ok(PeerAnswer {
            sdp: "answer".to_owned(),
            dtls_fingerprint_sha256: vec![0x51; 32],
        })
    }

    fn restart(
        &mut self,
        configuration: &PrivilegedPeerConfiguration,
        offer: &WebRtcSessionDescription,
        controller_display_name: &str,
    ) -> Result<PeerAnswer, HelperProtocolError> {
        self.start(configuration, offer, controller_display_name)
    }

    fn add_candidate(&mut self, _candidate: &IceCandidate) -> Result<(), HelperProtocolError> {
        Ok(())
    }

    fn input(&mut self, _input: &PrivilegedInputCommand) -> Result<(), HelperProtocolError> {
        self.0.lock().expect("operations").push("input");
        Ok(())
    }

    fn secure_attention(&mut self) -> Result<(), HelperProtocolError> {
        Err(HelperProtocolError::Backend)
    }

    fn close(&mut self) -> Result<(), HelperProtocolError> {
        self.0.lock().expect("operations").push("close");
        Ok(())
    }

    fn try_event(&mut self) -> Result<Option<ProxyEvent>, HelperProtocolError> {
        Ok(None)
    }

    fn fail_closed(&mut self) {
        self.0.lock().expect("operations").push("fail-closed");
    }
}

#[test]
fn host_broker_and_helper_exchange_real_framed_socket_messages() {
    verify_runtime_chain(false);
}

#[test]
fn unexpected_broker_disconnect_cleans_up_the_active_native_helper() {
    verify_runtime_chain(true);
}

fn verify_runtime_chain(disconnect_broker: bool) {
    let temporary = TempDir::new().expect("temp");
    let socket_path = temporary.path().join("bridge.sock");
    let executable_hash = installed_file_sha256(&std::env::current_exe().expect("current exe"))
        .expect("executable hash");
    let shutdown = Arc::new(AtomicBool::new(false));
    let broker_shutdown = Arc::clone(&shutdown);
    let broker_path = socket_path.clone();
    let broker = thread::spawn(move || {
        run_unix_broker(
            &broker_path,
            BrokerRuntimeConfig::new(TOKEN, [0x61; 16], executable_hash, executable_hash, 501)
                .expect("broker config"),
            broker_shutdown.as_ref(),
            Duration::from_millis(200),
        )
    });
    wait_for_path(&socket_path);

    let operations = Arc::new(Mutex::new(Vec::new()));
    let helper_operations = Arc::clone(&operations);
    let helper_shutdown = if disconnect_broker {
        Arc::new(AtomicBool::new(false))
    } else {
        Arc::clone(&shutdown)
    };
    let helper_path = socket_path.clone();
    let helper = thread::spawn(move || {
        run_unix_helper(
            &helper_path,
            HelperClientConfig::new(
                TOKEN,
                executable_hash,
                PrivilegedSessionDescriptor {
                    platform: DevicePlatform::Macos as i32,
                    os_session_id: 501,
                    desktop_kind: InteractiveDesktopKind::Normal as i32,
                    generation: 7,
                },
            )
            .expect("helper config"),
            Box::new(RecordingBackend(helper_operations)),
            helper_shutdown.as_ref(),
            Duration::from_millis(200),
        )
    });

    let context = ProxySessionContext::new(
        vec![0x71; 16],
        vec![
            SessionPermission::ViewScreen,
            SessionPermission::ControlInput,
        ],
        "Controller".to_owned(),
    )
    .expect("context");
    let transport =
        UnixBridgeTransportConnector::new(socket_path.clone(), Duration::from_millis(500))
            .expect("transport");
    let connector = AuthenticatedBridgeConnector::new(
        Box::new(transport),
        IpcToken::new(TOKEN),
        executable_hash,
        501,
    )
    .expect("connector");
    let mut connector = connector;
    let status = retry_probe(&mut connector);
    assert!(status.helper_connected);
    assert_eq!(status.interactive_session.expect("session").generation, 7);
    let mut factory = RpcProxyPartsFactory::new(
        Box::new(connector),
        BridgePeerOptions::new(Vec::new()).expect("options"),
    );
    let parts = retry_create(&mut factory, &context);
    let (mut peer, mut input, _, _) = parts.into_parts();

    assert_eq!(
        peer.start(&SessionConfig::new(IceTransportPolicy::All), OFFER_SDP)
            .expect("start")
            .sdp,
        "answer"
    );
    input.release_all().expect("input");
    if !disconnect_broker {
        peer.close().expect("close and release");
    }

    shutdown.store(true, Ordering::Relaxed);
    let helper_result = helper.join().expect("helper join");
    if disconnect_broker {
        assert!(helper_result.is_err());
    } else {
        assert!(helper_result.is_ok());
    }
    assert!(broker.join().expect("broker join").is_ok());
    let operations = operations.lock().expect("operations");
    assert!(operations.starts_with(&["start", "input"]));
    if !disconnect_broker {
        assert!(operations.contains(&"close"));
    }
    assert_eq!(operations.last(), Some(&"fail-closed"));
}

fn retry_probe(
    connector: &mut AuthenticatedBridgeConnector,
) -> roammand_protocol::roammand::v1::PrivilegedBridgeStatusSnapshot {
    for _ in 0..100 {
        if let Ok(status) = connector.probe_status() {
            return status;
        }
        thread::sleep(Duration::from_millis(10));
    }
    panic!("bridge route did not become ready for health probe");
}

fn wait_for_path(path: &Path) {
    for _ in 0..100 {
        if path.exists() {
            return;
        }
        thread::sleep(Duration::from_millis(10));
    }
    panic!("broker path was not created");
}

fn retry_create(
    factory: &mut RpcProxyPartsFactory,
    context: &ProxySessionContext,
) -> roammand_privileged_bridge::proxy::ProxyParts {
    let mut errors = Vec::new();
    for _ in 0..100 {
        match factory.create(&SessionConfig::new(IceTransportPolicy::All), context) {
            Ok(parts) => return parts,
            Err(error) => errors.push(error),
        }
        thread::sleep(Duration::from_millis(10));
    }
    panic!("bridge route did not become ready: {errors:?}");
}
