// SPDX-License-Identifier: MPL-2.0

use std::{
    fmt,
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use prost::Message;
use roammand_ipc::{AuthChannel, IpcToken, channel_client_proof, verify_channel_server_proof};
use roammand_protocol::{
    protocol_limits::{MINIMUM_PROTOCOL_MINOR_VERSION, PROTOCOL_MAJOR_VERSION},
    roammand::v1::{
        DevicePlatform, ErrorCode, InteractiveDesktopKind, PrivilegedBridgeAuthenticate,
        PrivilegedBridgeAuthenticated, PrivilegedBridgeChallenge, PrivilegedBridgeClientFrame,
        PrivilegedBridgeRole, PrivilegedBridgeServerFrame, PrivilegedBridgeState,
        PrivilegedBridgeStatusSnapshot, PrivilegedHelperRegistered, PrivilegedSessionDescriptor,
        ProtocolVersion, RegisterPrivilegedHelperRequest, UnifiedError,
        privileged_bridge_client_frame, privileged_bridge_server_frame,
    },
    validation::{
        decode_and_validate_privileged_bridge_client_frame,
        decode_and_validate_privileged_bridge_server_frame,
        validate_privileged_bridge_status_snapshot,
    },
};
use thiserror::Error;

use crate::{
    auth::{BridgeAuthenticator, BridgeRole, NonceReplayGuard},
    broker::{BrokerCore, BrokerHelper, BrokerProtocolError, HostBrokerSession},
    client::BridgeRpc,
    rpc::FramedBridgeRpc,
    session::{DesktopKind, Platform, RouteEvent, RouteSession},
    transport::{LocalBridgeTransport, TransportError},
};

#[cfg(any(unix, windows))]
use crate::helper::{HelperBackend, HelperProtocol};

#[cfg(windows)]
use crate::windows_runtime::{WindowsPipeListener, WindowsPipeTransport};

#[cfg(unix)]
use crate::unix_runtime::UnixStreamTransport;
#[cfg(unix)]
use std::{
    fs,
    io::ErrorKind,
    os::unix::{
        fs::{FileTypeExt, MetadataExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    },
    path::Path,
};

const REPLAY_CAPACITY: usize = 256;
const LOOP_INTERVAL: Duration = Duration::from_millis(5);
const CHALLENGE_REQUEST_ID: &str = "challenge-1";
const STATUS_REQUEST_ID: &str = "status-2";
const HELPER_REGISTER_REQUEST_ID: &str = "register-helper-2";

#[derive(Clone, Copy, Eq, PartialEq)]
pub struct BrokerRuntimeConfig {
    token: [u8; 32],
    instance_id: [u8; 16],
    host_executable_sha256: [u8; 32],
    helper_executable_sha256: [u8; 32],
    owner_os_session_id: u64,
}

impl BrokerRuntimeConfig {
    /// Creates a fixed installed-peer policy for one Host owner.
    ///
    /// # Errors
    ///
    /// Rejects zero secrets, identities, hashes, and OS sessions.
    pub fn new(
        token: [u8; 32],
        instance_id: [u8; 16],
        host_executable_sha256: [u8; 32],
        helper_executable_sha256: [u8; 32],
        owner_os_session_id: u64,
    ) -> Result<Self, RuntimeBridgeError> {
        if token == [0; 32]
            || instance_id == [0; 16]
            || host_executable_sha256 == [0; 32]
            || helper_executable_sha256 == [0; 32]
            || owner_os_session_id == 0
        {
            return Err(RuntimeBridgeError::Configuration);
        }
        Ok(Self {
            token,
            instance_id,
            host_executable_sha256,
            helper_executable_sha256,
            owner_os_session_id,
        })
    }
}

impl fmt::Debug for BrokerRuntimeConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("BrokerRuntimeConfig")
            .field("sensitive", &"[REDACTED]")
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Copy, PartialEq)]
pub struct HelperClientConfig {
    token: [u8; 32],
    executable_sha256: [u8; 32],
    session: PrivilegedSessionDescriptor,
}

impl HelperClientConfig {
    /// Creates a route-specific installed Helper configuration.
    ///
    /// # Errors
    ///
    /// Rejects zero secrets/hashes and invalid session descriptors.
    pub fn new(
        token: [u8; 32],
        executable_sha256: [u8; 32],
        session: PrivilegedSessionDescriptor,
    ) -> Result<Self, RuntimeBridgeError> {
        let status = ready_status(session);
        if token == [0; 32]
            || executable_sha256 == [0; 32]
            || validate_privileged_bridge_status_snapshot(&status).is_err()
        {
            return Err(RuntimeBridgeError::Configuration);
        }
        Ok(Self {
            token,
            executable_sha256,
            session,
        })
    }
}

impl fmt::Debug for HelperClientConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HelperClientConfig")
            .field("session", &"[REDACTED]")
            .field("sensitive", &"[REDACTED]")
            .finish()
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum RuntimeBridgeError {
    #[error("privileged runtime configuration is invalid")]
    Configuration,
    #[error("privileged runtime transport failed")]
    Transport,
    #[error("privileged runtime authentication failed")]
    Authentication,
    #[error("privileged runtime message failed validation")]
    InvalidMessage,
    #[error("privileged runtime route is unavailable")]
    RouteUnavailable,
    #[error("privileged runtime broker failed")]
    Broker,
    #[error("privileged runtime clock failed")]
    Clock,
}

struct AuthenticatedPeer {
    role: BridgeRole,
    os_session_id: u64,
}

struct RegisteredHelper {
    session: PrivilegedSessionDescriptor,
    transport: Box<dyn LocalBridgeTransport>,
}

struct TransportBrokerHelper {
    rpc: FramedBridgeRpc,
}

impl BrokerHelper for TransportBrokerHelper {
    fn exchange(
        &mut self,
        request: PrivilegedBridgeClientFrame,
    ) -> Result<PrivilegedBridgeServerFrame, BrokerProtocolError> {
        self.rpc
            .call(request)
            .map_err(|_| BrokerProtocolError::Helper)
    }

    fn try_event(&mut self) -> Result<Option<PrivilegedBridgeServerFrame>, BrokerProtocolError> {
        self.rpc
            .try_event()
            .map_err(|_| BrokerProtocolError::Helper)
    }

    fn fail_closed(&mut self) {
        self.rpc.fail_closed();
    }
}

/// Runs the macOS/Linux Unix-socket broker until shutdown.
///
/// # Errors
///
/// Returns a stable setup/runtime error; individual rejected peers are closed
/// and do not terminate the broker.
#[cfg(unix)]
pub fn run_unix_broker(
    socket_path: &Path,
    config: BrokerRuntimeConfig,
    shutdown: &AtomicBool,
    timeout: Duration,
) -> Result<(), RuntimeBridgeError> {
    if !socket_path.is_absolute() || timeout.is_zero() {
        return Err(RuntimeBridgeError::Configuration);
    }
    prepare_socket_path(socket_path, config.owner_os_session_id)?;
    let listener = UnixListener::bind(socket_path).map_err(|_| RuntimeBridgeError::Transport)?;
    fs::set_permissions(socket_path, fs::Permissions::from_mode(0o600))
        .map_err(|_| RuntimeBridgeError::Transport)?;
    assign_socket_owner(socket_path, config.owner_os_session_id)?;
    listener
        .set_nonblocking(true)
        .map_err(|_| RuntimeBridgeError::Transport)?;
    let mut replay =
        NonceReplayGuard::new(REPLAY_CAPACITY).map_err(|_| RuntimeBridgeError::Configuration)?;
    let mut helper: Option<RegisteredHelper> = None;
    while !shutdown.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _)) => {
                let mut transport = match UnixStreamTransport::new(stream, timeout) {
                    Ok(transport) => Box::new(transport) as Box<dyn LocalBridgeTransport>,
                    Err(_) => continue,
                };
                let Ok(peer) = authenticate_server(transport.as_mut(), &config, &mut replay) else {
                    transport.fail_closed();
                    continue;
                };
                match peer.role {
                    BridgeRole::SessionHelper => {
                        if let Ok(registered) = register_helper(transport, peer.os_session_id)
                            && let Some(mut previous) = helper.replace(registered)
                        {
                            previous.transport.fail_closed();
                        }
                    }
                    BridgeRole::HostAgent => {
                        if let Some(registered) = helper.take() {
                            if let Ok(Some(registered)) =
                                run_host_connection(transport, registered, &config, shutdown)
                            {
                                helper = Some(registered);
                            }
                        } else {
                            let unavailable = unavailable_status_frame();
                            let _ = send_server_frame(transport.as_mut(), &unavailable);
                            transport.fail_closed();
                        }
                    }
                }
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                thread::sleep(LOOP_INTERVAL);
            }
            Err(_) => {
                let _ = fs::remove_file(socket_path);
                return Err(RuntimeBridgeError::Transport);
            }
        }
    }
    if let Some(mut registered) = helper {
        registered.transport.fail_closed();
    }
    drop(listener);
    fs::remove_file(socket_path).map_err(|_| RuntimeBridgeError::Transport)
}

#[cfg(unix)]
fn prepare_socket_path(
    socket_path: &Path,
    owner_os_session_id: u64,
) -> Result<(), RuntimeBridgeError> {
    let parent = socket_path
        .parent()
        .ok_or(RuntimeBridgeError::Configuration)?;
    let parent_metadata =
        fs::symlink_metadata(parent).map_err(|_| RuntimeBridgeError::Transport)?;
    if !parent_metadata.is_dir()
        || parent_metadata.file_type().is_symlink()
        || parent_metadata.mode() & 0o022 != 0
    {
        return Err(RuntimeBridgeError::Transport);
    }
    let Ok(metadata) = fs::symlink_metadata(socket_path) else {
        return Ok(());
    };
    let effective_uid = u64::from(parent_metadata.uid());
    if !metadata.file_type().is_socket()
        || metadata.file_type().is_symlink()
        || (u64::from(metadata.uid()) != owner_os_session_id && metadata.uid() != 0)
        || (effective_uid != owner_os_session_id && parent_metadata.uid() != 0)
    {
        return Err(RuntimeBridgeError::Transport);
    }
    if UnixStream::connect(socket_path).is_ok() {
        return Err(RuntimeBridgeError::Transport);
    }
    fs::remove_file(socket_path).map_err(|_| RuntimeBridgeError::Transport)
}

#[cfg(target_os = "macos")]
fn assign_socket_owner(
    socket_path: &Path,
    owner_os_session_id: u64,
) -> Result<(), RuntimeBridgeError> {
    use nix::unistd::{Uid, chown};

    if !Uid::effective().is_root() {
        return Ok(());
    }
    let owner =
        u32::try_from(owner_os_session_id).map_err(|_| RuntimeBridgeError::Configuration)?;
    chown(socket_path, Some(Uid::from_raw(owner)), None).map_err(|_| RuntimeBridgeError::Transport)
}

// Keep one fallible call site for every Unix implementation; Linux is a no-op today.
#[cfg(all(unix, not(target_os = "macos")))]
#[allow(clippy::unnecessary_wraps)]
fn assign_socket_owner(
    _socket_path: &Path,
    _owner_os_session_id: u64,
) -> Result<(), RuntimeBridgeError> {
    Ok(())
}

/// Runs one Unix-socket Helper client until shutdown or broker disconnect.
///
/// # Errors
///
/// Returns a stable transport/authentication/protocol error.
#[cfg(unix)]
pub fn run_unix_helper(
    socket_path: &Path,
    config: HelperClientConfig,
    backend: Box<dyn HelperBackend>,
    shutdown: &AtomicBool,
    timeout: Duration,
) -> Result<(), RuntimeBridgeError> {
    let stream = UnixStream::connect(socket_path).map_err(|_| RuntimeBridgeError::Transport)?;
    let mut transport =
        UnixStreamTransport::new(stream, timeout).map_err(|_| RuntimeBridgeError::Transport)?;
    run_helper_transport(&mut transport, &config, backend, shutdown)
}

/// Runs the Windows named-pipe broker until shutdown.
///
/// # Errors
///
/// Returns a stable setup/runtime error; rejected local peers fail closed.
#[cfg(windows)]
pub fn run_windows_broker(
    owner_sid: String,
    config: BrokerRuntimeConfig,
    shutdown: &AtomicBool,
    timeout: Duration,
) -> Result<(), RuntimeBridgeError> {
    let mut listener = WindowsPipeListener::new(owner_sid, config.owner_os_session_id, timeout)
        .map_err(|_| RuntimeBridgeError::Transport)?;
    let mut replay =
        NonceReplayGuard::new(REPLAY_CAPACITY).map_err(|_| RuntimeBridgeError::Configuration)?;
    let mut helper: Option<RegisteredHelper> = None;
    while !shutdown.load(Ordering::Relaxed) {
        let Some(mut transport) = listener
            .try_accept()
            .map_err(|_| RuntimeBridgeError::Transport)?
        else {
            thread::sleep(LOOP_INTERVAL);
            continue;
        };
        let Ok(peer) = authenticate_server(transport.as_mut(), &config, &mut replay) else {
            transport.fail_closed();
            continue;
        };
        match peer.role {
            BridgeRole::SessionHelper => {
                if let Ok(registered) = register_helper(transport, peer.os_session_id)
                    && let Some(mut previous) = helper.replace(registered)
                {
                    previous.transport.fail_closed();
                }
            }
            BridgeRole::HostAgent => {
                if let Some(registered) = helper.take() {
                    if let Ok(Some(registered)) =
                        run_host_connection(transport, registered, &config, shutdown)
                    {
                        helper = Some(registered);
                    }
                } else {
                    let unavailable = unavailable_status_frame();
                    let _ = send_server_frame(transport.as_mut(), &unavailable);
                    transport.fail_closed();
                }
            }
        }
    }
    if let Some(mut registered) = helper {
        registered.transport.fail_closed();
    }
    Ok(())
}

/// Runs one Windows named-pipe Helper until shutdown or disconnect.
///
/// # Errors
///
/// Returns a stable transport/authentication/protocol error.
#[cfg(windows)]
pub fn run_windows_helper(
    config: HelperClientConfig,
    backend: Box<dyn HelperBackend>,
    shutdown: &AtomicBool,
    timeout: Duration,
) -> Result<(), RuntimeBridgeError> {
    let mut transport =
        WindowsPipeTransport::connect(timeout).map_err(|_| RuntimeBridgeError::Transport)?;
    run_helper_transport(&mut transport, &config, backend, shutdown)
}

#[cfg(any(unix, windows))]
fn run_helper_transport(
    transport: &mut dyn LocalBridgeTransport,
    config: &HelperClientConfig,
    backend: Box<dyn HelperBackend>,
    shutdown: &AtomicBool,
) -> Result<(), RuntimeBridgeError> {
    authenticate_helper(transport, config)?;
    let mut helper = HelperProtocol::new(backend);
    let result = (|| {
        while !shutdown.load(Ordering::Relaxed) {
            match transport.try_receive() {
                Ok(Some(encoded)) => {
                    let request = decode_and_validate_privileged_bridge_client_frame(&encoded)
                        .map_err(|_| RuntimeBridgeError::InvalidMessage)?;
                    let response = helper
                        .handle(&request)
                        .map_err(|_| RuntimeBridgeError::Broker)?;
                    send_server_frame(transport, &response)?;
                }
                Ok(None) => {}
                Err(TransportError::Disconnected) if shutdown.load(Ordering::Relaxed) => break,
                Err(_) => return Err(RuntimeBridgeError::Transport),
            }
            if let Some(event) = helper.try_event().map_err(|_| RuntimeBridgeError::Broker)? {
                send_server_frame(transport, &event)?;
            }
            thread::sleep(LOOP_INTERVAL);
        }
        Ok(())
    })();
    helper.shutdown();
    transport.fail_closed();
    result
}

fn authenticate_server(
    transport: &mut dyn LocalBridgeTransport,
    config: &BrokerRuntimeConfig,
    replay: &mut NonceReplayGuard,
) -> Result<AuthenticatedPeer, RuntimeBridgeError> {
    let mut server_nonce = [0_u8; 32];
    getrandom::fill(&mut server_nonce).map_err(|_| RuntimeBridgeError::Authentication)?;
    send_server_frame(
        transport,
        &PrivilegedBridgeServerFrame {
            protocol_version: Some(version()),
            request_id: CHALLENGE_REQUEST_ID.to_owned(),
            sequence: 1,
            payload: Some(privileged_bridge_server_frame::Payload::Challenge(
                PrivilegedBridgeChallenge {
                    broker_instance_id: config.instance_id.to_vec(),
                    server_nonce: server_nonce.to_vec(),
                },
            )),
        },
    )?;
    let request = receive_client_frame(transport)?;
    let Some(privileged_bridge_client_frame::Payload::Authenticate(authenticate)) =
        request.payload.as_ref()
    else {
        return Err(RuntimeBridgeError::Authentication);
    };
    let role = match PrivilegedBridgeRole::try_from(authenticate.role) {
        Ok(PrivilegedBridgeRole::HostAgent) => BridgeRole::HostAgent,
        Ok(PrivilegedBridgeRole::SessionHelper) => BridgeRole::SessionHelper,
        Ok(PrivilegedBridgeRole::Unspecified) | Err(_) => {
            return Err(RuntimeBridgeError::Authentication);
        }
    };
    let expected_hash = match role {
        BridgeRole::HostAgent => &config.host_executable_sha256,
        BridgeRole::SessionHelper => &config.helper_executable_sha256,
    };
    if authenticate.executable_sha256.as_slice() != expected_hash
        || authenticate.os_session_id != config.owner_os_session_id
    {
        return Err(RuntimeBridgeError::Authentication);
    }
    if let Some(peer) = transport.peer_identity()
        && (peer.process_id == 0
            || (peer.os_session_id != 0 && peer.os_session_id != authenticate.os_session_id)
            || peer.executable_sha256 != *expected_hash)
    {
        return Err(RuntimeBridgeError::Authentication);
    }
    if let Some(uid) = transport.peer_identity().and_then(|peer| peer.unix_uid) {
        let owner = u32::try_from(config.owner_os_session_id)
            .map_err(|_| RuntimeBridgeError::Authentication)?;
        let principal_matches = match role {
            BridgeRole::HostAgent => uid == owner,
            BridgeRole::SessionHelper => matches!(uid, 0) || uid == owner,
        };
        if !principal_matches {
            return Err(RuntimeBridgeError::Authentication);
        }
    }
    let mut authenticator = BridgeAuthenticator::new(
        role,
        IpcToken::new(config.token),
        config.instance_id,
        server_nonce,
    );
    let proof = authenticator
        .authenticate(
            &authenticate.client_nonce,
            &authenticate.client_proof,
            replay,
        )
        .map_err(|_| RuntimeBridgeError::Authentication)?;
    send_server_frame(
        transport,
        &PrivilegedBridgeServerFrame {
            protocol_version: Some(version()),
            request_id: request.request_id,
            sequence: request.sequence,
            payload: Some(privileged_bridge_server_frame::Payload::Authenticated(
                PrivilegedBridgeAuthenticated {
                    server_proof: proof.to_vec(),
                },
            )),
        },
    )?;
    Ok(AuthenticatedPeer {
        role,
        os_session_id: authenticate.os_session_id,
    })
}

fn register_helper(
    mut transport: Box<dyn LocalBridgeTransport>,
    os_session_id: u64,
) -> Result<RegisteredHelper, RuntimeBridgeError> {
    let request = receive_client_frame(transport.as_mut())?;
    let Some(privileged_bridge_client_frame::Payload::RegisterHelper(register)) =
        request.payload.as_ref()
    else {
        return Err(RuntimeBridgeError::InvalidMessage);
    };
    let session = register.session.ok_or(RuntimeBridgeError::InvalidMessage)?;
    if session.os_session_id != os_session_id
        || validate_privileged_bridge_status_snapshot(&ready_status(session)).is_err()
    {
        return Err(RuntimeBridgeError::InvalidMessage);
    }
    send_server_frame(
        transport.as_mut(),
        &PrivilegedBridgeServerFrame {
            protocol_version: Some(version()),
            request_id: request.request_id,
            sequence: request.sequence,
            payload: Some(privileged_bridge_server_frame::Payload::HelperRegistered(
                PrivilegedHelperRegistered {
                    session: Some(session),
                },
            )),
        },
    )?;
    Ok(RegisteredHelper { session, transport })
}

fn run_host_connection(
    mut host: Box<dyn LocalBridgeTransport>,
    registered: RegisteredHelper,
    config: &BrokerRuntimeConfig,
    shutdown: &AtomicBool,
) -> Result<Option<RegisteredHelper>, RuntimeBridgeError> {
    let ready = status_frame(ready_status(registered.session));
    if send_server_frame(host.as_mut(), &ready).is_err() {
        host.fail_closed();
        return Ok(Some(registered));
    }
    let request = loop {
        if shutdown.load(Ordering::Relaxed) {
            host.fail_closed();
            return Ok(Some(registered));
        }
        match host.try_receive() {
            Ok(Some(encoded)) => {
                let request = decode_and_validate_privileged_bridge_client_frame(&encoded)
                    .map_err(|_| RuntimeBridgeError::InvalidMessage)?;
                if !matches!(
                    request.payload,
                    Some(privileged_bridge_client_frame::Payload::AcquireLease(_))
                ) {
                    let error = error_frame(&request);
                    send_server_frame(host.as_mut(), &error)?;
                    host.fail_closed();
                    return Ok(Some(registered));
                }
                break request;
            }
            Ok(None) => thread::sleep(LOOP_INTERVAL),
            Err(_) => {
                host.fail_closed();
                return Ok(Some(registered));
            }
        }
    };
    let route = route_session(&registered.session)?;
    let mut broker = BrokerCore::new(config.instance_id);
    broker
        .observe_route(RouteEvent::SessionAvailable(route))
        .map_err(|_| RuntimeBridgeError::Broker)?;
    broker
        .connect_host(route.generation)
        .map_err(|_| RuntimeBridgeError::Broker)?;
    let helper = TransportBrokerHelper {
        rpc: FramedBridgeRpc::new(registered.transport),
    };
    let secure_attention = matches!(
        route,
        RouteSession {
            platform: Platform::Windows,
            desktop: DesktopKind::LockedLogin | DesktopKind::Secure,
            ..
        }
    );
    let mut session =
        HostBrokerSession::new(broker, Box::new(helper)).with_secure_attention(secure_attention);
    if let Ok(response) = session.handle(request.clone(), now_unix_ms()?) {
        send_server_frame(host.as_mut(), &response)?;
    } else {
        let error = error_frame(&request);
        send_server_frame(host.as_mut(), &error)?;
        session.fail_closed();
        host.fail_closed();
        return Ok(None);
    }
    while !shutdown.load(Ordering::Relaxed) {
        match host.try_receive() {
            Ok(Some(encoded)) => {
                let request = decode_and_validate_privileged_bridge_client_frame(&encoded)
                    .map_err(|_| RuntimeBridgeError::InvalidMessage)?;
                if let Ok(response) = session.handle(request.clone(), now_unix_ms()?) {
                    send_server_frame(host.as_mut(), &response)?;
                } else {
                    let error = error_frame(&request);
                    send_server_frame(host.as_mut(), &error)?;
                    break;
                }
            }
            Ok(None) => {}
            Err(TransportError::Disconnected) => break,
            Err(_) => return Err(RuntimeBridgeError::Transport),
        }
        if session.expire(now_unix_ms()?) {
            break;
        }
        if let Some(event) = session
            .try_event()
            .map_err(|_| RuntimeBridgeError::Broker)?
        {
            send_server_frame(host.as_mut(), &event)?;
        }
        thread::sleep(LOOP_INTERVAL);
    }
    session.fail_closed();
    host.fail_closed();
    Ok(None)
}

fn authenticate_helper(
    transport: &mut dyn LocalBridgeTransport,
    config: &HelperClientConfig,
) -> Result<(), RuntimeBridgeError> {
    let challenge = receive_server_frame(transport)?;
    let Some(privileged_bridge_server_frame::Payload::Challenge(challenge)) = challenge.payload
    else {
        return Err(RuntimeBridgeError::Authentication);
    };
    let instance_id: [u8; 16] = challenge
        .broker_instance_id
        .try_into()
        .map_err(|_| RuntimeBridgeError::Authentication)?;
    let server_nonce: [u8; 32] = challenge
        .server_nonce
        .try_into()
        .map_err(|_| RuntimeBridgeError::Authentication)?;
    let mut client_nonce = [0_u8; 32];
    getrandom::fill(&mut client_nonce).map_err(|_| RuntimeBridgeError::Authentication)?;
    let token = IpcToken::new(config.token);
    let client_proof = channel_client_proof(
        &token,
        AuthChannel::PrivilegedHelper,
        &instance_id,
        &server_nonce,
        &client_nonce,
    );
    let auth_request = PrivilegedBridgeClientFrame {
        protocol_version: Some(version()),
        request_id: "authenticate-helper-1".to_owned(),
        sequence: 1,
        payload: Some(privileged_bridge_client_frame::Payload::Authenticate(
            PrivilegedBridgeAuthenticate {
                role: PrivilegedBridgeRole::SessionHelper as i32,
                client_nonce: client_nonce.to_vec(),
                client_proof: client_proof.to_vec(),
                executable_sha256: config.executable_sha256.to_vec(),
                os_session_id: config.session.os_session_id,
            },
        )),
    };
    send_client_frame(transport, &auth_request)?;
    let authenticated = receive_server_frame(transport)?;
    let server_proof = match authenticated.payload {
        Some(privileged_bridge_server_frame::Payload::Authenticated(value)) => value.server_proof,
        _ => return Err(RuntimeBridgeError::Authentication),
    };
    if authenticated.request_id != auth_request.request_id
        || authenticated.sequence != auth_request.sequence
        || !verify_channel_server_proof(
            &token,
            AuthChannel::PrivilegedHelper,
            &instance_id,
            &server_nonce,
            &client_nonce,
            &server_proof,
        )
    {
        return Err(RuntimeBridgeError::Authentication);
    }
    let register = PrivilegedBridgeClientFrame {
        protocol_version: Some(version()),
        request_id: HELPER_REGISTER_REQUEST_ID.to_owned(),
        sequence: 2,
        payload: Some(privileged_bridge_client_frame::Payload::RegisterHelper(
            RegisterPrivilegedHelperRequest {
                session: Some(config.session),
            },
        )),
    };
    send_client_frame(transport, &register)?;
    let registered = receive_server_frame(transport)?;
    if registered.request_id != register.request_id
        || registered.sequence != register.sequence
        || !matches!(
            registered.payload,
            Some(privileged_bridge_server_frame::Payload::HelperRegistered(_))
        )
    {
        return Err(RuntimeBridgeError::Authentication);
    }
    Ok(())
}

fn route_session(
    descriptor: &PrivilegedSessionDescriptor,
) -> Result<RouteSession, RuntimeBridgeError> {
    let platform = match DevicePlatform::try_from(descriptor.platform) {
        Ok(DevicePlatform::Windows) => Platform::Windows,
        Ok(DevicePlatform::Macos) => Platform::Macos,
        _ => return Err(RuntimeBridgeError::InvalidMessage),
    };
    let desktop = match InteractiveDesktopKind::try_from(descriptor.desktop_kind) {
        Ok(InteractiveDesktopKind::Normal) => DesktopKind::Normal,
        Ok(InteractiveDesktopKind::LockedLogin) => DesktopKind::LockedLogin,
        Ok(InteractiveDesktopKind::Secure) => DesktopKind::Secure,
        _ => return Err(RuntimeBridgeError::InvalidMessage),
    };
    Ok(RouteSession {
        platform,
        os_session_id: descriptor.os_session_id,
        desktop,
        generation: descriptor.generation,
    })
}

fn ready_status(session: PrivilegedSessionDescriptor) -> PrivilegedBridgeStatusSnapshot {
    PrivilegedBridgeStatusSnapshot {
        state: PrivilegedBridgeState::Ready as i32,
        interactive_session: Some(session),
        helper_connected: true,
        active_controller_display_name: String::new(),
        error: None,
    }
}

fn status_frame(status: PrivilegedBridgeStatusSnapshot) -> PrivilegedBridgeServerFrame {
    PrivilegedBridgeServerFrame {
        protocol_version: Some(version()),
        request_id: STATUS_REQUEST_ID.to_owned(),
        sequence: 2,
        payload: Some(privileged_bridge_server_frame::Payload::Status(status)),
    }
}

fn unavailable_status_frame() -> PrivilegedBridgeServerFrame {
    status_frame(PrivilegedBridgeStatusSnapshot {
        state: PrivilegedBridgeState::UserSessionOnly as i32,
        interactive_session: None,
        helper_connected: false,
        active_controller_display_name: String::new(),
        error: None,
    })
}

fn error_frame(request: &PrivilegedBridgeClientFrame) -> PrivilegedBridgeServerFrame {
    PrivilegedBridgeServerFrame {
        protocol_version: Some(version()),
        request_id: request.request_id.clone(),
        sequence: request.sequence,
        payload: Some(privileged_bridge_server_frame::Payload::Error(
            UnifiedError {
                code: ErrorCode::InvalidRequest as i32,
                message_key: "privileged_bridge_rejected".to_owned(),
                retryable: false,
                request_id: request.request_id.clone(),
                details: None,
            },
        )),
    }
}

fn receive_client_frame(
    transport: &mut dyn LocalBridgeTransport,
) -> Result<PrivilegedBridgeClientFrame, RuntimeBridgeError> {
    let encoded = transport
        .receive()
        .map_err(|_| RuntimeBridgeError::Transport)?;
    decode_and_validate_privileged_bridge_client_frame(&encoded)
        .map_err(|_| RuntimeBridgeError::InvalidMessage)
}

fn receive_server_frame(
    transport: &mut dyn LocalBridgeTransport,
) -> Result<PrivilegedBridgeServerFrame, RuntimeBridgeError> {
    let encoded = transport
        .receive()
        .map_err(|_| RuntimeBridgeError::Transport)?;
    decode_and_validate_privileged_bridge_server_frame(&encoded)
        .map_err(|_| RuntimeBridgeError::InvalidMessage)
}

fn send_client_frame(
    transport: &mut dyn LocalBridgeTransport,
    frame: &PrivilegedBridgeClientFrame,
) -> Result<(), RuntimeBridgeError> {
    transport
        .send(&frame.encode_to_vec())
        .map_err(|_| RuntimeBridgeError::Transport)
}

fn send_server_frame(
    transport: &mut dyn LocalBridgeTransport,
    frame: &PrivilegedBridgeServerFrame,
) -> Result<(), RuntimeBridgeError> {
    transport
        .send(&frame.encode_to_vec())
        .map_err(|_| RuntimeBridgeError::Transport)
}

fn now_unix_ms() -> Result<u64, RuntimeBridgeError> {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| RuntimeBridgeError::Clock)?;
    u64::try_from(elapsed.as_millis()).map_err(|_| RuntimeBridgeError::Clock)
}

const fn version() -> ProtocolVersion {
    ProtocolVersion {
        major: PROTOCOL_MAJOR_VERSION,
        minor: MINIMUM_PROTOCOL_MINOR_VERSION,
    }
}
