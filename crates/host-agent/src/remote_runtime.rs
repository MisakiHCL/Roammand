// SPDX-License-Identifier: MPL-2.0

use std::{fmt, future::Future, path::PathBuf, sync::Arc, time::Duration};

#[cfg(any(target_os = "macos", windows))]
use std::env;

use roammand_host_webrtc::IceTransportPolicy;
use roammand_ipc::IpcToken;
use roammand_privileged_bridge::client::{
    AuthenticatedBridgeConnector, BridgeIceServer, BridgePeerOptions, RpcProxyPartsFactory,
};
use roammand_privileged_bridge::installed::{InstalledBridgeConfig, installed_file_sha256};
use roammand_privileged_bridge::proxy::ProxyError;
use tokio::{
    sync::{broadcast, watch},
    time::{MissedTickBehavior, interval, sleep, timeout},
};
use url::Url;

#[cfg(feature = "native-webrtc")]
use crate::NativeRemoteSessionFactory;
use crate::{
    BridgeRemoteSessionFactory, HostService, PairingOutbound, RemoteSessionCoordinator,
    RemoteSessionError, RemoteSessionOutbound, RuntimeError, SignalingEvent, SignalingProtocol,
    WebSocketSignalingTransport, runtime::now_unix_ms,
};

#[cfg(any(target_os = "macos", windows))]
use crate::AgentRuntimeConfig;

#[cfg(unix)]
use roammand_privileged_bridge::unix_runtime::UnixBridgeTransportConnector;
#[cfg(windows)]
use roammand_privileged_bridge::windows_runtime::WindowsBridgeTransportConnector;

#[cfg(any(target_os = "macos", windows))]
const SIGNALING_ENDPOINT_ENV: &str = "ROAMMAND_SIGNALING_ENDPOINT";
#[cfg(any(target_os = "macos", windows))]
const ICE_TRANSPORT_POLICY_ENV: &str = "ROAMMAND_ICE_TRANSPORT_POLICY";
#[cfg(any(target_os = "macos", windows))]
const STUN_URLS_ENV: &str = "ROAMMAND_STUN_URLS";
#[cfg(any(target_os = "macos", windows))]
const TURN_URLS_ENV: &str = "ROAMMAND_TURN_URLS";
#[cfg(any(target_os = "macos", windows))]
const TURN_USERNAME_ENV: &str = "ROAMMAND_TURN_USERNAME";
#[cfg(any(target_os = "macos", windows))]
const TURN_PASSWORD_ENV: &str = "ROAMMAND_TURN_PASSWORD";
const MAX_ICE_SERVERS: usize = 8;
const MAX_ICE_URLS_PER_SERVER: usize = 16;
const MAX_ICE_URL_UTF8_BYTES: usize = 2_048;
const MAX_ICE_CREDENTIAL_UTF8_BYTES: usize = 256;
const SIGNALING_RECONNECT_BASE_MS: u64 = 2_000;
const SIGNALING_RECONNECT_MAX_MS: u64 = 30_000;
const SIGNALING_STABLE_INTERVAL: Duration = Duration::from_secs(30);
const SIGNALING_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(15);
const PEER_EVENT_POLL_INTERVAL: Duration = Duration::from_millis(10);
const REMOTE_OPERATION_TIMEOUT: Duration = Duration::from_secs(5);
const BRIDGE_IO_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Eq, PartialEq)]
pub struct PrivilegedBridgeRuntimeConfig {
    endpoint: PathBuf,
    token: [u8; 32],
    executable_sha256: [u8; 32],
    os_session_id: u64,
}

impl PrivilegedBridgeRuntimeConfig {
    /// Creates one required installed-bridge client configuration.
    ///
    /// # Errors
    ///
    /// Rejects relative endpoints and missing installed identity values.
    pub fn new(
        endpoint: PathBuf,
        token: [u8; 32],
        executable_sha256: [u8; 32],
        os_session_id: u64,
    ) -> Result<Self, RuntimeError> {
        if !endpoint.is_absolute()
            || token == [0; 32]
            || executable_sha256 == [0; 32]
            || os_session_id == 0
        {
            return Err(RuntimeError::RemoteConfiguration);
        }
        Ok(Self {
            endpoint,
            token,
            executable_sha256,
            os_session_id,
        })
    }

    /// Loads and validates installed client identity material without exposing
    /// it through diagnostics.
    ///
    /// # Errors
    ///
    /// Rejects malformed installed data, endpoint, or executable evidence.
    pub fn load_installed(
        endpoint: PathBuf,
        secret_path: &std::path::Path,
        owner_path: &std::path::Path,
        executable_path: &std::path::Path,
    ) -> Result<Self, RuntimeError> {
        let installed = InstalledBridgeConfig::load(secret_path, owner_path)
            .map_err(|_| RuntimeError::PrivilegedBridgeUnavailable)?;
        let executable_sha256 = installed_file_sha256(executable_path)
            .map_err(|_| RuntimeError::PrivilegedBridgeUnavailable)?;
        Self::new(
            endpoint,
            installed.token(),
            executable_sha256,
            installed.owner_os_session_id(),
        )
    }
}

impl fmt::Debug for PrivilegedBridgeRuntimeConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("PrivilegedBridgeRuntimeConfig([REDACTED])")
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct RemoteIceServerConfig {
    urls: Vec<String>,
    username: String,
    password: String,
}

impl RemoteIceServerConfig {
    /// Creates one bounded STUN or TURN server configuration.
    ///
    /// # Errors
    ///
    /// Returns a configuration error for missing, malformed, mixed, or
    /// over-limit URLs, STUN credentials, or TURN without credentials.
    pub fn new(
        urls: Vec<String>,
        username: String,
        password: String,
    ) -> Result<Self, RuntimeError> {
        let all_stun = urls.iter().all(|value| valid_stun_url(value));
        let all_turn = urls.iter().all(|value| valid_turn_url(value));
        let valid_credentials = if all_stun {
            username.is_empty() && password.is_empty()
        } else if all_turn {
            !username.is_empty() && !password.is_empty()
        } else {
            false
        };
        if urls.is_empty()
            || urls.len() > MAX_ICE_URLS_PER_SERVER
            || username.len() > MAX_ICE_CREDENTIAL_UTF8_BYTES
            || password.len() > MAX_ICE_CREDENTIAL_UTF8_BYTES
            || !valid_credentials
        {
            return Err(RuntimeError::RemoteConfiguration);
        }
        Ok(Self {
            urls,
            username,
            password,
        })
    }

    fn provides_turn(&self) -> bool {
        self.urls.iter().all(|value| valid_turn_url(value))
    }
}

impl fmt::Debug for RemoteIceServerConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RemoteIceServerConfig")
            .field("url_count", &self.urls.len())
            .field("has_username", &!self.username.is_empty())
            .field("has_password", &!self.password.is_empty())
            .finish()
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct RemoteRuntimeConfig {
    endpoint: String,
    ice_transport_policy: IceTransportPolicy,
    ice_servers: Vec<RemoteIceServerConfig>,
}

impl RemoteRuntimeConfig {
    /// Creates an explicit, bounded signaling and ICE runtime configuration.
    ///
    /// # Errors
    ///
    /// Returns a configuration error for endpoint policy violations, too many
    /// ICE servers, or relay-only mode without TURN.
    pub fn new(
        endpoint: String,
        ice_transport_policy: IceTransportPolicy,
        ice_servers: Vec<RemoteIceServerConfig>,
    ) -> Result<Self, RuntimeError> {
        crate::validate_signaling_endpoint(&endpoint)
            .map_err(|_| RuntimeError::RemoteConfiguration)?;
        if ice_servers.len() > MAX_ICE_SERVERS
            || (ice_transport_policy == IceTransportPolicy::Relay
                && !ice_servers.iter().any(RemoteIceServerConfig::provides_turn))
        {
            return Err(RuntimeError::RemoteConfiguration);
        }
        Ok(Self {
            endpoint,
            ice_transport_policy,
            ice_servers,
        })
    }
}

impl fmt::Debug for RemoteRuntimeConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RemoteRuntimeConfig")
            .field("ice_transport_policy", &self.ice_transport_policy)
            .field("ice_server_count", &self.ice_servers.len())
            .finish_non_exhaustive()
    }
}

pub(crate) struct PreparedRemote {
    config: RemoteRuntimeConfig,
    coordinator: RemoteSessionCoordinator,
    service: Arc<HostService>,
}

pub(crate) fn prepare_remote(
    config: Option<&RemoteRuntimeConfig>,
    privileged_bridge: Option<&PrivilegedBridgeRuntimeConfig>,
    service: Arc<HostService>,
) -> Result<Option<PreparedRemote>, RuntimeError> {
    if let Some(privileged_bridge) = privileged_bridge {
        return prepare_bridge_remote(config, privileged_bridge, service);
    }
    let Some(config) = config else {
        return Ok(None);
    };
    prepare_native_remote(config, service)
}

#[cfg(feature = "native-webrtc")]
fn prepare_native_remote(
    config: &RemoteRuntimeConfig,
    service: Arc<HostService>,
) -> Result<Option<PreparedRemote>, RuntimeError> {
    #[cfg(target_os = "macos")]
    if !roammand_host_platform::macos_desktop_permission_status(false, false).ready() {
        return Err(RuntimeError::DesktopPermissionsRequired);
    }
    let options = roammand_host_webrtc::native::NativePeerOptions {
        ice_servers: config
            .ice_servers
            .iter()
            .map(|server| roammand_host_webrtc::native::NativeIceServer {
                urls: server.urls.clone(),
                username: server.username.clone(),
                password: server.password.clone(),
            })
            .collect(),
    };
    let factory = NativeRemoteSessionFactory::new(options);
    let coordinator = RemoteSessionCoordinator::with_config(
        Arc::clone(&service),
        Box::new(factory),
        roammand_host_webrtc::SessionConfig::new(config.ice_transport_policy),
    )
    .map_err(|_| RuntimeError::RemoteSession)?;
    Ok(Some(PreparedRemote {
        config: config.clone(),
        coordinator,
        service,
    }))
}

#[cfg(not(feature = "native-webrtc"))]
fn prepare_native_remote(
    _config: &RemoteRuntimeConfig,
    _service: Arc<HostService>,
) -> Result<Option<PreparedRemote>, RuntimeError> {
    Err(RuntimeError::NativeWebRtcUnavailable)
}

#[cfg(unix)]
fn prepare_bridge_remote(
    config: Option<&RemoteRuntimeConfig>,
    privileged_bridge: &PrivilegedBridgeRuntimeConfig,
    service: Arc<HostService>,
) -> Result<Option<PreparedRemote>, RuntimeError> {
    let transport =
        UnixBridgeTransportConnector::new(privileged_bridge.endpoint.clone(), BRIDGE_IO_TIMEOUT)
            .map_err(|_| RuntimeError::PrivilegedBridgeUnavailable)?;
    let mut connector = AuthenticatedBridgeConnector::new(
        Box::new(transport),
        IpcToken::new(privileged_bridge.token),
        privileged_bridge.executable_sha256,
        privileged_bridge.os_session_id,
    )
    .map_err(|_| RuntimeError::PrivilegedBridgeUnavailable)?;
    let status = connector.probe_status().map_err(map_bridge_probe_error)?;
    service
        .update_privileged_bridge_status(status, None)
        .map_err(|_| RuntimeError::PrivilegedBridgeUnavailable)?;
    let Some(config) = config else {
        return Ok(None);
    };
    let ice_servers = config
        .ice_servers
        .iter()
        .map(|server| {
            BridgeIceServer::new(
                server.urls.clone(),
                server.username.clone(),
                server.password.clone(),
            )
            .map_err(|_| RuntimeError::RemoteConfiguration)
        })
        .collect::<Result<Vec<_>, _>>()?;
    let options =
        BridgePeerOptions::new(ice_servers).map_err(|_| RuntimeError::RemoteConfiguration)?;
    let factory = BridgeRemoteSessionFactory::new(Box::new(RpcProxyPartsFactory::new(
        Box::new(connector),
        options,
    )));
    let coordinator = RemoteSessionCoordinator::with_config(
        Arc::clone(&service),
        Box::new(factory),
        roammand_host_webrtc::SessionConfig::new(config.ice_transport_policy),
    )
    .map_err(|_| RuntimeError::RemoteSession)?;
    Ok(Some(PreparedRemote {
        config: config.clone(),
        coordinator,
        service,
    }))
}

#[cfg(not(unix))]
fn prepare_bridge_remote(
    config: Option<&RemoteRuntimeConfig>,
    privileged_bridge: &PrivilegedBridgeRuntimeConfig,
    service: Arc<HostService>,
) -> Result<Option<PreparedRemote>, RuntimeError> {
    let transport = WindowsBridgeTransportConnector::new(BRIDGE_IO_TIMEOUT)
        .map_err(|_| RuntimeError::PrivilegedBridgeUnavailable)?;
    let mut connector = AuthenticatedBridgeConnector::new(
        Box::new(transport),
        IpcToken::new(privileged_bridge.token),
        privileged_bridge.executable_sha256,
        privileged_bridge.os_session_id,
    )
    .map_err(|_| RuntimeError::PrivilegedBridgeUnavailable)?;
    let status = connector.probe_status().map_err(map_bridge_probe_error)?;
    service
        .update_privileged_bridge_status(status, None)
        .map_err(|_| RuntimeError::PrivilegedBridgeUnavailable)?;
    let Some(config) = config else {
        return Ok(None);
    };
    let ice_servers = config
        .ice_servers
        .iter()
        .map(|server| {
            BridgeIceServer::new(
                server.urls.clone(),
                server.username.clone(),
                server.password.clone(),
            )
            .map_err(|_| RuntimeError::RemoteConfiguration)
        })
        .collect::<Result<Vec<_>, _>>()?;
    let options =
        BridgePeerOptions::new(ice_servers).map_err(|_| RuntimeError::RemoteConfiguration)?;
    let factory = BridgeRemoteSessionFactory::new(Box::new(RpcProxyPartsFactory::new(
        Box::new(connector),
        options,
    )));
    let coordinator = RemoteSessionCoordinator::with_config(
        Arc::clone(&service),
        Box::new(factory),
        roammand_host_webrtc::SessionConfig::new(config.ice_transport_policy),
    )
    .map_err(|_| RuntimeError::RemoteSession)?;
    Ok(Some(PreparedRemote {
        config: config.clone(),
        coordinator,
        service,
    }))
}

const fn map_bridge_probe_error(error: ProxyError) -> RuntimeError {
    match error {
        ProxyError::HelperUnavailable => RuntimeError::ProtectedSessionAgentUnavailable,
        _ => RuntimeError::PrivilegedBridgeUnavailable,
    }
}

#[derive(Default)]
struct SignalingBackoff {
    failures: u32,
}

impl SignalingBackoff {
    fn next_delay(&mut self) -> Result<Duration, RuntimeError> {
        let mut random = [0_u8; 8];
        getrandom::fill(&mut random).map_err(|_| RuntimeError::RandomGeneration)?;
        Ok(self.delay_with_sample(u64::from_le_bytes(random)))
    }

    fn delay_with_sample(&mut self, sample: u64) -> Duration {
        let maximum = SIGNALING_RECONNECT_BASE_MS
            .saturating_mul(1_u64 << self.failures.min(4))
            .min(SIGNALING_RECONNECT_MAX_MS);
        self.failures = self.failures.saturating_add(1);
        let minimum = maximum / 2;
        Duration::from_millis(minimum + sample % (maximum - minimum + 1))
    }

    fn reset(&mut self) {
        self.failures = 0;
    }
}

struct RemoteConnection {
    transport: WebSocketSignalingTransport,
    protocol: SignalingProtocol,
    request_counter: u64,
    generation: u64,
}

pub(crate) async fn run_remote_sessions(
    mut remote: PreparedRemote,
    mut shutdown: watch::Receiver<bool>,
) -> Result<(), RuntimeError> {
    let mut generation = 0_u64;
    let mut backoff = SignalingBackoff::default();
    let mut terminations = remote.coordinator.subscribe_session_terminations();
    while !*shutdown.borrow() {
        generation = generation.saturating_add(1);
        let host_device_id = remote.coordinator.host_device_id().to_vec();
        let connected = await_offline_operation(
            Box::pin(connect_remote(&remote.config, &host_device_id, generation)),
            &mut remote.coordinator,
            &mut terminations,
            &mut shutdown,
        )
        .await;
        let connection_result = match connected {
            Ok(Some(mut connection)) => {
                remote
                    .service
                    .pairing_signaling_connected()
                    .map_err(|_| RuntimeError::RemoteSession)?;
                let registered_at = tokio::time::Instant::now();
                let result = run_registered_connection(
                    &mut connection,
                    &mut remote.coordinator,
                    &remote.service,
                    &mut terminations,
                    &mut shutdown,
                )
                .await;
                if registered_at.elapsed() >= SIGNALING_STABLE_INTERVAL {
                    backoff.reset();
                }
                result
            }
            Ok(None) => break,
            Err(error) => Err(error),
        };
        if *shutdown.borrow() {
            break;
        }
        if let Err(error) = connection_result {
            log_remote_failure("signalingConnection", error);
        }
        if let Err(error) = remote.coordinator.signaling_lost(now_unix_ms()?) {
            log_remote_failure("signalingLost", error);
        }
        remote
            .service
            .pairing_signaling_lost()
            .map_err(|_| RuntimeError::RemoteSession)?;
        if await_offline_operation(
            async {
                sleep(backoff.next_delay()?).await;
                Ok(())
            },
            &mut remote.coordinator,
            &mut terminations,
            &mut shutdown,
        )
        .await?
        .is_none()
        {
            break;
        }
    }
    remote
        .coordinator
        .shutdown()
        .map_err(|_| RuntimeError::RemoteSession)?;
    remote
        .service
        .pairing_shutdown()
        .map_err(|_| RuntimeError::RemoteSession)
}

// Keep session expiry and trusted local stops live during backoff, DNS/TLS,
// WebSocket registration, and a server that accepts but never responds.
async fn await_offline_operation<F, T>(
    operation: F,
    coordinator: &mut RemoteSessionCoordinator,
    terminations: &mut broadcast::Receiver<roammand_protocol::roammand::v1::SessionTerminatedEvent>,
    shutdown: &mut watch::Receiver<bool>,
) -> Result<Option<T>, RuntimeError>
where
    F: Future<Output = Result<T, RuntimeError>>,
{
    tokio::pin!(operation);
    loop {
        if *shutdown.borrow() {
            return Ok(None);
        }
        let deadline = coordinator.reconnect_deadline_unix_ms();
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() { return Ok(None); }
            }
            result = &mut operation => return result.map(Some),
            () = wait_for_deadline(deadline) => {
                coordinator.expire_active_reconnect(now_unix_ms()?.max(deadline.unwrap_or(0)))
                    .map_err(|_| RuntimeError::RemoteSession)?;
            }
            termination = terminations.recv() => {
                match termination {
                    Ok(event) => {
                        let _ = coordinator.handle_termination(&event, now_unix_ms()?)
                            .map_err(|_| RuntimeError::RemoteSession)?;
                    }
                    Err(_) => return Err(RuntimeError::RemoteSession),
                }
            }
        }
    }
}

async fn wait_for_deadline(deadline: Option<u64>) {
    match deadline {
        Some(deadline) => {
            let remaining = deadline.saturating_sub(now_unix_ms().unwrap_or(0));
            sleep(Duration::from_millis(remaining)).await;
        }
        None => std::future::pending().await,
    }
}

async fn connect_remote(
    config: &RemoteRuntimeConfig,
    host_device_id: &[u8],
    generation: u64,
) -> Result<RemoteConnection, RuntimeError> {
    let mut transport = timeout(
        REMOTE_OPERATION_TIMEOUT,
        WebSocketSignalingTransport::connect(&config.endpoint),
    )
    .await
    .map_err(|_| RuntimeError::RemoteSession)?
    .map_err(|_| RuntimeError::RemoteSession)?;
    let mut protocol =
        SignalingProtocol::new(host_device_id.to_vec()).map_err(|_| RuntimeError::RemoteSession)?;
    let mut request_counter = 0_u64;
    let registration_id = next_remote_request_id(generation, &mut request_counter);
    let registration = protocol
        .registration(&registration_id)
        .map_err(|_| RuntimeError::RemoteSession)?;
    transport
        .send(&registration)
        .await
        .map_err(|_| RuntimeError::RemoteSession)?;
    let registered = timeout(REMOTE_OPERATION_TIMEOUT, transport.receive_binary())
        .await
        .map_err(|_| RuntimeError::RemoteSession)?
        .map_err(|_| RuntimeError::RemoteSession)?;
    if !matches!(
        protocol.handle_binary(&registered),
        Ok(SignalingEvent::Registered { .. })
    ) {
        return Err(RuntimeError::RemoteSession);
    }
    Ok(RemoteConnection {
        transport,
        protocol,
        request_counter,
        generation,
    })
}

async fn run_registered_connection(
    connection: &mut RemoteConnection,
    coordinator: &mut RemoteSessionCoordinator,
    service: &Arc<HostService>,
    terminations: &mut broadcast::Receiver<roammand_protocol::roammand::v1::SessionTerminatedEvent>,
    shutdown: &mut watch::Receiver<bool>,
) -> Result<(), RuntimeError> {
    let RemoteConnection {
        transport,
        protocol,
        request_counter,
        generation,
    } = connection;
    let generation = *generation;
    let mut heartbeat = interval(SIGNALING_HEARTBEAT_INTERVAL);
    heartbeat.set_missed_tick_behavior(MissedTickBehavior::Skip);
    let mut peer_poll = interval(PEER_EVENT_POLL_INTERVAL);
    peer_poll.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        let pairing_deadline = service
            .pairing_deadline_unix_ms()
            .map_err(|_| RuntimeError::RemoteSession)?;
        let has_active_session = coordinator.has_active_session();
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    let _ = transport.close().await;
                    return Ok(());
                }
            }
            received = transport.receive_binary() => {
                let encoded = received.map_err(|_| RuntimeError::RemoteSession)?;
                let outbound = handle_remote_server_frame(protocol, coordinator, service, &encoded)?;
                flush_pairing(protocol, transport, service, generation, request_counter).await?;
                send_remote_outbound(
                    protocol,
                    transport,
                    outbound,
                    generation,
                    request_counter,
                ).await?;
            }
            _ = heartbeat.tick() => {
                let request_id = next_remote_request_id(generation, request_counter);
                let frame = protocol
                    .heartbeat(&request_id)
                    .map_err(|_| RuntimeError::RemoteSession)?;
                transport.send(&frame).await.map_err(|_| RuntimeError::RemoteSession)?;
            }
            () = service.pairing_activity() => {
                flush_pairing(protocol, transport, service, generation, request_counter).await?;
            }
            () = wait_for_deadline(pairing_deadline) => {
                flush_pairing(protocol, transport, service, generation, request_counter).await?;
            }
            _ = peer_poll.tick(), if has_active_session => {
                let outbound = coordinator
                    .poll_peer_events(now_unix_ms()?)
                    .map_err(|error| {
                        log_remote_failure("pollPeerEvent", error);
                        RuntimeError::RemoteSession
                    })?;
                send_remote_outbound(
                    protocol,
                    transport,
                    outbound,
                    generation,
                    request_counter,
                ).await?;
            }
            termination = terminations.recv() => {
                match termination {
                    Ok(event) => {
                        let outbound = coordinator
                            .handle_termination(&event, now_unix_ms()?)
                            .map_err(|_| RuntimeError::RemoteSession)?;
                        send_remote_outbound(
                            protocol,
                            transport,
                            outbound,
                            generation,
                            request_counter,
                        ).await?;
                    }
                    Err(
                        tokio::sync::broadcast::error::RecvError::Lagged(_)
                        | tokio::sync::broadcast::error::RecvError::Closed,
                    ) => return Err(RuntimeError::RemoteSession),
                }
            }
        }
    }
}

fn handle_remote_server_frame(
    protocol: &mut SignalingProtocol,
    coordinator: &mut RemoteSessionCoordinator,
    service: &Arc<HostService>,
    encoded: &[u8],
) -> Result<Vec<RemoteSessionOutbound>, RuntimeError> {
    let event = protocol
        .handle_binary(encoded)
        .map_err(|_| RuntimeError::RemoteSession)?;
    match event {
        SignalingEvent::RoutedSession {
            sender_device_id,
            opaque_envelope,
        } => match coordinator.handle_routed(&sender_device_id, &opaque_envelope, now_unix_ms()?) {
            Ok(outbound) => Ok(outbound),
            Err(
                error @ (RemoteSessionError::InvalidEnvelope
                | RemoteSessionError::Authentication
                | RemoteSessionError::Authorization
                | RemoteSessionError::Replay
                | RemoteSessionError::PendingIceLimit
                | RemoteSessionError::DeviceBusy),
            ) => {
                log_remote_failure("handleRouted", error);
                Ok(Vec::new())
            }
            Err(error) => {
                log_remote_failure("handleRouted", error);
                Err(RuntimeError::RemoteSession)
            }
        },
        SignalingEvent::HeartbeatAcknowledged { .. } => Ok(Vec::new()),
        event @ (SignalingEvent::PairingCreated { .. }
        | SignalingEvent::PairingJoined { .. }
        | SignalingEvent::RoutedPairing { .. }
        | SignalingEvent::PairingClosed { .. }
        | SignalingEvent::RemoteError { .. }) => {
            Ok(handle_pairing_server_event(service, event, now_unix_ms()?))
        }
        SignalingEvent::Registered { .. } => Err(RuntimeError::RemoteSession),
    }
}

fn handle_pairing_server_event(
    service: &Arc<HostService>,
    event: SignalingEvent,
    now_unix_ms: u64,
) -> Vec<RemoteSessionOutbound> {
    let _ = service.handle_pairing_signaling_event(event, now_unix_ms);
    // A malformed or stale pairing event must fail only that rendezvous. The
    // coordinator queues a rejection where appropriate; keeping this transport
    // alive lets it send that result and preserves unrelated remote sessions.
    Vec::new()
}

fn log_remote_failure(operation: &str, error: impl fmt::Debug) {
    eprintln!("[remote] host_operation={operation} cause={error:?}");
}

async fn flush_pairing(
    protocol: &mut SignalingProtocol,
    transport: &mut WebSocketSignalingTransport,
    service: &HostService,
    generation: u64,
    request_counter: &mut u64,
) -> Result<(), RuntimeError> {
    send_pairing_outbound(
        protocol,
        transport,
        service
            .poll_pairing_outbound(now_unix_ms()?)
            .map_err(|_| RuntimeError::RemoteSession)?,
        generation,
        request_counter,
    )
    .await
}

async fn send_pairing_outbound(
    protocol: &mut SignalingProtocol,
    transport: &mut WebSocketSignalingTransport,
    outbound: Vec<PairingOutbound>,
    generation: u64,
    request_counter: &mut u64,
) -> Result<(), RuntimeError> {
    for outbound in outbound {
        let request_id = next_remote_request_id(generation, request_counter);
        let frame = match outbound {
            PairingOutbound::Create {
                rendezvous_id,
                kind,
                pairing_code,
            } => protocol.create_pairing(rendezvous_id, kind, pairing_code, &request_id),
            PairingOutbound::Relay {
                rendezvous_id,
                opaque_envelope,
            } => protocol.relay_pairing(rendezvous_id, opaque_envelope, &request_id),
            PairingOutbound::Complete {
                rendezvous_id,
                completion,
            } => protocol.complete_pairing(rendezvous_id, completion, &request_id),
        }
        .map_err(|_| RuntimeError::RemoteSession)?;
        transport
            .send(&frame)
            .await
            .map_err(|_| RuntimeError::RemoteSession)?;
    }
    Ok(())
}

async fn send_remote_outbound(
    protocol: &SignalingProtocol,
    transport: &mut WebSocketSignalingTransport,
    outbound: Vec<RemoteSessionOutbound>,
    generation: u64,
    request_counter: &mut u64,
) -> Result<(), RuntimeError> {
    for outbound in outbound {
        let request_id = next_remote_request_id(generation, request_counter);
        let frame = protocol
            .relay_session(
                outbound.recipient_device_id,
                outbound.opaque_envelope,
                &request_id,
            )
            .map_err(|_| RuntimeError::RemoteSession)?;
        transport
            .send(&frame)
            .await
            .map_err(|_| RuntimeError::RemoteSession)?;
    }
    Ok(())
}

fn next_remote_request_id(generation: u64, counter: &mut u64) -> String {
    *counter = counter.saturating_add(1);
    format!("host-{generation}-{counter}")
}

#[cfg(any(target_os = "macos", windows))]
pub(crate) fn with_remote_config_from_env(
    config: AgentRuntimeConfig,
) -> Result<AgentRuntimeConfig, RuntimeError> {
    let endpoint = optional_unicode_env(SIGNALING_ENDPOINT_ENV)?;
    let policy = optional_unicode_env(ICE_TRANSPORT_POLICY_ENV)?;
    let stun_urls = optional_unicode_env(STUN_URLS_ENV)?;
    let turn_urls = optional_unicode_env(TURN_URLS_ENV)?;
    let turn_username = optional_unicode_env(TURN_USERNAME_ENV)?;
    let turn_password = optional_unicode_env(TURN_PASSWORD_ENV)?;
    let Some(endpoint) = endpoint else {
        if policy.is_some()
            || stun_urls.is_some()
            || turn_urls.is_some()
            || turn_username.is_some()
            || turn_password.is_some()
        {
            return Err(RuntimeError::RemoteConfiguration);
        }
        return Ok(config);
    };
    if endpoint.is_empty() {
        return Err(RuntimeError::RemoteConfiguration);
    }
    let ice_transport_policy = match policy.as_deref().unwrap_or("all") {
        "all" => IceTransportPolicy::All,
        "relay" => IceTransportPolicy::Relay,
        _ => return Err(RuntimeError::RemoteConfiguration),
    };
    let mut ice_servers = Vec::new();
    if let Some(value) = stun_urls {
        let urls = split_ice_urls(&value);
        ice_servers.push(RemoteIceServerConfig::new(
            urls,
            String::new(),
            String::new(),
        )?);
    }
    if let Some(value) = turn_urls {
        let urls = split_ice_urls(&value);
        let username = turn_username.ok_or(RuntimeError::RemoteConfiguration)?;
        let password = turn_password.ok_or(RuntimeError::RemoteConfiguration)?;
        ice_servers.push(RemoteIceServerConfig::new(urls, username, password)?);
    } else if turn_username.is_some() || turn_password.is_some() {
        return Err(RuntimeError::RemoteConfiguration);
    }
    Ok(config.with_remote(RemoteRuntimeConfig::new(
        endpoint,
        ice_transport_policy,
        ice_servers,
    )?))
}

#[cfg(any(target_os = "macos", windows))]
fn split_ice_urls(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .map(ToOwned::to_owned)
        .collect()
}

#[cfg(any(target_os = "macos", windows))]
fn optional_unicode_env(name: &str) -> Result<Option<String>, RuntimeError> {
    match env::var(name) {
        Ok(value) => Ok(Some(value)),
        Err(env::VarError::NotPresent) => Ok(None),
        Err(env::VarError::NotUnicode(_)) => Err(RuntimeError::Environment),
    }
}

fn valid_turn_url(value: &str) -> bool {
    valid_ice_url(value, &["turn", "turns"])
}

fn valid_stun_url(value: &str) -> bool {
    valid_ice_url(value, &["stun", "stuns"])
}

fn valid_ice_url(value: &str, schemes: &[&str]) -> bool {
    if value.is_empty()
        || value.len() > MAX_ICE_URL_UTF8_BYTES
        || value.contains('@')
        || value.chars().any(char::is_whitespace)
    {
        return false;
    }
    let Ok(parsed) = Url::parse(value) else {
        return false;
    };
    schemes.contains(&parsed.scheme()) && !parsed.path().is_empty() && parsed.fragment().is_none()
}

#[cfg(test)]
mod tests;
