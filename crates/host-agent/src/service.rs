// SPDX-License-Identifier: MPL-2.0

use std::sync::Mutex;

use roammand_protocol::roammand::v1::{
    ControllerGrantCreated, ControllerGrantList, ControllerGrantRevoked,
    EmergencyStopRemoteSessionResult, ErrorCode, HostPairingStatusSnapshot, HostStatus,
    LocalIpcClientFrame, LocalIpcServerFrame, PairingIdentityRole, PairingInvitationKind,
    PrivilegedBridgeState, PrivilegedBridgeStatusSnapshot, ProtocolVersion,
    RemoteSessionStatusSnapshot, SessionAnswerAuthentication, SessionOfferAuthentication,
    SessionPermission, SessionReconnectAuthentication, SessionState, SessionStatus, UnifiedError,
    local_ipc_client_frame, local_ipc_server_frame,
};
use roammand_protocol::{
    canonical_transcript::sha256,
    validation::{
        validate_privileged_bridge_status_snapshot, validate_remote_session_status_snapshot,
    },
};
use thiserror::Error;
use tokio::sync::{Notify, broadcast};

use crate::{
    AuthorizationError, AuthorizationRegistry, HostIdentity, HostPairingCoordinator, IdentityError,
    PairingCoordinatorError, PairingOutbound, SignalingEvent,
    session_auth::{
        OfferVerifier, SessionAuthenticationError, VerifiedSessionOffer,
        encode_session_answer_transcript, encode_session_reconnect_transcript,
    },
    sessions::{SessionRegistry, SessionRegistryError},
};

const PROTOCOL_MAJOR_VERSION: u32 = 1;
const PROTOCOL_MINOR_VERSION: u32 = 0;
const PAIRING_EVENT_CAPACITY: usize = 32;

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum BridgeStatusError {
    #[error("privileged bridge status is invalid")]
    InvalidStatus,
    #[error("privileged bridge status generation is stale")]
    StaleGeneration,
    #[error("privileged bridge status is unavailable")]
    Unavailable,
}

pub struct HostService {
    identity: HostIdentity,
    authorization: Mutex<AuthorizationRegistry>,
    sessions: SessionRegistry,
    remote_status: Mutex<RemoteSessionStatusSnapshot>,
    privileged_bridge_status: Mutex<PrivilegedBridgeStatusSnapshot>,
    privileged_bridge_generation: Mutex<u64>,
    pairing: Mutex<HostPairingCoordinator>,
    pairing_events: broadcast::Sender<HostPairingStatusSnapshot>,
    pairing_activity: Notify,
    instance_id: [u8; 16],
    started_at_unix_ms: u64,
}

impl HostService {
    #[must_use]
    pub fn new(
        identity: HostIdentity,
        authorization: AuthorizationRegistry,
        instance_id: [u8; 16],
        started_at_unix_ms: u64,
    ) -> Self {
        let pairing =
            HostPairingCoordinator::from_validated_host(identity.device_identity().clone());
        let (pairing_events, _) = broadcast::channel(PAIRING_EVENT_CAPACITY);
        Self {
            identity,
            authorization: Mutex::new(authorization),
            sessions: SessionRegistry::new(),
            remote_status: Mutex::new(idle_remote_status()),
            privileged_bridge_status: Mutex::new(user_session_only_bridge_status()),
            privileged_bridge_generation: Mutex::new(0),
            pairing: Mutex::new(pairing),
            pairing_events,
            pairing_activity: Notify::new(),
            instance_id,
            started_at_unix_ms,
        }
    }

    #[must_use]
    pub fn handle_frame(
        &self,
        frame: &LocalIpcClientFrame,
        now_unix_ms: u64,
    ) -> LocalIpcServerFrame {
        let result = frame
            .payload
            .as_ref()
            .ok_or(ServiceError::InvalidRequest)
            .and_then(|payload| self.handle_payload(payload, now_unix_ms));
        let payload = match result {
            Ok(payload) => payload,
            Err(error) => {
                local_ipc_server_frame::Payload::Error(error.to_unified_error(&frame.request_id))
            }
        };
        LocalIpcServerFrame {
            protocol_version: Some(protocol_version()),
            request_id: frame.request_id.clone(),
            payload: Some(payload),
        }
    }

    /// Registers an authenticated active remote session.
    ///
    /// # Errors
    ///
    /// Returns an error for invalid or duplicate identifiers, or unavailable
    /// session state.
    pub fn register_active_session(
        &self,
        session_id: Vec<u8>,
        controller_device_id: Vec<u8>,
    ) -> Result<(), SessionRegistryError> {
        self.sessions.register(session_id, controller_device_id)
    }

    #[must_use]
    pub fn subscribe_session_terminations(
        &self,
    ) -> broadcast::Receiver<roammand_protocol::roammand::v1::SessionTerminatedEvent> {
        self.sessions.subscribe()
    }

    #[must_use]
    pub fn active_session_count(&self) -> usize {
        self.sessions.count().unwrap_or(0)
    }

    /// Publishes one sanitized, monotonic bridge snapshot for local UI clients.
    ///
    /// A controlled snapshot accepts no display name from the privileged side;
    /// it resolves the public name from the existing permanent Host grant.
    ///
    /// # Errors
    ///
    /// Rejects invalid state, unbound Controller identity, stale generation, or
    /// unavailable internal state.
    pub fn update_privileged_bridge_status(
        &self,
        mut snapshot: PrivilegedBridgeStatusSnapshot,
        controller_device_id: Option<&[u8]>,
    ) -> Result<(), BridgeStatusError> {
        if !snapshot.active_controller_display_name.is_empty() {
            return Err(BridgeStatusError::InvalidStatus);
        }
        let state = PrivilegedBridgeState::try_from(snapshot.state)
            .map_err(|_| BridgeStatusError::InvalidStatus)?;
        if state == PrivilegedBridgeState::Controlled {
            let controller_device_id =
                controller_device_id.ok_or(BridgeStatusError::InvalidStatus)?;
            let authorization = self
                .authorization
                .lock()
                .map_err(|_| BridgeStatusError::Unavailable)?;
            snapshot.active_controller_display_name = authorization
                .list_controller_grants()
                .into_iter()
                .filter_map(|view| view.grant)
                .filter_map(|grant| grant.controller)
                .find(|controller| controller.device_id == controller_device_id)
                .map(|controller| controller.display_name)
                .ok_or(BridgeStatusError::InvalidStatus)?;
        } else if controller_device_id.is_some() {
            return Err(BridgeStatusError::InvalidStatus);
        }
        validate_privileged_bridge_status_snapshot(&snapshot)
            .map_err(|_| BridgeStatusError::InvalidStatus)?;

        let next_generation = snapshot
            .interactive_session
            .as_ref()
            .map_or(0, |session| session.generation);
        let mut generation = self
            .privileged_bridge_generation
            .lock()
            .map_err(|_| BridgeStatusError::Unavailable)?;
        if next_generation != 0 && next_generation < *generation {
            return Err(BridgeStatusError::StaleGeneration);
        }
        let mut current = self
            .privileged_bridge_status
            .lock()
            .map_err(|_| BridgeStatusError::Unavailable)?;
        if next_generation != 0 {
            *generation = next_generation;
        }
        *current = snapshot;
        Ok(())
    }

    #[must_use]
    pub const fn device_identity(&self) -> &roammand_protocol::roammand::v1::DeviceIdentity {
        self.identity.device_identity()
    }

    #[must_use]
    pub fn subscribe_host_pairing_states(&self) -> broadcast::Receiver<HostPairingStatusSnapshot> {
        self.pairing_events.subscribe()
    }

    /// Marks the pairing rendezvous transport ready after registration.
    ///
    /// # Errors
    ///
    /// Returns an error when the pairing state lock is unavailable.
    pub fn pairing_signaling_connected(&self) -> Result<(), PairingCoordinatorError> {
        self.pairing
            .lock()
            .map_err(|_| PairingCoordinatorError::InvalidState)?
            .signaling_connected();
        Ok(())
    }

    pub(crate) fn pairing_signaling_lost(&self) -> Result<(), PairingCoordinatorError> {
        let mut pairing = self
            .pairing
            .lock()
            .map_err(|_| PairingCoordinatorError::InvalidState)?;
        let previous_revision = pairing.revision();
        pairing.signaling_lost();
        self.publish_pairing_snapshot(previous_revision, &pairing);
        Ok(())
    }

    pub(crate) fn pairing_shutdown(&self) -> Result<(), PairingCoordinatorError> {
        let mut pairing = self
            .pairing
            .lock()
            .map_err(|_| PairingCoordinatorError::InvalidState)?;
        let previous_revision = pairing.revision();
        pairing.shutdown();
        self.publish_pairing_snapshot(previous_revision, &pairing);
        Ok(())
    }

    pub(crate) fn handle_pairing_signaling_event(
        &self,
        event: SignalingEvent,
        now_unix_ms: u64,
    ) -> Result<(), PairingCoordinatorError> {
        let mut pairing = self
            .pairing
            .lock()
            .map_err(|_| PairingCoordinatorError::InvalidState)?;
        let previous_revision = pairing.revision();
        let result = pairing.handle_signaling_event(event, &self.identity, now_unix_ms);
        self.publish_pairing_snapshot(previous_revision, &pairing);
        result
    }

    pub(crate) fn poll_pairing_outbound(
        &self,
        now_unix_ms: u64,
    ) -> Result<Vec<PairingOutbound>, PairingCoordinatorError> {
        let mut pairing = self
            .pairing
            .lock()
            .map_err(|_| PairingCoordinatorError::InvalidState)?;
        let previous_revision = pairing.revision();
        pairing.tick(now_unix_ms);
        self.publish_pairing_snapshot(previous_revision, &pairing);
        Ok(pairing.take_outbound())
    }

    /// Returns the current sanitized Host pairing snapshot.
    ///
    /// # Errors
    ///
    /// Returns an error when the pairing state lock is unavailable.
    pub fn host_pairing_status(
        &self,
    ) -> Result<HostPairingStatusSnapshot, PairingCoordinatorError> {
        self.pairing
            .lock()
            .map_err(|_| PairingCoordinatorError::InvalidState)
            .map(|pairing| pairing.snapshot())
    }

    /// Starts one Host-owned QR or desktop-code pairing invitation.
    ///
    /// # Errors
    ///
    /// Returns the coordinator's state, input, endpoint, or randomness error.
    pub fn start_host_pairing(
        &self,
        kind: PairingInvitationKind,
        signaling_endpoint: &str,
        now_unix_ms: u64,
    ) -> Result<HostPairingStatusSnapshot, PairingCoordinatorError> {
        let mut pairing = self
            .pairing
            .lock()
            .map_err(|_| PairingCoordinatorError::InvalidState)?;
        let previous_revision = pairing.revision();
        let result = pairing.start(kind, signaling_endpoint, now_unix_ms);
        self.publish_pairing_snapshot(previous_revision, &pairing);
        result
    }

    /// Accepts the exact verified pending Controller and persists its grant.
    ///
    /// # Errors
    ///
    /// Returns an error for stale identifiers, invalid state, expiry, locking,
    /// or authorization persistence failure.
    pub fn accept_host_pairing(
        &self,
        rendezvous_id: &[u8],
        controller_device_id: &[u8],
        now_unix_ms: u64,
    ) -> Result<(), PairingCoordinatorError> {
        let mut pairing = self
            .pairing
            .lock()
            .map_err(|_| PairingCoordinatorError::InvalidState)?;
        let mut authorization = self
            .authorization
            .lock()
            .map_err(|_| PairingCoordinatorError::InvalidState)?;
        let previous_revision = pairing.revision();
        let result = pairing.accept(
            rendezvous_id,
            controller_device_id,
            &mut authorization,
            now_unix_ms,
        );
        self.publish_pairing_snapshot(previous_revision, &pairing);
        result
    }

    /// Rejects the exact verified pending Controller.
    ///
    /// # Errors
    ///
    /// Returns an error for stale identifiers, invalid state, expiry, or an
    /// unavailable pairing lock.
    pub fn reject_host_pairing(
        &self,
        rendezvous_id: &[u8],
        controller_device_id: &[u8],
        now_unix_ms: u64,
    ) -> Result<(), PairingCoordinatorError> {
        let mut pairing = self
            .pairing
            .lock()
            .map_err(|_| PairingCoordinatorError::InvalidState)?;
        let previous_revision = pairing.revision();
        let result = pairing.reject(rendezvous_id, controller_device_id, now_unix_ms);
        self.publish_pairing_snapshot(previous_revision, &pairing);
        result
    }

    /// Cancels the active pairing without granting authorization.
    ///
    /// # Errors
    ///
    /// Returns an error when no pairing is active or the state lock fails.
    pub fn cancel_host_pairing(
        &self,
        rendezvous_id: &[u8],
        now_unix_ms: u64,
    ) -> Result<(), PairingCoordinatorError> {
        let mut pairing = self
            .pairing
            .lock()
            .map_err(|_| PairingCoordinatorError::InvalidState)?;
        let previous_revision = pairing.revision();
        let result = pairing.cancel(rendezvous_id, now_unix_ms);
        self.publish_pairing_snapshot(previous_revision, &pairing);
        result
    }

    fn publish_pairing_snapshot(&self, previous_revision: u64, pairing: &HostPairingCoordinator) {
        if pairing.revision() != previous_revision {
            let _ = self.pairing_events.send(pairing.snapshot());
            self.pairing_activity.notify_one();
        } else if pairing.has_outbound() {
            self.pairing_activity.notify_one();
        }
    }

    pub(crate) async fn pairing_activity(&self) {
        self.pairing_activity.notified().await;
    }

    pub(crate) fn pairing_deadline_unix_ms(&self) -> Result<Option<u64>, PairingCoordinatorError> {
        self.pairing
            .lock()
            .map(|pairing| pairing.deadline_unix_ms())
            .map_err(|_| PairingCoordinatorError::InvalidState)
    }

    /// Creates a grant through an explicit current-user maintenance action.
    ///
    /// This method is not reachable through signaling and does not weaken
    /// session authentication.
    ///
    /// # Errors
    ///
    /// Returns the normal persistent authorization errors.
    pub fn create_controller_grant_for_maintenance(
        &self,
        controller: roammand_protocol::roammand::v1::DeviceIdentity,
        permissions: &[SessionPermission],
        now_unix_ms: u64,
    ) -> Result<roammand_protocol::roammand::v1::ControllerGrantView, AuthorizationError> {
        self.authorization
            .lock()
            .map_err(|_| AuthorizationError::Store(crate::GrantStoreError::Io))?
            .create_controller_grant(controller, permissions, now_unix_ms)
    }

    pub(crate) fn verify_remote_offer(
        &self,
        verifier: &mut OfferVerifier,
        authentication: &SessionOfferAuthentication,
        offer_sdp: &str,
        controller_fingerprint: &[u8],
        now_unix_ms: u64,
    ) -> Result<VerifiedSessionOffer, RemoteServiceError> {
        let authorization = self
            .authorization
            .lock()
            .map_err(|_| RemoteServiceError::Unavailable)?;
        verifier
            .verify(
                authentication,
                offer_sdp,
                controller_fingerprint,
                &authorization,
                now_unix_ms,
            )
            .map_err(RemoteServiceError::Authentication)
    }

    pub(crate) fn sign_remote_answer(
        &self,
        offer: &SessionOfferAuthentication,
        answer_sdp: &str,
        host_fingerprint: &[u8],
    ) -> Result<SessionAnswerAuthentication, RemoteServiceError> {
        let mut answer = SessionAnswerAuthentication {
            controller_device_id: offer.controller_device_id.clone(),
            host_device_id: offer.host_device_id.clone(),
            session_id: offer.session_id.clone(),
            nonce: offer.nonce.clone(),
            issued_at_unix_ms: offer.issued_at_unix_ms,
            expires_at_unix_ms: offer.expires_at_unix_ms,
            requested_permissions: offer.requested_permissions.clone(),
            offer_sha256: offer.offer_sha256.clone(),
            controller_dtls_fingerprint_sha256: offer.controller_dtls_fingerprint_sha256.clone(),
            answer_sha256: sha256(answer_sdp.as_bytes()).to_vec(),
            host_dtls_fingerprint_sha256: host_fingerprint.to_vec(),
            signature: Vec::new(),
        };
        let transcript = encode_session_answer_transcript(&answer)
            .map_err(RemoteServiceError::Authentication)?;
        answer.signature = self
            .identity
            .sign_canonical_transcript(&transcript)
            .map_err(|_| RemoteServiceError::Identity)?
            .signature;
        Ok(answer)
    }

    pub(crate) fn sign_remote_reconnect(
        &self,
        offer: &SessionOfferAuthentication,
        answer_sdp: &str,
        host_fingerprint: &[u8],
        reconnect_generation: u32,
    ) -> Result<SessionReconnectAuthentication, RemoteServiceError> {
        let mut reconnect = SessionReconnectAuthentication {
            controller_device_id: offer.controller_device_id.clone(),
            host_device_id: offer.host_device_id.clone(),
            session_id: offer.session_id.clone(),
            nonce: offer.nonce.clone(),
            issued_at_unix_ms: offer.issued_at_unix_ms,
            expires_at_unix_ms: offer.expires_at_unix_ms,
            requested_permissions: offer.requested_permissions.clone(),
            offer_sha256: offer.offer_sha256.clone(),
            controller_dtls_fingerprint_sha256: offer.controller_dtls_fingerprint_sha256.clone(),
            answer_sha256: sha256(answer_sdp.as_bytes()).to_vec(),
            host_dtls_fingerprint_sha256: host_fingerprint.to_vec(),
            reconnect_generation,
            signature: Vec::new(),
        };
        let transcript = encode_session_reconnect_transcript(&reconnect)
            .map_err(RemoteServiceError::Authentication)?;
        reconnect.signature = self
            .identity
            .sign_canonical_transcript(&transcript)
            .map_err(|_| RemoteServiceError::Identity)?
            .signature;
        Ok(reconnect)
    }

    pub(crate) fn record_authenticated_remote_session(
        &self,
        controller_device_id: &[u8],
        now_unix_ms: u64,
    ) -> Result<(), RemoteServiceError> {
        self.authorization
            .lock()
            .map_err(|_| RemoteServiceError::Unavailable)?
            .record_authenticated_session(controller_device_id, now_unix_ms)
            .map(|_| ())
            .map_err(|_| RemoteServiceError::Authorization)
    }

    pub(crate) fn unregister_active_session(
        &self,
        session_id: &[u8],
    ) -> Result<(), RemoteServiceError> {
        self.sessions
            .unregister(session_id)
            .map(|_| ())
            .map_err(|_| RemoteServiceError::Session)
    }

    pub(crate) fn update_remote_status(
        &self,
        session_id: Vec<u8>,
        controller_device_id: Vec<u8>,
        state: SessionState,
        error: Option<UnifiedError>,
    ) -> Result<(), RemoteServiceError> {
        let snapshot = RemoteSessionStatusSnapshot {
            session_status: Some(SessionStatus {
                session_id,
                state: state as i32,
                error,
            }),
            controller_device_id,
        };
        validate_remote_session_status_snapshot(&snapshot)
            .map_err(|_| RemoteServiceError::InvalidStatus)?;
        *self
            .remote_status
            .lock()
            .map_err(|_| RemoteServiceError::Unavailable)? = snapshot;
        Ok(())
    }

    fn handle_payload(
        &self,
        payload: &local_ipc_client_frame::Payload,
        now_unix_ms: u64,
    ) -> Result<local_ipc_server_frame::Payload, ServiceError> {
        match payload {
            local_ipc_client_frame::Payload::Authenticate(_) => Err(ServiceError::InvalidRequest),
            local_ipc_client_frame::Payload::GetHostStatus(_) => self.host_status(),
            local_ipc_client_frame::Payload::ListControllerGrants(_) => {
                let authorization = self
                    .authorization
                    .lock()
                    .map_err(|_| ServiceError::Internal)?;
                Ok(local_ipc_server_frame::Payload::ControllerGrantList(
                    ControllerGrantList {
                        grants: authorization.list_controller_grants(),
                    },
                ))
            }
            local_ipc_client_frame::Payload::CreateControllerGrant(request) => {
                let controller = request
                    .controller
                    .clone()
                    .ok_or(ServiceError::InvalidRequest)?;
                let permissions = request
                    .permissions
                    .iter()
                    .map(|value| {
                        SessionPermission::try_from(*value)
                            .map_err(|_| ServiceError::InvalidRequest)
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                let grant = self
                    .authorization
                    .lock()
                    .map_err(|_| ServiceError::Internal)?
                    .create_controller_grant(controller, &permissions, now_unix_ms)?;
                Ok(local_ipc_server_frame::Payload::ControllerGrantCreated(
                    ControllerGrantCreated { grant: Some(grant) },
                ))
            }
            local_ipc_client_frame::Payload::SignCanonicalTranscript(request) => {
                let signature = self
                    .identity
                    .sign_canonical_transcript(&request.canonical_transcript)?;
                Ok(local_ipc_server_frame::Payload::CanonicalTranscriptSignature(signature))
            }
            local_ipc_client_frame::Payload::RevokeControllerGrant(request) => {
                self.revoke(&request.grant_id)
            }
            local_ipc_client_frame::Payload::SignSessionOffer(request) => {
                let signature = self
                    .identity
                    .sign_session_offer(&request.canonical_transcript)?;
                Ok(local_ipc_server_frame::Payload::SessionOfferSignature(
                    signature,
                ))
            }
            local_ipc_client_frame::Payload::GetRemoteSessionStatus(_) => {
                let snapshot = self
                    .remote_status
                    .lock()
                    .map_err(|_| ServiceError::Internal)?
                    .clone();
                Ok(local_ipc_server_frame::Payload::RemoteSessionStatus(
                    snapshot,
                ))
            }
            local_ipc_client_frame::Payload::SignPairingTranscript(request) => {
                let role = PairingIdentityRole::try_from(request.role)
                    .map_err(|_| ServiceError::InvalidRequest)?;
                let signature = self
                    .identity
                    .sign_pairing_transcript(&request.canonical_transcript, role)?;
                Ok(local_ipc_server_frame::Payload::PairingTranscriptSignature(
                    signature,
                ))
            }
            pairing_payload @ (local_ipc_client_frame::Payload::StartHostQrPairing(_)
            | local_ipc_client_frame::Payload::StartHostDesktopCodePairing(_)
            | local_ipc_client_frame::Payload::CancelHostPairing(_)
            | local_ipc_client_frame::Payload::GetHostPairingStatus(_)
            | local_ipc_client_frame::Payload::AcceptHostPairing(_)
            | local_ipc_client_frame::Payload::RejectHostPairing(_)) => {
                self.handle_pairing_payload(pairing_payload, now_unix_ms)
            }
            local_ipc_client_frame::Payload::EmergencyStopRemoteSession(_) => self.emergency_stop(),
        }
    }

    fn handle_pairing_payload(
        &self,
        payload: &local_ipc_client_frame::Payload,
        now_unix_ms: u64,
    ) -> Result<local_ipc_server_frame::Payload, ServiceError> {
        match payload {
            local_ipc_client_frame::Payload::StartHostQrPairing(request) => Ok(
                local_ipc_server_frame::Payload::HostPairingStatus(self.start_host_pairing(
                    PairingInvitationKind::Qr,
                    &request.signaling_endpoint,
                    now_unix_ms,
                )?),
            ),
            local_ipc_client_frame::Payload::StartHostDesktopCodePairing(request) => Ok(
                local_ipc_server_frame::Payload::HostPairingStatus(self.start_host_pairing(
                    PairingInvitationKind::DesktopCode,
                    &request.signaling_endpoint,
                    now_unix_ms,
                )?),
            ),
            local_ipc_client_frame::Payload::CancelHostPairing(request) => {
                self.cancel_host_pairing(&request.rendezvous_id, now_unix_ms)?;
                self.pairing_status_payload()
            }
            local_ipc_client_frame::Payload::GetHostPairingStatus(_) => {
                let mut pairing = self.pairing.lock().map_err(|_| ServiceError::Internal)?;
                let previous_revision = pairing.revision();
                pairing.tick(now_unix_ms);
                let status = pairing.snapshot();
                self.publish_pairing_snapshot(previous_revision, &pairing);
                Ok(local_ipc_server_frame::Payload::HostPairingStatus(status))
            }
            local_ipc_client_frame::Payload::AcceptHostPairing(request) => {
                self.accept_host_pairing(
                    &request.rendezvous_id,
                    &request.controller_device_id,
                    now_unix_ms,
                )?;
                self.pairing_status_payload()
            }
            local_ipc_client_frame::Payload::RejectHostPairing(request) => {
                self.reject_host_pairing(
                    &request.rendezvous_id,
                    &request.controller_device_id,
                    now_unix_ms,
                )?;
                self.pairing_status_payload()
            }
            _ => Err(ServiceError::InvalidRequest),
        }
    }

    fn pairing_status_payload(&self) -> Result<local_ipc_server_frame::Payload, ServiceError> {
        Ok(local_ipc_server_frame::Payload::HostPairingStatus(
            self.host_pairing_status()?,
        ))
    }

    fn host_status(&self) -> Result<local_ipc_server_frame::Payload, ServiceError> {
        let grant_count = self
            .authorization
            .lock()
            .map_err(|_| ServiceError::Internal)?
            .list_controller_grants()
            .len();
        Ok(local_ipc_server_frame::Payload::HostStatus(HostStatus {
            identity: Some(self.identity.device_identity().clone()),
            agent_instance_id: self.instance_id.to_vec(),
            agent_started_at_unix_ms: self.started_at_unix_ms,
            controller_grant_count: u32::try_from(grant_count)
                .map_err(|_| ServiceError::Internal)?,
            privileged_bridge: Some(
                self.privileged_bridge_status
                    .lock()
                    .map_err(|_| ServiceError::Internal)?
                    .clone(),
            ),
        }))
    }

    fn emergency_stop(&self) -> Result<local_ipc_server_frame::Payload, ServiceError> {
        let terminated = self
            .sessions
            .terminate_all(ErrorCode::LocalEmergencyStop)
            .map_err(|_| ServiceError::Session)?;
        *self
            .remote_status
            .lock()
            .map_err(|_| ServiceError::Internal)? = idle_remote_status();
        let mut bridge = self
            .privileged_bridge_status
            .lock()
            .map_err(|_| ServiceError::Internal)?;
        if bridge.interactive_session.is_some() && bridge.helper_connected {
            bridge.state = PrivilegedBridgeState::Ready as i32;
            bridge.active_controller_display_name.clear();
            bridge.error = None;
        } else {
            *bridge = user_session_only_bridge_status();
        }
        Ok(
            local_ipc_server_frame::Payload::EmergencyStopRemoteSessionResult(
                EmergencyStopRemoteSessionResult {
                    terminated_session_count: u32::try_from(terminated.len())
                        .map_err(|_| ServiceError::Internal)?,
                },
            ),
        )
    }

    fn revoke(&self, grant_id: &[u8]) -> Result<local_ipc_server_frame::Payload, ServiceError> {
        let revoked = self
            .authorization
            .lock()
            .map_err(|_| ServiceError::Internal)?
            .revoke_controller_grant(grant_id)?;
        let controller_device_id = revoked
            .grant
            .as_ref()
            .and_then(|grant| grant.controller.as_ref())
            .map(|controller| controller.device_id.as_slice())
            .ok_or(ServiceError::Internal)?;
        let terminated = self
            .sessions
            .terminate_controller(controller_device_id)
            .map_err(|_| ServiceError::Session)?;
        Ok(local_ipc_server_frame::Payload::ControllerGrantRevoked(
            ControllerGrantRevoked {
                grant_id: grant_id.to_vec(),
                terminated_session_count: u32::try_from(terminated.len())
                    .map_err(|_| ServiceError::Internal)?,
            },
        ))
    }
}

#[derive(Clone, Copy, Debug, Error, PartialEq)]
pub(crate) enum RemoteServiceError {
    #[error("remote session authentication failed")]
    Authentication(SessionAuthenticationError),
    #[error("remote session authorization persistence failed")]
    Authorization,
    #[error("remote session answer signing failed")]
    Identity,
    #[error("remote session registry failed")]
    Session,
    #[error("remote session status is invalid")]
    InvalidStatus,
    #[error("remote session service is unavailable")]
    Unavailable,
}

enum ServiceError {
    InvalidRequest,
    Authorization(AuthorizationError),
    Identity,
    Pairing(PairingCoordinatorError),
    Session,
    Internal,
}

impl ServiceError {
    fn to_unified_error(&self, request_id: &str) -> UnifiedError {
        let (code, message_key, retryable) = match self {
            Self::InvalidRequest => (
                ErrorCode::InvalidRequest,
                "local_ipc.invalid_request",
                false,
            ),
            Self::Authorization(AuthorizationError::GrantNotFound) => {
                (ErrorCode::AuthRevoked, "local_ipc.grant_not_found", false)
            }
            Self::Authorization(AuthorizationError::Store(_))
            | Self::Internal
            | Self::Pairing(
                PairingCoordinatorError::Authorization(AuthorizationError::Store(_))
                | PairingCoordinatorError::Random(_),
            ) => (
                ErrorCode::ServerUnavailable,
                "local_ipc.temporarily_unavailable",
                true,
            ),
            Self::Authorization(_) => (ErrorCode::InvalidRequest, "local_ipc.invalid_grant", false),
            Self::Identity => (
                ErrorCode::AuthInvalid,
                "local_ipc.invalid_transcript",
                false,
            ),
            Self::Pairing(PairingCoordinatorError::Expired) => (
                ErrorCode::PairingCodeExpired,
                "local_ipc.pairing_expired",
                false,
            ),
            Self::Pairing(PairingCoordinatorError::Authentication) => (
                ErrorCode::AuthInvalid,
                "local_ipc.pairing_authentication_failed",
                false,
            ),
            Self::Pairing(_) => (
                ErrorCode::InvalidRequest,
                "local_ipc.invalid_pairing_state",
                false,
            ),
            Self::Session => (
                ErrorCode::InvalidRequest,
                "local_ipc.invalid_session",
                false,
            ),
        };
        UnifiedError {
            code: code as i32,
            message_key: message_key.to_owned(),
            retryable,
            request_id: request_id.to_owned(),
            details: None,
        }
    }
}

impl From<AuthorizationError> for ServiceError {
    fn from(error: AuthorizationError) -> Self {
        Self::Authorization(error)
    }
}

impl From<IdentityError> for ServiceError {
    fn from(_error: IdentityError) -> Self {
        Self::Identity
    }
}

impl From<PairingCoordinatorError> for ServiceError {
    fn from(error: PairingCoordinatorError) -> Self {
        Self::Pairing(error)
    }
}

const fn protocol_version() -> ProtocolVersion {
    ProtocolVersion {
        major: PROTOCOL_MAJOR_VERSION,
        minor: PROTOCOL_MINOR_VERSION,
    }
}

fn idle_remote_status() -> RemoteSessionStatusSnapshot {
    RemoteSessionStatusSnapshot {
        session_status: Some(SessionStatus {
            session_id: Vec::new(),
            state: SessionState::Idle as i32,
            error: None,
        }),
        controller_device_id: Vec::new(),
    }
}

fn user_session_only_bridge_status() -> PrivilegedBridgeStatusSnapshot {
    PrivilegedBridgeStatusSnapshot {
        state: PrivilegedBridgeState::UserSessionOnly as i32,
        ..Default::default()
    }
}
