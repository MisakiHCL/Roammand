// SPDX-License-Identifier: MPL-2.0

use roammand_host_webrtc::PeerAnswer;
use roammand_protocol::roammand::v1::{
    IceCandidate, PrivilegedBridgeClientFrame, PrivilegedBridgeServerFrame,
    PrivilegedCommandAccepted, PrivilegedFastPointerEvent, PrivilegedInputCommand,
    PrivilegedLocalIceCandidate, PrivilegedPeerAnswer, PrivilegedPeerConfiguration,
    PrivilegedPeerState, PrivilegedPeerStateChanged, PrivilegedReliableInputEvent, ProtocolVersion,
    WebRtcSessionDescription, privileged_bridge_client_frame, privileged_bridge_server_frame,
};
use thiserror::Error;

use crate::{
    lease::LeaseId,
    proxy::{ProxyEvent, ProxyRoute},
};

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum HelperError {
    #[error("session helper has no current lease")]
    LeaseRequired,
    #[error("session helper route is stale")]
    StaleRoute,
}

#[derive(Debug, Default)]
pub struct HelperLeaseGate {
    route: Option<ProxyRoute>,
}

impl HelperLeaseGate {
    #[must_use]
    pub const fn new() -> Self {
        Self { route: None }
    }

    /// Attaches the exact broker-issued route before native peer creation.
    ///
    /// # Errors
    ///
    /// Rejects zero generation and stale/repeated route installation.
    pub fn attach(&mut self, route: ProxyRoute) -> Result<(), HelperError> {
        if route.generation == 0
            || self
                .route
                .is_some_and(|current| route.generation <= current.generation)
        {
            return Err(HelperError::StaleRoute);
        }
        self.route = Some(route);
        Ok(())
    }

    /// Authorizes one helper operation against the exact current route.
    ///
    /// # Errors
    ///
    /// Rejects missing, mismatched, or stale leases.
    pub fn authorize(&self, lease_id: LeaseId, generation: u64) -> Result<(), HelperError> {
        match self.route {
            None => Err(HelperError::LeaseRequired),
            Some(route) if route.lease_id == lease_id && route.generation == generation => Ok(()),
            Some(_) => Err(HelperError::StaleRoute),
        }
    }

    #[must_use]
    pub fn release(&mut self) -> bool {
        self.route.take().is_some()
    }

    #[must_use]
    pub const fn current(&self) -> Option<ProxyRoute> {
        self.route
    }
}

pub trait HelperBackend: Send {
    /// Creates the native peer on the Helper's assigned graphical desktop.
    ///
    /// # Errors
    ///
    /// Returns a stable backend failure without exposing negotiation data.
    fn start(
        &mut self,
        configuration: &PrivilegedPeerConfiguration,
        offer: &WebRtcSessionDescription,
        controller_display_name: &str,
    ) -> Result<PeerAnswer, HelperProtocolError>;

    /// Restarts the native peer on a strictly newer authenticated route.
    ///
    /// # Errors
    ///
    /// Returns a stable backend failure.
    fn restart(
        &mut self,
        configuration: &PrivilegedPeerConfiguration,
        offer: &WebRtcSessionDescription,
        controller_display_name: &str,
    ) -> Result<PeerAnswer, HelperProtocolError>;

    /// Adds one bounded ICE candidate.
    ///
    /// # Errors
    ///
    /// Returns a stable backend failure.
    fn add_candidate(&mut self, candidate: &IceCandidate) -> Result<(), HelperProtocolError>;

    /// Applies one broker-authorized typed input command.
    ///
    /// # Errors
    ///
    /// Returns a stable backend failure.
    fn input(&mut self, input: &PrivilegedInputCommand) -> Result<(), HelperProtocolError>;

    /// Invokes the dedicated platform secure-attention operation.
    ///
    /// # Errors
    ///
    /// Returns a stable backend failure if unsupported or denied.
    fn secure_attention(&mut self) -> Result<(), HelperProtocolError>;

    /// Closes peer and input resources idempotently.
    ///
    /// # Errors
    ///
    /// Returns a stable backend failure.
    fn close(&mut self) -> Result<(), HelperProtocolError>;

    /// Polls one native peer event without blocking.
    ///
    /// # Errors
    ///
    /// Returns a stable backend failure on queue loss.
    fn try_event(&mut self) -> Result<Option<ProxyEvent>, HelperProtocolError>;

    fn fail_closed(&mut self);
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum HelperProtocolError {
    #[error("Helper message is invalid")]
    InvalidMessage,
    #[error("Helper route is stale")]
    StaleRoute,
    #[error("Helper native backend failed")]
    Backend,
    #[error("Helper event sequence overflowed")]
    SequenceOverflow,
}

pub struct HelperProtocol {
    gate: HelperLeaseGate,
    backend: Box<dyn HelperBackend>,
    next_event_sequence: u64,
    failed: bool,
}

impl HelperProtocol {
    #[must_use]
    pub fn new(backend: Box<dyn HelperBackend>) -> Self {
        Self {
            gate: HelperLeaseGate::new(),
            backend,
            next_event_sequence: 1,
            failed: false,
        }
    }

    /// Executes one broker-authenticated, route-bound typed command.
    ///
    /// # Errors
    ///
    /// Rejects missing/stale routes, unsupported messages, and native failures.
    pub fn handle(
        &mut self,
        request: &PrivilegedBridgeClientFrame,
    ) -> Result<PrivilegedBridgeServerFrame, HelperProtocolError> {
        if self.failed {
            return Err(HelperProtocolError::Backend);
        }
        let result = self.handle_inner(request);
        if matches!(result, Err(HelperProtocolError::Backend)) {
            self.fail_closed();
        }
        result
    }

    /// Polls and route-binds one native event.
    ///
    /// # Errors
    ///
    /// Rejects events without an active route and sequence overflow. Backend
    /// failures release the active lease and native resources before returning.
    pub fn try_event(
        &mut self,
    ) -> Result<Option<PrivilegedBridgeServerFrame>, HelperProtocolError> {
        if self.failed {
            return Err(HelperProtocolError::Backend);
        }
        let event = match self.backend.try_event() {
            Ok(event) => event,
            Err(error) => {
                self.fail_closed();
                return Err(error);
            }
        };
        let Some(event) = event else {
            return Ok(None);
        };
        let route = self.gate.current().ok_or(HelperProtocolError::StaleRoute)?;
        let sequence = self.next_event_sequence;
        self.next_event_sequence = sequence
            .checked_add(1)
            .ok_or(HelperProtocolError::SequenceOverflow)?;
        Ok(Some(event_frame(route, sequence, event)))
    }

    pub fn shutdown(&mut self) {
        self.fail_closed();
    }

    fn handle_inner(
        &mut self,
        request: &PrivilegedBridgeClientFrame,
    ) -> Result<PrivilegedBridgeServerFrame, HelperProtocolError> {
        let payload = request
            .payload
            .as_ref()
            .ok_or(HelperProtocolError::InvalidMessage)?;
        match payload {
            privileged_bridge_client_frame::Payload::StartPeer(value) => {
                let route = parse_route(&value.lease_id, value.generation)?;
                self.attach_or_authorize(route)?;
                let answer = self.backend.start(
                    value
                        .configuration
                        .as_ref()
                        .ok_or(HelperProtocolError::InvalidMessage)?,
                    value
                        .offer
                        .as_ref()
                        .ok_or(HelperProtocolError::InvalidMessage)?,
                    &value.controller_display_name,
                )?;
                Ok(answer_response(request, route, answer))
            }
            privileged_bridge_client_frame::Payload::RestartPeer(value) => {
                let route = parse_route(&value.lease_id, value.generation)?;
                self.attach_or_authorize(route)?;
                let answer = self.backend.restart(
                    value
                        .configuration
                        .as_ref()
                        .ok_or(HelperProtocolError::InvalidMessage)?,
                    value
                        .offer
                        .as_ref()
                        .ok_or(HelperProtocolError::InvalidMessage)?,
                    &value.controller_display_name,
                )?;
                Ok(answer_response(request, route, answer))
            }
            privileged_bridge_client_frame::Payload::AddIceCandidate(value) => {
                let route = self.authorize(&value.lease_id, value.generation)?;
                self.backend.add_candidate(
                    value
                        .candidate
                        .as_ref()
                        .ok_or(HelperProtocolError::InvalidMessage)?,
                )?;
                Ok(accepted_response(request, route))
            }
            privileged_bridge_client_frame::Payload::InputCommand(value) => {
                let route = self.authorize(&value.lease_id, value.generation)?;
                self.backend.input(value)?;
                Ok(accepted_response(request, route))
            }
            privileged_bridge_client_frame::Payload::SendSecureAttention(value) => {
                let route = self.authorize(&value.lease_id, value.generation)?;
                self.backend.secure_attention()?;
                Ok(accepted_response(request, route))
            }
            privileged_bridge_client_frame::Payload::ClosePeer(value) => {
                let route = self.authorize(&value.lease_id, value.generation)?;
                self.backend.close()?;
                Ok(accepted_response(request, route))
            }
            privileged_bridge_client_frame::Payload::ReleaseLease(value) => {
                let route = self.authorize(&value.lease_id, value.generation)?;
                self.backend.close()?;
                let _ = self.gate.release();
                Ok(accepted_response(request, route))
            }
            privileged_bridge_client_frame::Payload::Authenticate(_)
            | privileged_bridge_client_frame::Payload::RegisterHelper(_)
            | privileged_bridge_client_frame::Payload::AcquireLease(_)
            | privileged_bridge_client_frame::Payload::RenewLease(_) => {
                Err(HelperProtocolError::InvalidMessage)
            }
        }
    }

    fn attach_or_authorize(&mut self, route: ProxyRoute) -> Result<(), HelperProtocolError> {
        match self.gate.current() {
            Some(current) if current == route => Ok(()),
            Some(_) | None => self
                .gate
                .attach(route)
                .map_err(|_| HelperProtocolError::StaleRoute),
        }
    }

    fn authorize(
        &self,
        lease_id: &[u8],
        generation: u64,
    ) -> Result<ProxyRoute, HelperProtocolError> {
        let route = parse_route(lease_id, generation)?;
        self.gate
            .authorize(route.lease_id, route.generation)
            .map_err(|_| HelperProtocolError::StaleRoute)?;
        Ok(route)
    }

    fn fail_closed(&mut self) {
        if !self.failed {
            self.failed = true;
            let _ = self.gate.release();
            self.backend.fail_closed();
        }
    }
}

fn parse_route(lease_id: &[u8], generation: u64) -> Result<ProxyRoute, HelperProtocolError> {
    let lease_id: [u8; 16] = lease_id
        .try_into()
        .map_err(|_| HelperProtocolError::InvalidMessage)?;
    if generation == 0 {
        return Err(HelperProtocolError::InvalidMessage);
    }
    Ok(ProxyRoute::new(LeaseId::new(lease_id), generation))
}

fn accepted_response(
    request: &PrivilegedBridgeClientFrame,
    route: ProxyRoute,
) -> PrivilegedBridgeServerFrame {
    response_frame(
        request,
        privileged_bridge_server_frame::Payload::CommandAccepted(PrivilegedCommandAccepted {
            lease_id: route.lease_id.into_bytes().to_vec(),
            generation: route.generation,
        }),
    )
}

fn answer_response(
    request: &PrivilegedBridgeClientFrame,
    route: ProxyRoute,
    answer: PeerAnswer,
) -> PrivilegedBridgeServerFrame {
    response_frame(
        request,
        privileged_bridge_server_frame::Payload::PeerAnswer(PrivilegedPeerAnswer {
            lease_id: route.lease_id.into_bytes().to_vec(),
            generation: route.generation,
            answer: Some(WebRtcSessionDescription {
                r#type: roammand_protocol::roammand::v1::SessionDescriptionType::Answer as i32,
                sdp: answer.sdp,
                dtls_fingerprint_sha256: answer.dtls_fingerprint_sha256,
            }),
        }),
    )
}

fn response_frame(
    request: &PrivilegedBridgeClientFrame,
    payload: privileged_bridge_server_frame::Payload,
) -> PrivilegedBridgeServerFrame {
    PrivilegedBridgeServerFrame {
        protocol_version: Some(ProtocolVersion { major: 1, minor: 0 }),
        request_id: request.request_id.clone(),
        sequence: request.sequence,
        payload: Some(payload),
    }
}

fn event_frame(route: ProxyRoute, sequence: u64, event: ProxyEvent) -> PrivilegedBridgeServerFrame {
    let payload = match event {
        ProxyEvent::Connected => state_event(route, PrivilegedPeerState::Connected),
        ProxyEvent::Disconnected => state_event(route, PrivilegedPeerState::Disconnected),
        ProxyEvent::Failed => state_event(route, PrivilegedPeerState::Failed),
        ProxyEvent::LocalStop => state_event(route, PrivilegedPeerState::Closed),
        ProxyEvent::LocalIceCandidate(candidate) => {
            privileged_bridge_server_frame::Payload::LocalIceCandidate(
                PrivilegedLocalIceCandidate {
                    lease_id: route.lease_id.into_bytes().to_vec(),
                    generation: route.generation,
                    candidate: Some(IceCandidate {
                        candidate: candidate.candidate,
                        sdp_mid: candidate.sdp_mid,
                        sdp_m_line_index: candidate.sdp_m_line_index,
                    }),
                },
            )
        }
        ProxyEvent::ReliableInput(encoded_envelope) => {
            privileged_bridge_server_frame::Payload::ReliableInput(PrivilegedReliableInputEvent {
                lease_id: route.lease_id.into_bytes().to_vec(),
                generation: route.generation,
                encoded_envelope,
            })
        }
        ProxyEvent::FastPointer(encoded_envelope) => {
            privileged_bridge_server_frame::Payload::FastPointer(PrivilegedFastPointerEvent {
                lease_id: route.lease_id.into_bytes().to_vec(),
                generation: route.generation,
                encoded_envelope,
            })
        }
    };
    PrivilegedBridgeServerFrame {
        protocol_version: Some(ProtocolVersion { major: 1, minor: 0 }),
        request_id: format!("event-{sequence}"),
        sequence,
        payload: Some(payload),
    }
}

fn state_event(
    route: ProxyRoute,
    state: PrivilegedPeerState,
) -> privileged_bridge_server_frame::Payload {
    privileged_bridge_server_frame::Payload::PeerStateChanged(PrivilegedPeerStateChanged {
        lease_id: route.lease_id.into_bytes().to_vec(),
        generation: route.generation,
        state: state as i32,
    })
}
