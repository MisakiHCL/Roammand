// SPDX-License-Identifier: MPL-2.0

use std::{fmt, sync::Arc};

use prost::Message;
use roammand_host_webrtc::{
    HostPeerSession, HostSessionState, HostWebRtcError, IceTransportPolicy, PeerBackend,
    PeerIceCandidate, RemoteInputSink, SessionConfig,
};
use roammand_protocol::{
    protocol_limits::{MAX_OPAQUE_SIGNALING_ENVELOPE_BYTES, MINIMUM_PROTOCOL_MINOR_VERSION},
    roammand::v1::{
        ErrorCode, ProtocolVersion, SessionAuthentication, SessionDescriptionType,
        SessionOfferAuthentication, SessionState, SessionTerminatedEvent, SignalingEnvelope,
        UnifiedError, WebRtcNegotiation, WebRtcSessionDescription, session_authentication,
        signaling_envelope, web_rtc_negotiation,
    },
    validation::decode_and_validate_signaling_envelope,
};
use thiserror::Error;

use crate::{
    HostService, OfferVerifier, VerifiedSessionOffer,
    remote_session_state::{
        ActiveSession, FailedSessionAttempt, PENDING_SESSION_LIFETIME_MS, PendingSession,
        StartedSession,
    },
    service::RemoteServiceError,
};

const LOCAL_TERMINATION_REQUEST_ID: &str = "host-termination";

#[derive(Clone, Eq, PartialEq)]
pub enum RemotePeerEvent {
    Connected,
    Disconnected,
    Failed,
    LocalStop,
    LocalIceCandidate(PeerIceCandidate),
    ReliableInput(Vec<u8>),
    FastPointer(Vec<u8>),
}

impl fmt::Debug for RemotePeerEvent {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let (kind, payload_bytes) = match self {
            Self::Connected => ("connected", 0),
            Self::Disconnected => ("disconnected", 0),
            Self::Failed => ("failed", 0),
            Self::LocalStop => ("local_stop", 0),
            Self::LocalIceCandidate(_) => ("local_ice_candidate", 0),
            Self::ReliableInput(encoded) => ("reliable_input", encoded.len()),
            Self::FastPointer(encoded) => ("fast_pointer", encoded.len()),
        };
        formatter
            .debug_struct("RemotePeerEvent")
            .field("kind", &kind)
            .field("payload_bytes", &payload_bytes)
            .finish()
    }
}

pub trait RemotePeerEventSource: Send {
    /// Polls one peer event without blocking.
    ///
    /// # Errors
    ///
    /// Returns a stable peer error if the native event queue failed.
    fn try_recv(&self) -> Result<Option<RemotePeerEvent>, RemoteSessionError>;
}

pub struct RemoteSessionParts {
    peer: Box<dyn PeerBackend>,
    input: Box<dyn RemoteInputSink>,
    events: Box<dyn RemotePeerEventSource>,
}

#[derive(Clone, Eq, PartialEq)]
pub struct RemoteSessionContext {
    session_id: Vec<u8>,
    permissions: Vec<roammand_protocol::roammand::v1::SessionPermission>,
    controller_display_name: String,
}

impl RemoteSessionContext {
    fn from_verified(verified: &VerifiedSessionOffer) -> Self {
        Self {
            session_id: verified.session_id.clone(),
            permissions: verified.permissions.clone(),
            controller_display_name: verified.controller.display_name.clone(),
        }
    }

    #[must_use]
    pub fn session_id(&self) -> &[u8] {
        &self.session_id
    }

    #[must_use]
    pub fn permissions(&self) -> &[roammand_protocol::roammand::v1::SessionPermission] {
        &self.permissions
    }

    #[must_use]
    pub fn controller_display_name(&self) -> &str {
        &self.controller_display_name
    }
}

impl fmt::Debug for RemoteSessionContext {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RemoteSessionContext")
            .field("permission_count", &self.permissions.len())
            .field("sensitive", &"[REDACTED]")
            .finish_non_exhaustive()
    }
}

impl RemoteSessionParts {
    #[must_use]
    pub fn new(
        peer: Box<dyn PeerBackend>,
        input: Box<dyn RemoteInputSink>,
        events: Box<dyn RemotePeerEventSource>,
    ) -> Self {
        Self {
            peer,
            input,
            events,
        }
    }
}

impl fmt::Debug for RemoteSessionParts {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("RemoteSessionParts([REDACTED])")
    }
}

pub trait RemoteSessionFactory: Send {
    /// Creates session-scoped peer, input, and event resources.
    ///
    /// # Errors
    ///
    /// Returns a stable error when platform resources cannot be initialized.
    fn create(
        &mut self,
        config: &SessionConfig,
        context: &RemoteSessionContext,
    ) -> Result<RemoteSessionParts, RemoteSessionError>;
}

#[derive(Clone, Eq, PartialEq)]
pub struct RemoteSessionOutbound {
    pub recipient_device_id: Vec<u8>,
    pub opaque_envelope: Vec<u8>,
}

impl fmt::Debug for RemoteSessionOutbound {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RemoteSessionOutbound")
            .field("opaque_envelope_bytes", &self.opaque_envelope.len())
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum RemoteSessionError {
    #[error("remote signaling envelope is invalid")]
    InvalidEnvelope,
    #[error("remote session is busy")]
    DeviceBusy,
    #[error("remote session authentication failed")]
    Authentication,
    #[error("remote session authorization was revoked")]
    Authorization,
    #[error("remote session authentication was replayed")]
    Replay,
    #[error("remote session pending ICE limit was exceeded")]
    PendingIceLimit,
    #[error("remote peer failed")]
    Peer,
    #[error("remote input failed")]
    Input,
    #[error("remote input permission is required")]
    InputPermission,
    #[error("remote session service failed")]
    Service,
    #[error("remote session coordinator is closed")]
    Closed,
}

pub struct RemoteSessionCoordinator {
    pub(super) service: Arc<HostService>,
    pub(super) verifier: OfferVerifier,
    factory: Box<dyn RemoteSessionFactory>,
    config: SessionConfig,
    pending: Option<PendingSession>,
    failed_attempt: Option<FailedSessionAttempt>,
    pub(super) active: Option<ActiveSession>,
    closed: bool,
}

impl RemoteSessionCoordinator {
    /// Creates a direct-ICE Host session coordinator.
    ///
    /// # Errors
    ///
    /// Returns an authentication error if the local Host identity is invalid.
    pub fn new(
        service: Arc<HostService>,
        factory: Box<dyn RemoteSessionFactory>,
    ) -> Result<Self, RemoteSessionError> {
        Self::with_config(
            service,
            factory,
            SessionConfig::new(IceTransportPolicy::All),
        )
    }

    /// Creates a Host coordinator with an explicit ICE transport policy.
    ///
    /// # Errors
    ///
    /// Returns an authentication error if the local Host identity is invalid.
    pub fn with_config(
        service: Arc<HostService>,
        factory: Box<dyn RemoteSessionFactory>,
        config: SessionConfig,
    ) -> Result<Self, RemoteSessionError> {
        let verifier = OfferVerifier::new(service.device_identity().device_id.clone())
            .map_err(|_| RemoteSessionError::Authentication)?;
        Ok(Self {
            service,
            verifier,
            factory,
            config,
            pending: None,
            failed_attempt: None,
            active: None,
            closed: false,
        })
    }

    pub(crate) fn host_device_id(&self) -> &[u8] {
        &self.service.device_identity().device_id
    }

    pub(crate) fn subscribe_session_terminations(
        &self,
    ) -> tokio::sync::broadcast::Receiver<SessionTerminatedEvent> {
        self.service.subscribe_session_terminations()
    }

    /// Handles one opaque envelope routed by the signaling service.
    ///
    /// # Errors
    ///
    /// Returns a stable error for malformed, misrouted, over-limit, closed, or
    /// failed session processing. Expected busy responses are returned as
    /// sanitized outbound protocol errors.
    pub fn handle_routed(
        &mut self,
        routed_sender_device_id: &[u8],
        encoded: &[u8],
        now_unix_ms: u64,
    ) -> Result<Vec<RemoteSessionOutbound>, RemoteSessionError> {
        if self.closed {
            return Err(RemoteSessionError::Closed);
        }
        let envelope = decode_and_validate_signaling_envelope(encoded)
            .map_err(|_| RemoteSessionError::InvalidEnvelope)?;
        if envelope.sender_device_id != routed_sender_device_id
            || envelope.recipient_device_id != self.service.device_identity().device_id
        {
            return Err(RemoteSessionError::InvalidEnvelope);
        }
        self.expire_pending(now_unix_ms);
        self.expire_active_reconnect(now_unix_ms)?;
        let failed_session_id = match envelope.payload.as_ref() {
            Some(signaling_envelope::Payload::SessionAuthentication(authentication)) => {
                match authentication.payload.as_ref() {
                    Some(session_authentication::Payload::Offer(offer)) => {
                        Some(offer.session_id.as_slice())
                    }
                    _ => None,
                }
            }
            Some(signaling_envelope::Payload::WebrtcNegotiation(negotiation)) => {
                Some(negotiation.session_id.as_slice())
            }
            _ => None,
        };
        if failed_session_id.is_some_and(|session_id| {
            self.failed_attempt
                .as_ref()
                .is_some_and(|attempt| attempt.matches(&envelope.sender_device_id, session_id))
        }) {
            return Ok(Vec::new());
        }

        if let Some(active) = self.active.as_ref() {
            if active.controller_device_id != envelope.sender_device_id {
                return Ok(vec![self.error_outbound(
                    &envelope.sender_device_id,
                    &envelope.request_id,
                    ErrorCode::DeviceBusy,
                    now_unix_ms,
                )?]);
            }
            return self.handle_active_envelope(envelope, now_unix_ms);
        }

        self.handle_pending_envelope(envelope, now_unix_ms)
    }

    /// Applies a native peer event to the active authenticated session.
    ///
    /// # Errors
    ///
    /// Returns a stable state, peer, input, or service error.
    pub fn handle_peer_event(
        &mut self,
        event: RemotePeerEvent,
        now_unix_ms: u64,
    ) -> Result<Vec<RemoteSessionOutbound>, RemoteSessionError> {
        if self.closed {
            return Err(RemoteSessionError::Closed);
        }
        if self.expire_active_reconnect(now_unix_ms)? {
            return Ok(Vec::new());
        }
        match event {
            RemotePeerEvent::Connected => {
                let active = self.active.as_mut().ok_or(RemoteSessionError::Peer)?;
                active
                    .session
                    .mark_connected()
                    .map_err(|_| RemoteSessionError::Peer)?;
                active.reconnect = None;
                active.reconnect_deadline_unix_ms = None;
                self.service
                    .update_remote_status(
                        active.session_id.clone(),
                        active.controller_device_id.clone(),
                        SessionState::Connected,
                        None,
                    )
                    .map_err(|_| RemoteSessionError::Service)?;
                Ok(Vec::new())
            }
            RemotePeerEvent::LocalIceCandidate(candidate) => {
                let active = self.active.as_ref().ok_or(RemoteSessionError::Peer)?;
                let payload = signaling_envelope::Payload::WebrtcNegotiation(WebRtcNegotiation {
                    session_id: active.session_id.clone(),
                    payload: Some(web_rtc_negotiation::Payload::IceCandidate(
                        roammand_protocol::roammand::v1::IceCandidate {
                            candidate: candidate.candidate,
                            sdp_mid: candidate.sdp_mid,
                            sdp_m_line_index: candidate.sdp_m_line_index,
                        },
                    )),
                });
                Ok(vec![self.outbound(
                    &active.controller_device_id,
                    "host-ice",
                    now_unix_ms,
                    payload,
                )?])
            }
            RemotePeerEvent::ReliableInput(encoded) => {
                if self
                    .active
                    .as_ref()
                    .is_some_and(|active| active.reconnect_deadline_unix_ms.is_some())
                {
                    return Ok(Vec::new());
                }
                let active = self.active.as_mut().ok_or(RemoteSessionError::Input)?;
                let result = active.session.handle_reliable(&encoded);
                if let Err(error) = result {
                    debug_webrtc_failure("reliableInput", error);
                    self.close_active(
                        Some(session_error(ErrorCode::InputInjectionFailed)),
                        now_unix_ms,
                    )?;
                    return Err(RemoteSessionError::Input);
                }
                if active.session.state() == HostSessionState::Closed {
                    self.close_active(None, now_unix_ms)?;
                }
                Ok(Vec::new())
            }
            RemotePeerEvent::FastPointer(encoded) => {
                if self
                    .active
                    .as_ref()
                    .is_some_and(|active| active.reconnect_deadline_unix_ms.is_some())
                {
                    return Ok(Vec::new());
                }
                let result = self
                    .active
                    .as_mut()
                    .ok_or(RemoteSessionError::Input)?
                    .session
                    .handle_pointer_fast(&encoded);
                if result.is_err() {
                    self.close_active(
                        Some(session_error(ErrorCode::InputInjectionFailed)),
                        now_unix_ms,
                    )?;
                    return Err(RemoteSessionError::Input);
                }
                Ok(Vec::new())
            }
            RemotePeerEvent::Disconnected | RemotePeerEvent::Failed => {
                self.begin_active_reconnect(now_unix_ms)?;
                Ok(Vec::new())
            }
            RemotePeerEvent::LocalStop => {
                self.close_active_with_remote_notification(now_unix_ms, None)
            }
        }
    }

    /// Polls and applies at most one native peer event without blocking.
    ///
    /// # Errors
    ///
    /// Returns a stable peer or event-processing error.
    pub fn poll_peer_event(
        &mut self,
        now_unix_ms: u64,
    ) -> Result<Vec<RemoteSessionOutbound>, RemoteSessionError> {
        if self.expire_active_reconnect(now_unix_ms)? {
            return Ok(Vec::new());
        }
        let event = match self.active.as_ref() {
            Some(active) => active.events.try_recv()?,
            None => None,
        };
        event.map_or_else(
            || Ok(Vec::new()),
            |event| self.handle_peer_event(event, now_unix_ms),
        )
    }

    /// Drains a bounded batch without imposing one timer interval per input.
    ///
    /// # Errors
    ///
    /// Returns a stable peer or event-processing error. The time budget yields
    /// between events so signaling and local termination remain responsive.
    pub fn poll_peer_events(
        &mut self,
        now_unix_ms: u64,
    ) -> Result<Vec<RemoteSessionOutbound>, RemoteSessionError> {
        self.poll_peer_events_with_budget(now_unix_ms, std::time::Duration::from_millis(2))
    }

    pub(crate) fn poll_peer_events_with_budget(
        &mut self,
        now_unix_ms: u64,
        time_budget: std::time::Duration,
    ) -> Result<Vec<RemoteSessionOutbound>, RemoteSessionError> {
        const MAX_EVENTS: usize = 64;
        if self.expire_active_reconnect(now_unix_ms)? {
            return Ok(Vec::new());
        }
        let started = std::time::Instant::now();
        let mut outbound = Vec::new();
        for _ in 0..MAX_EVENTS {
            let Some(event) = self
                .active
                .as_ref()
                .map(|active| active.events.try_recv())
                .transpose()?
                .flatten()
            else {
                break;
            };
            outbound.extend(self.handle_peer_event(event, now_unix_ms)?);
            // Yield before any network send: a batch of ICE messages must not
            // multiply the transport timeout while local stops wait to run.
            if !outbound.is_empty() || started.elapsed() >= time_budget {
                break;
            }
        }
        Ok(outbound)
    }

    pub(crate) fn has_active_session(&self) -> bool {
        self.active.is_some()
    }

    pub(crate) fn reconnect_deadline_unix_ms(&self) -> Option<u64> {
        self.active
            .as_ref()
            .and_then(|active| active.reconnect_deadline_unix_ms)
    }

    /// Closes an active session after a trusted local termination request.
    ///
    /// # Errors
    ///
    /// Returns a stable cleanup or service error.
    pub fn handle_termination(
        &mut self,
        event: &SessionTerminatedEvent,
        now_unix_ms: u64,
    ) -> Result<Vec<RemoteSessionOutbound>, RemoteSessionError> {
        let matches = self.active.as_ref().is_some_and(|active| {
            active.session_id == event.session_id
                && active.controller_device_id == event.controller_device_id
        });
        if !matches {
            return Ok(Vec::new());
        }

        let final_error = match ErrorCode::try_from(event.reason) {
            Ok(ErrorCode::LocalEmergencyStop) => None,
            Ok(ErrorCode::Unspecified) | Err(_) => Some(session_error(ErrorCode::AuthRevoked)),
            Ok(reason) => Some(session_error(reason)),
        };
        self.close_active_with_remote_notification(now_unix_ms, final_error)
    }

    fn close_active_with_remote_notification(
        &mut self,
        now_unix_ms: u64,
        final_error: Option<UnifiedError>,
    ) -> Result<Vec<RemoteSessionOutbound>, RemoteSessionError> {
        let Some(active) = self.active.as_ref() else {
            return Ok(Vec::new());
        };
        let outbound = self.outbound(
            &active.controller_device_id,
            LOCAL_TERMINATION_REQUEST_ID,
            now_unix_ms,
            signaling_envelope::Payload::SessionStatus(
                roammand_protocol::roammand::v1::SessionStatus {
                    session_id: active.session_id.clone(),
                    state: SessionState::Closing as i32,
                    error: None,
                },
            ),
        )?;
        self.close_active(final_error, now_unix_ms)?;
        Ok(vec![outbound])
    }

    /// Suspends input and starts the bounded retained-session reconnect window.
    ///
    /// # Errors
    ///
    /// Returns a stable cleanup or service error.
    pub fn signaling_lost(&mut self, now_unix_ms: u64) -> Result<(), RemoteSessionError> {
        self.pending = None;
        if self.active.is_some()
            && let Err(reconnect_error) = self.begin_active_reconnect(now_unix_ms)
        {
            // A failed bridge/input operation can make the retained peer
            // unusable. Remove it before the signaling runtime retries so
            // a later connection is not rejected as device-busy.
            let close_result =
                self.close_active(Some(session_error(ErrorCode::IceFailed)), now_unix_ms);
            return match close_result {
                Ok(()) => Err(reconnect_error),
                Err(close_error) => Err(close_error),
            };
        }
        Ok(())
    }

    /// Freezes active input and opens the authenticated reconnect window after
    /// the privileged broker publishes a new graphical-session generation.
    ///
    /// # Errors
    ///
    /// Returns a stable peer or service error when the active session cannot
    /// enter fail-closed reconnect state.
    pub fn privileged_route_changed(&mut self, now_unix_ms: u64) -> Result<(), RemoteSessionError> {
        if self.active.is_some() {
            self.begin_active_reconnect(now_unix_ms)?;
        }
        Ok(())
    }

    /// Deterministically releases all active resources and closes the coordinator.
    ///
    /// # Errors
    ///
    /// Returns the first stable cleanup or service error.
    pub fn shutdown(&mut self) -> Result<(), RemoteSessionError> {
        self.pending = None;
        self.failed_attempt = None;
        self.close_active(None, 0)?;
        self.closed = true;
        Ok(())
    }

    fn handle_pending_envelope(
        &mut self,
        envelope: SignalingEnvelope,
        now_unix_ms: u64,
    ) -> Result<Vec<RemoteSessionOutbound>, RemoteSessionError> {
        let sender = envelope.sender_device_id.clone();
        let request_id = envelope.request_id.clone();
        let payload = envelope
            .payload
            .ok_or(RemoteSessionError::InvalidEnvelope)?;
        if let signaling_envelope::Payload::SessionStatus(status) = &payload {
            if SessionState::try_from(status.state) != Ok(SessionState::Closing) {
                return Err(RemoteSessionError::InvalidEnvelope);
            }
            if self.pending.as_ref().is_some_and(|pending| {
                pending.controller_device_id == sender && pending.session_id == status.session_id
            }) {
                self.pending = None;
            }
            return Ok(Vec::new());
        }
        let session_id = match &payload {
            signaling_envelope::Payload::SessionAuthentication(authentication) => {
                let Some(session_authentication::Payload::Offer(offer)) =
                    authentication.payload.as_ref()
                else {
                    return Err(RemoteSessionError::InvalidEnvelope);
                };
                offer.session_id.clone()
            }
            signaling_envelope::Payload::WebrtcNegotiation(negotiation) => {
                negotiation.session_id.clone()
            }
            _ => return Err(RemoteSessionError::InvalidEnvelope),
        };
        if !self.prepare_pending(&sender, &session_id, &request_id, now_unix_ms) {
            return Ok(vec![self.error_outbound(
                &sender,
                &request_id,
                ErrorCode::DeviceBusy,
                now_unix_ms,
            )?]);
        }
        let pending = self.pending.as_mut().ok_or(RemoteSessionError::Service)?;
        match payload {
            signaling_envelope::Payload::SessionAuthentication(authentication) => {
                let Some(session_authentication::Payload::Offer(offer)) = authentication.payload
                else {
                    return Err(RemoteSessionError::InvalidEnvelope);
                };
                if pending.authentication.replace(offer).is_some() {
                    return Err(RemoteSessionError::InvalidEnvelope);
                }
            }
            signaling_envelope::Payload::WebrtcNegotiation(negotiation) => {
                match negotiation
                    .payload
                    .ok_or(RemoteSessionError::InvalidEnvelope)?
                {
                    web_rtc_negotiation::Payload::Description(description) => {
                        if SessionDescriptionType::try_from(description.r#type)
                            != Ok(SessionDescriptionType::Offer)
                            || pending.description.replace(description).is_some()
                        {
                            return Err(RemoteSessionError::InvalidEnvelope);
                        }
                    }
                    web_rtc_negotiation::Payload::IceCandidate(candidate) => {
                        pending.push_candidate(PeerIceCandidate {
                            candidate: candidate.candidate,
                            sdp_mid: candidate.sdp_mid,
                            sdp_m_line_index: candidate.sdp_m_line_index,
                        })?;
                    }
                    web_rtc_negotiation::Payload::EndOfCandidates(_) => {}
                }
            }
            _ => return Err(RemoteSessionError::InvalidEnvelope),
        }
        self.try_start_pending(now_unix_ms)
    }

    fn handle_active_envelope(
        &mut self,
        envelope: SignalingEnvelope,
        now_unix_ms: u64,
    ) -> Result<Vec<RemoteSessionOutbound>, RemoteSessionError> {
        match envelope.payload.as_ref() {
            Some(
                signaling_envelope::Payload::SessionAuthentication(_)
                | signaling_envelope::Payload::WebrtcNegotiation(_),
            ) => self.handle_active_reconnect_envelope(envelope, now_unix_ms),
            Some(signaling_envelope::Payload::SessionStatus(status)) => {
                if SessionState::try_from(status.state) != Ok(SessionState::Closing) {
                    return Err(RemoteSessionError::InvalidEnvelope);
                }
                let active = self.active.as_ref().ok_or(RemoteSessionError::Peer)?;
                if status.session_id != active.session_id {
                    return Err(RemoteSessionError::InvalidEnvelope);
                }
                self.close_active(None, now_unix_ms)?;
                Ok(Vec::new())
            }
            _ => Err(RemoteSessionError::InvalidEnvelope),
        }
    }

    fn try_start_pending(
        &mut self,
        now_unix_ms: u64,
    ) -> Result<Vec<RemoteSessionOutbound>, RemoteSessionError> {
        let ready = self.pending.as_ref().is_some_and(PendingSession::is_ready);
        if !ready {
            return Ok(Vec::new());
        }
        let pending = self.pending.take().ok_or(RemoteSessionError::Service)?;
        let context = (
            pending.controller_device_id.clone(),
            pending.session_id.clone(),
            pending.request_id.clone(),
        );
        match self.start_pending(pending, now_unix_ms) {
            Ok(outbound) => Ok(outbound),
            Err(error) => {
                debug_remote_failure("startPending", error);
                self.failed_attempt = Some(FailedSessionAttempt::new(
                    context.0.clone(),
                    context.1.clone(),
                    now_unix_ms,
                ));
                let protocol_error = protocol_error_for(error);
                let _ = self.service.update_remote_status(
                    context.1,
                    context.0.clone(),
                    SessionState::Failed,
                    Some(session_error(protocol_error)),
                );
                Ok(vec![self.error_outbound(
                    &context.0,
                    &context.2,
                    protocol_error,
                    now_unix_ms,
                )?])
            }
        }
    }

    fn start_pending(
        &mut self,
        pending: PendingSession,
        now_unix_ms: u64,
    ) -> Result<Vec<RemoteSessionOutbound>, RemoteSessionError> {
        let authentication = pending
            .authentication
            .ok_or(RemoteSessionError::InvalidEnvelope)?;
        let description = pending
            .description
            .ok_or(RemoteSessionError::InvalidEnvelope)?;
        self.service
            .update_remote_status(
                pending.session_id.clone(),
                pending.controller_device_id.clone(),
                SessionState::Authenticating,
                None,
            )
            .map_err(|_| RemoteSessionError::Service)?;
        let verified = self
            .service
            .verify_remote_offer(
                &mut self.verifier,
                &authentication,
                &description.sdp,
                &description.dtls_fingerprint_sha256,
                now_unix_ms,
            )
            .map_err(map_service_error)?;
        if verified.controller.device_id != pending.controller_device_id
            || verified.session_id != pending.session_id
        {
            return Err(RemoteSessionError::Authentication);
        }

        let started = self.activate_verified_session(
            &authentication,
            &description,
            &pending.candidates,
            verified,
            now_unix_ms,
        )?;
        let authentication_payload =
            signaling_envelope::Payload::SessionAuthentication(SessionAuthentication {
                payload: Some(session_authentication::Payload::Answer(
                    started.answer_authentication,
                )),
            });
        let description_payload =
            signaling_envelope::Payload::WebrtcNegotiation(WebRtcNegotiation {
                session_id: started.session_id,
                payload: Some(web_rtc_negotiation::Payload::Description(
                    WebRtcSessionDescription {
                        r#type: SessionDescriptionType::Answer as i32,
                        sdp: started.answer.sdp,
                        dtls_fingerprint_sha256: started.answer.dtls_fingerprint_sha256,
                    },
                )),
            });
        Ok(vec![
            self.outbound(
                &started.controller_device_id,
                &pending.request_id,
                now_unix_ms,
                authentication_payload,
            )?,
            self.outbound(
                &started.controller_device_id,
                &pending.request_id,
                now_unix_ms,
                description_payload,
            )?,
        ])
    }

    fn activate_verified_session(
        &mut self,
        authentication: &SessionOfferAuthentication,
        description: &WebRtcSessionDescription,
        candidates: &[PeerIceCandidate],
        verified: VerifiedSessionOffer,
        now_unix_ms: u64,
    ) -> Result<StartedSession, RemoteSessionError> {
        let RemoteSessionParts {
            peer,
            input,
            events,
        } = self.factory.create(
            &self.config,
            &RemoteSessionContext::from_verified(&verified),
        )?;
        let mut session = HostPeerSession::new(
            verified.session_id.clone(),
            &verified.permissions,
            self.config.clone(),
            peer,
            input,
        )
        .map_err(map_peer_error)?;
        let answer = match session.accept_offer(&description.sdp) {
            Ok(answer) => answer,
            Err(error) => {
                debug_webrtc_failure("acceptOffer", error);
                let _ = session.close();
                return Err(map_peer_error(error));
            }
        };
        let answer_authentication = match self.service.sign_remote_answer(
            authentication,
            &answer.sdp,
            &answer.dtls_fingerprint_sha256,
        ) {
            Ok(authentication) => authentication,
            Err(error) => {
                let _ = session.close();
                return Err(map_service_error(error));
            }
        };
        if self
            .service
            .register_active_session(
                verified.session_id.clone(),
                verified.controller.device_id.clone(),
            )
            .is_err()
        {
            let _ = session.close();
            return Err(RemoteSessionError::Service);
        }
        if let Err(error) = self
            .service
            .record_authenticated_remote_session(&verified.controller.device_id, now_unix_ms)
        {
            let _ = self.service.unregister_active_session(&verified.session_id);
            let _ = session.close();
            return Err(map_service_error(error));
        }
        for candidate in candidates {
            if session.add_remote_ice_candidate(candidate).is_err() {
                let _ = self.service.unregister_active_session(&verified.session_id);
                let _ = session.close();
                return Err(RemoteSessionError::Peer);
            }
        }

        let controller_device_id = verified.controller.device_id;
        let session_id = verified.session_id;
        if self
            .service
            .update_remote_status(
                session_id.clone(),
                controller_device_id.clone(),
                SessionState::Connecting,
                None,
            )
            .is_err()
        {
            let _ = self.service.unregister_active_session(&session_id);
            let _ = session.close();
            return Err(RemoteSessionError::Service);
        }
        self.active = Some(ActiveSession {
            controller_device_id: controller_device_id.clone(),
            session_id: session_id.clone(),
            session,
            events,
            reconnect: None,
            reconnect_generation: 0,
            reconnect_deadline_unix_ms: None,
        });
        Ok(StartedSession {
            controller_device_id,
            session_id,
            answer,
            answer_authentication,
        })
    }

    fn prepare_pending(
        &mut self,
        controller_device_id: &[u8],
        session_id: &[u8],
        request_id: &str,
        now_unix_ms: u64,
    ) -> bool {
        match self.pending.as_mut() {
            Some(pending)
                if pending.controller_device_id == controller_device_id
                    && pending.session_id == session_id =>
            {
                pending.request_id.clone_from(&request_id.to_owned());
                true
            }
            Some(_) => false,
            None => {
                self.pending = Some(PendingSession::new(
                    controller_device_id.to_vec(),
                    session_id.to_vec(),
                    request_id.to_owned(),
                    now_unix_ms,
                ));
                true
            }
        }
    }

    fn expire_pending(&mut self, now_unix_ms: u64) {
        if self.pending.as_ref().is_some_and(|pending| {
            now_unix_ms.saturating_sub(pending.created_at_unix_ms) > PENDING_SESSION_LIFETIME_MS
        }) {
            self.pending = None;
        }
        if self
            .failed_attempt
            .as_ref()
            .is_some_and(|attempt| attempt.is_expired(now_unix_ms))
        {
            self.failed_attempt = None;
        }
    }

    pub(super) fn close_active(
        &mut self,
        final_error: Option<UnifiedError>,
        _now_unix_ms: u64,
    ) -> Result<(), RemoteSessionError> {
        let Some(mut active) = self.active.take() else {
            if final_error.is_none() {
                self.service
                    .update_remote_status(Vec::new(), Vec::new(), SessionState::Idle, None)
                    .map_err(|_| RemoteSessionError::Service)?;
            }
            return Ok(());
        };
        let _ = self.service.update_remote_status(
            active.session_id.clone(),
            active.controller_device_id.clone(),
            SessionState::Closing,
            None,
        );
        let close_result = active.session.close().map_err(map_peer_error);
        let unregister_result = self
            .service
            .unregister_active_session(&active.session_id)
            .map_err(|_| RemoteSessionError::Service);
        let status_result = if let Some(error) = final_error {
            self.service.update_remote_status(
                active.session_id,
                active.controller_device_id,
                SessionState::Failed,
                Some(error),
            )
        } else {
            self.service
                .update_remote_status(Vec::new(), Vec::new(), SessionState::Idle, None)
        }
        .map_err(|_| RemoteSessionError::Service);
        close_result.and(unregister_result).and(status_result)
    }

    pub(super) fn outbound(
        &self,
        recipient_device_id: &[u8],
        request_id: &str,
        now_unix_ms: u64,
        payload: signaling_envelope::Payload,
    ) -> Result<RemoteSessionOutbound, RemoteSessionError> {
        let envelope = SignalingEnvelope {
            protocol_version: Some(protocol_version()),
            sender_device_id: self.service.device_identity().device_id.clone(),
            recipient_device_id: recipient_device_id.to_vec(),
            request_id: request_id.to_owned(),
            sent_at_unix_ms: now_unix_ms,
            payload: Some(payload),
        };
        let opaque_envelope = envelope.encode_to_vec();
        if opaque_envelope.len() > MAX_OPAQUE_SIGNALING_ENVELOPE_BYTES {
            return Err(RemoteSessionError::InvalidEnvelope);
        }
        Ok(RemoteSessionOutbound {
            recipient_device_id: recipient_device_id.to_vec(),
            opaque_envelope,
        })
    }

    pub(super) fn error_outbound(
        &self,
        recipient_device_id: &[u8],
        request_id: &str,
        code: ErrorCode,
        now_unix_ms: u64,
    ) -> Result<RemoteSessionOutbound, RemoteSessionError> {
        self.outbound(
            recipient_device_id,
            request_id,
            now_unix_ms,
            signaling_envelope::Payload::Error(UnifiedError {
                code: code as i32,
                message_key: message_key(code).to_owned(),
                retryable: matches!(code, ErrorCode::DeviceBusy | ErrorCode::ServerUnavailable),
                request_id: request_id.to_owned(),
                details: None,
            }),
        )
    }
}

impl fmt::Debug for RemoteSessionCoordinator {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RemoteSessionCoordinator")
            .field("has_pending", &self.pending.is_some())
            .field("has_active", &self.active.is_some())
            .field("closed", &self.closed)
            .finish_non_exhaustive()
    }
}

impl Drop for RemoteSessionCoordinator {
    fn drop(&mut self) {
        self.pending = None;
        self.failed_attempt = None;
        let _ = self.close_active(None, 0);
    }
}

fn protocol_version() -> ProtocolVersion {
    ProtocolVersion {
        major: 1,
        minor: MINIMUM_PROTOCOL_MINOR_VERSION,
    }
}

pub(super) fn session_error(code: ErrorCode) -> UnifiedError {
    UnifiedError {
        code: code as i32,
        message_key: message_key(code).to_owned(),
        retryable: matches!(code, ErrorCode::DeviceBusy | ErrorCode::ServerUnavailable),
        request_id: String::new(),
        details: None,
    }
}

const fn message_key(code: ErrorCode) -> &'static str {
    match code {
        ErrorCode::DeviceBusy => "remote_session.device_busy",
        ErrorCode::AuthInvalid => "remote_session.authentication_failed",
        ErrorCode::AuthRevoked => "remote_session.authorization_revoked",
        ErrorCode::SessionReplayed => "remote_session.replayed",
        ErrorCode::IceFailed => "remote_session.ice_failed",
        ErrorCode::InputInjectionFailed => "remote_session.input_failed",
        ErrorCode::ServerUnavailable => "remote_session.temporarily_unavailable",
        _ => "remote_session.failed",
    }
}

pub(super) const fn protocol_error_for(error: RemoteSessionError) -> ErrorCode {
    match error {
        RemoteSessionError::DeviceBusy => ErrorCode::DeviceBusy,
        RemoteSessionError::Authentication => ErrorCode::AuthInvalid,
        RemoteSessionError::Authorization => ErrorCode::AuthRevoked,
        RemoteSessionError::Replay => ErrorCode::SessionReplayed,
        RemoteSessionError::PendingIceLimit | RemoteSessionError::InvalidEnvelope => {
            ErrorCode::InvalidRequest
        }
        RemoteSessionError::Input => ErrorCode::InputInjectionFailed,
        RemoteSessionError::InputPermission => ErrorCode::InputPermissionRequired,
        RemoteSessionError::Peer => ErrorCode::CaptureFailed,
        RemoteSessionError::Service | RemoteSessionError::Closed => ErrorCode::ServerUnavailable,
    }
}

pub(super) const fn map_service_error(error: RemoteServiceError) -> RemoteSessionError {
    match error {
        RemoteServiceError::Authentication(crate::SessionAuthenticationError::Replay) => {
            RemoteSessionError::Replay
        }
        RemoteServiceError::Authentication(
            crate::SessionAuthenticationError::ControllerNotAuthorized
            | crate::SessionAuthenticationError::PermissionDenied,
        ) => RemoteSessionError::Authorization,
        RemoteServiceError::Authentication(_) => RemoteSessionError::Authentication,
        RemoteServiceError::Authorization
        | RemoteServiceError::Identity
        | RemoteServiceError::Session
        | RemoteServiceError::InvalidStatus
        | RemoteServiceError::Unavailable => RemoteSessionError::Service,
    }
}

pub(super) const fn map_peer_error(error: HostWebRtcError) -> RemoteSessionError {
    match error {
        HostWebRtcError::InputPermissionDenied => RemoteSessionError::InputPermission,
        HostWebRtcError::InputFailure => RemoteSessionError::Input,
        _ => RemoteSessionError::Peer,
    }
}

fn debug_remote_failure(operation: &str, error: RemoteSessionError) {
    #[cfg(debug_assertions)]
    eprintln!("[remote] host_operation={operation} cause={error:?}");
    #[cfg(not(debug_assertions))]
    let _ = (operation, error);
}

fn debug_webrtc_failure(operation: &str, error: HostWebRtcError) {
    #[cfg(debug_assertions)]
    eprintln!("[remote] host_operation={operation} cause={error:?}");
    #[cfg(not(debug_assertions))]
    let _ = (operation, error);
}
