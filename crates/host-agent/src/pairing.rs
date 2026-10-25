// SPDX-License-Identifier: MPL-2.0

use std::{collections::VecDeque, fmt};

use roammand_protocol::{
    identity_derivation::derive_device_id_v1,
    pairing_crypto::x25519_public_key,
    protocol_limits::{PAIRING_RENDEZVOUS_LIFETIME_MS, PROTOCOL_MAJOR_VERSION},
    roammand::v1::{
        ControllerGrant, DeviceIdentity, DevicePlatform, ErrorCode, HostPairingInvitation,
        HostPairingProof, HostPairingState, HostPairingStatusSnapshot, PairingConfirmationData,
        PairingDecisionStatus, PairingFinalDecision, PairingIdentityRole, PairingInvitationKind,
        PairingPlaintext, PairingRendezvousCompletion, PairingRendezvousKind, ProtocolVersion,
        SessionPermission, UnifiedError, pairing_message, pairing_plaintext,
    },
    validation::validate_device_identity,
};
use thiserror::Error;
use zeroize::Zeroizing;

use crate::{
    AuthorizationError, AuthorizationRegistry, HostIdentity, SignalingEvent,
    pairing_crypto::{
        HostPairingCryptoError, VerifiedControllerHello, decode_pairing_message,
        encode_pairing_payload, open_controller_plaintext, pairing_sas_words,
        public_key_fingerprint, seal_host_plaintext, verify_controller_hello,
    },
    signaling::validate_signaling_endpoint,
};

const RENDEZVOUS_BYTES: usize = 16;
const EPHEMERAL_PRIVATE_KEY_BYTES: usize = 32;
const DESKTOP_CODE_RANDOM_BYTES: usize = 5;
const BASE32_ALPHABET: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const VIEW_AND_CONTROL_PERMISSIONS: &[SessionPermission] = &[
    SessionPermission::ViewScreen,
    SessionPermission::ControlInput,
];

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PairingRandomError {
    #[error("secure pairing randomness is unavailable")]
    Unavailable,
}

pub trait PairingRandom: Send {
    /// Fills one pairing secret or identifier with secure random bytes.
    ///
    /// # Errors
    ///
    /// Returns an error when the platform random source is unavailable.
    fn fill(&mut self, output: &mut [u8]) -> Result<(), PairingRandomError>;
}

struct SystemPairingRandom;

impl PairingRandom for SystemPairingRandom {
    fn fill(&mut self, output: &mut [u8]) -> Result<(), PairingRandomError> {
        getrandom::fill(output).map_err(|_| PairingRandomError::Unavailable)
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PairingCoordinatorError {
    #[error("Host pairing state is invalid")]
    InvalidState,
    #[error("Host pairing input is invalid")]
    InvalidInput,
    #[error("Host pairing has expired")]
    Expired,
    #[error("Host pairing authentication failed")]
    Authentication,
    #[error("Host pairing authorization failed")]
    Authorization(AuthorizationError),
    #[error("Host pairing randomness failed")]
    Random(PairingRandomError),
}

#[derive(Clone, Eq, PartialEq)]
pub enum PairingOutbound {
    Create {
        rendezvous_id: Vec<u8>,
        kind: PairingRendezvousKind,
        pairing_code: String,
    },
    Relay {
        rendezvous_id: Vec<u8>,
        opaque_envelope: Vec<u8>,
    },
    Complete {
        rendezvous_id: Vec<u8>,
        completion: PairingRendezvousCompletion,
    },
}

impl fmt::Debug for PairingOutbound {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Create { kind, .. } => formatter
                .debug_struct("PairingOutbound::Create")
                .field("kind", kind)
                .field("sensitive", &"[REDACTED]")
                .finish(),
            Self::Relay {
                opaque_envelope, ..
            } => formatter
                .debug_struct("PairingOutbound::Relay")
                .field("opaque_bytes", &opaque_envelope.len())
                .field("sensitive", &"[REDACTED]")
                .finish(),
            Self::Complete { completion, .. } => formatter
                .debug_struct("PairingOutbound::Complete")
                .field("completion", completion)
                .field("rendezvous_id", &"[REDACTED]")
                .finish(),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ActivePhase {
    Creating,
    Inviting,
    WaitingHello,
    WaitingReady,
    WaitingDecision,
}

struct HostPairingKeys {
    controller_to_host: Zeroizing<[u8; 32]>,
    host_to_controller: Zeroizing<[u8; 32]>,
}

struct ActivePairing {
    phase: ActivePhase,
    invitation: HostPairingInvitation,
    server_expires_at_unix_ms: u64,
    host_ephemeral_private_key: Zeroizing<[u8; EPHEMERAL_PRIVATE_KEY_BYTES]>,
    peer_device_id: Option<Vec<u8>>,
    controller: Option<DeviceIdentity>,
    controller_ephemeral_public_key: Vec<u8>,
    transcript_sha256: Vec<u8>,
    keys: Option<HostPairingKeys>,
    sas_words: Vec<String>,
}

pub struct HostPairingCoordinator {
    host_identity: DeviceIdentity,
    random: Box<dyn PairingRandom>,
    signaling_connected: bool,
    revision: u64,
    status: HostPairingStatusSnapshot,
    active: Option<ActivePairing>,
    terminal_rendezvous_id: Option<Vec<u8>>,
    pending_cancelled_create: Option<Vec<u8>>,
    outbound: VecDeque<PairingOutbound>,
}

impl HostPairingCoordinator {
    pub(crate) fn from_validated_host(host_identity: DeviceIdentity) -> Self {
        match Self::new(host_identity) {
            Ok(coordinator) => coordinator,
            Err(_) => unreachable!("HostIdentity always contains a validated desktop identity"),
        }
    }

    /// Creates a Host pairing coordinator backed by the system CSPRNG.
    ///
    /// # Errors
    ///
    /// Returns an error unless the public Host identity is a valid desktop
    /// Ed25519 identity.
    pub fn new(host_identity: DeviceIdentity) -> Result<Self, PairingCoordinatorError> {
        Self::with_random(host_identity, Box::new(SystemPairingRandom))
    }

    #[doc(hidden)]
    /// Creates a coordinator with injected randomness for deterministic tests.
    ///
    /// # Errors
    ///
    /// Returns the same identity validation error as [`Self::new`].
    pub fn with_random(
        host_identity: DeviceIdentity,
        random: Box<dyn PairingRandom>,
    ) -> Result<Self, PairingCoordinatorError> {
        validate_device_identity(&host_identity)
            .map_err(|_| PairingCoordinatorError::InvalidInput)?;
        let host_public_key: [u8; 32] = host_identity
            .public_key
            .as_slice()
            .try_into()
            .map_err(|_| PairingCoordinatorError::InvalidInput)?;
        if host_identity.display_name.is_empty()
            || derive_device_id_v1(&host_public_key)
                .map_err(|_| PairingCoordinatorError::InvalidInput)?
                .as_slice()
                != host_identity.device_id
        {
            return Err(PairingCoordinatorError::InvalidInput);
        }
        let platform = DevicePlatform::try_from(host_identity.platform)
            .map_err(|_| PairingCoordinatorError::InvalidInput)?;
        if !matches!(platform, DevicePlatform::Macos | DevicePlatform::Windows) {
            return Err(PairingCoordinatorError::InvalidInput);
        }
        Ok(Self {
            host_identity,
            random,
            signaling_connected: false,
            revision: 0,
            status: idle_snapshot(0),
            active: None,
            terminal_rendezvous_id: None,
            pending_cancelled_create: None,
            outbound: VecDeque::new(),
        })
    }

    pub fn signaling_connected(&mut self) {
        self.signaling_connected = true;
    }

    #[must_use]
    pub fn snapshot(&self) -> HostPairingStatusSnapshot {
        self.status.clone()
    }

    pub(crate) const fn revision(&self) -> u64 {
        self.revision
    }

    pub(crate) fn deadline_unix_ms(&self) -> Option<u64> {
        self.active
            .as_ref()
            .map(|active| active.invitation.expires_at_unix_ms)
    }

    pub(crate) fn has_outbound(&self) -> bool {
        !self.outbound.is_empty()
    }

    /// Starts a two-minute QR or desktop-code invitation.
    ///
    /// # Errors
    ///
    /// Returns an error unless signaling is connected, the coordinator is
    /// idle, the endpoint and kind are valid, and secure randomness succeeds.
    pub fn start(
        &mut self,
        kind: PairingInvitationKind,
        signaling_endpoint: &str,
        now_unix_ms: u64,
    ) -> Result<HostPairingStatusSnapshot, PairingCoordinatorError> {
        if !self.signaling_connected || self.active.is_some() {
            return Err(PairingCoordinatorError::InvalidState);
        }
        if self.status.state != HostPairingState::Idle as i32 {
            self.return_to_idle()?;
        }
        if !matches!(
            kind,
            PairingInvitationKind::Qr | PairingInvitationKind::DesktopCode
        ) || validate_signaling_endpoint(signaling_endpoint).is_err()
        {
            return Err(PairingCoordinatorError::InvalidInput);
        }
        let expires_at_unix_ms = now_unix_ms
            .checked_add(PAIRING_RENDEZVOUS_LIFETIME_MS)
            .ok_or(PairingCoordinatorError::InvalidInput)?;
        let mut rendezvous_id = [0_u8; RENDEZVOUS_BYTES];
        let mut private_key = Zeroizing::new([0_u8; EPHEMERAL_PRIVATE_KEY_BYTES]);
        self.random
            .fill(&mut rendezvous_id)
            .map_err(PairingCoordinatorError::Random)?;
        self.random
            .fill(private_key.as_mut())
            .map_err(PairingCoordinatorError::Random)?;
        let ephemeral_public_key = x25519_public_key(private_key.as_ref())
            .map_err(|_| PairingCoordinatorError::Authentication)?;
        let pairing_code = if kind == PairingInvitationKind::DesktopCode {
            self.generate_desktop_code()?
        } else {
            String::new()
        };
        let invitation = HostPairingInvitation {
            protocol_version: Some(ProtocolVersion {
                major: PROTOCOL_MAJOR_VERSION,
                minor: 0,
            }),
            kind: kind as i32,
            rendezvous_id: rendezvous_id.to_vec(),
            host_identity: Some(self.host_identity.clone()),
            host_public_key_fingerprint_sha256: public_key_fingerprint(
                &self.host_identity.public_key,
            )
            .to_vec(),
            host_ephemeral_public_key: ephemeral_public_key.to_vec(),
            signaling_endpoint: signaling_endpoint.to_owned(),
            pairing_code: pairing_code.clone(),
            issued_at_unix_ms: now_unix_ms,
            expires_at_unix_ms,
        };
        self.active = Some(ActivePairing {
            phase: ActivePhase::Creating,
            invitation,
            server_expires_at_unix_ms: 0,
            host_ephemeral_private_key: private_key,
            peer_device_id: None,
            controller: None,
            controller_ephemeral_public_key: Vec::new(),
            transcript_sha256: Vec::new(),
            keys: None,
            sas_words: Vec::new(),
        });
        self.terminal_rendezvous_id = None;
        self.outbound.push_back(PairingOutbound::Create {
            rendezvous_id: rendezvous_id.to_vec(),
            kind: signaling_kind(kind),
            pairing_code,
        });
        self.publish_active(HostPairingState::Creating);
        Ok(self.snapshot())
    }

    /// Applies one already-validated signaling service event.
    ///
    /// # Errors
    ///
    /// Returns an error for state, correlation, identity, signature, transcript,
    /// sequence, or authenticated-encryption violations. Authentication errors
    /// terminate and clear the active pairing.
    pub fn handle_signaling_event(
        &mut self,
        event: SignalingEvent,
        signing_identity: &HostIdentity,
        now_unix_ms: u64,
    ) -> Result<(), PairingCoordinatorError> {
        self.tick(now_unix_ms);
        match event {
            SignalingEvent::PairingCreated {
                rendezvous_id,
                kind,
                expires_at_unix_ms,
            } => self.handle_created(&rendezvous_id, kind, expires_at_unix_ms, now_unix_ms),
            SignalingEvent::PairingJoined {
                rendezvous_id,
                peer_device_id,
                expires_at_unix_ms,
            } => self.handle_joined(
                &rendezvous_id,
                peer_device_id,
                expires_at_unix_ms,
                now_unix_ms,
            ),
            SignalingEvent::RoutedPairing {
                rendezvous_id,
                sender_device_id,
                opaque_envelope,
            } => self.handle_routed(
                &rendezvous_id,
                &sender_device_id,
                &opaque_envelope,
                signing_identity,
            ),
            SignalingEvent::PairingClosed {
                rendezvous_id,
                completion,
            } => self.handle_closed(&rendezvous_id, completion),
            SignalingEvent::RemoteError { .. } if self.active.is_some() => {
                self.fail_active();
                Ok(())
            }
            SignalingEvent::Registered { .. }
            | SignalingEvent::HeartbeatAcknowledged { .. }
            | SignalingEvent::RoutedSession { .. }
            | SignalingEvent::RemoteError { .. } => Err(PairingCoordinatorError::InvalidState),
        }
    }

    /// Atomically persists the grant before reporting encrypted success.
    ///
    /// # Errors
    ///
    /// Returns an error unless the identifiers match a verified pending
    /// Controller or authorization persistence succeeds.
    pub fn accept(
        &mut self,
        rendezvous_id: &[u8],
        controller_device_id: &[u8],
        authorization: &mut AuthorizationRegistry,
        now_unix_ms: u64,
    ) -> Result<(), PairingCoordinatorError> {
        self.ensure_waiting_decision(rendezvous_id, controller_device_id, now_unix_ms)?;
        let controller = self
            .active
            .as_ref()
            .and_then(|active| active.controller.clone())
            .ok_or(PairingCoordinatorError::InvalidState)?;
        let grant = match authorization.create_controller_grant(
            controller,
            VIEW_AND_CONTROL_PERMISSIONS,
            now_unix_ms,
        ) {
            Ok(view) => view.grant.ok_or(PairingCoordinatorError::InvalidState)?,
            Err(error) => {
                self.fail_active();
                return Err(PairingCoordinatorError::Authorization(error));
            }
        };
        let encrypted =
            self.encrypt_final_decision(PairingDecisionStatus::Accepted, Some(grant))?;
        self.outbound.push_back(PairingOutbound::Relay {
            rendezvous_id: rendezvous_id.to_vec(),
            opaque_envelope: encrypted,
        });
        self.outbound.push_back(PairingOutbound::Complete {
            rendezvous_id: rendezvous_id.to_vec(),
            completion: PairingRendezvousCompletion::Succeeded,
        });
        self.finish(HostPairingState::Accepted, None);
        Ok(())
    }

    /// Rejects a verified pending Controller through the authenticated local UI.
    ///
    /// # Errors
    ///
    /// Returns an error unless both identifiers match the pending decision.
    pub fn reject(
        &mut self,
        rendezvous_id: &[u8],
        controller_device_id: &[u8],
        now_unix_ms: u64,
    ) -> Result<(), PairingCoordinatorError> {
        self.ensure_waiting_decision(rendezvous_id, controller_device_id, now_unix_ms)?;
        let encrypted = self.encrypt_final_decision(PairingDecisionStatus::Rejected, None)?;
        self.outbound.push_back(PairingOutbound::Relay {
            rendezvous_id: rendezvous_id.to_vec(),
            opaque_envelope: encrypted,
        });
        self.outbound.push_back(PairingOutbound::Complete {
            rendezvous_id: rendezvous_id.to_vec(),
            completion: PairingRendezvousCompletion::Rejected,
        });
        self.finish(HostPairingState::Rejected, None);
        Ok(())
    }

    /// Cancels any active invitation without granting authorization.
    ///
    /// # Errors
    ///
    /// Returns an error when there is no active pairing.
    pub fn cancel(
        &mut self,
        rendezvous_id: &[u8],
        _now_unix_ms: u64,
    ) -> Result<(), PairingCoordinatorError> {
        let active = self
            .active
            .as_ref()
            .ok_or(PairingCoordinatorError::InvalidState)?;
        if active.invitation.rendezvous_id != rendezvous_id {
            return Err(PairingCoordinatorError::InvalidState);
        }
        let rendezvous_id = rendezvous_id.to_vec();
        if active.phase == ActivePhase::Creating {
            self.pending_cancelled_create = Some(rendezvous_id);
        } else {
            self.outbound.push_back(PairingOutbound::Complete {
                rendezvous_id,
                completion: PairingRendezvousCompletion::Rejected,
            });
        }
        self.finish(HostPairingState::Cancelled, None);
        Ok(())
    }

    pub fn tick(&mut self, now_unix_ms: u64) {
        let Some(active) = self.active.as_ref() else {
            return;
        };
        if now_unix_ms < active.invitation.expires_at_unix_ms {
            return;
        }
        let rendezvous_id = active.invitation.rendezvous_id.clone();
        if active.phase == ActivePhase::Creating {
            self.pending_cancelled_create = Some(rendezvous_id);
        } else {
            self.outbound.push_back(PairingOutbound::Complete {
                rendezvous_id,
                completion: PairingRendezvousCompletion::Rejected,
            });
        }
        self.finish(HostPairingState::Expired, None);
    }

    pub fn signaling_lost(&mut self) {
        self.signaling_connected = false;
        self.pending_cancelled_create = None;
        if self.active.is_some() {
            self.finish(HostPairingState::Failed, Some(pairing_failed_error()));
        }
    }

    pub fn shutdown(&mut self) {
        self.signaling_connected = false;
        self.pending_cancelled_create = None;
        self.outbound.clear();
        if self.active.is_some() {
            self.finish(HostPairingState::Cancelled, None);
        }
    }

    /// Clears a terminal public snapshot after the UI has observed it.
    ///
    /// # Errors
    ///
    /// Returns an error for active or already-idle states.
    pub fn return_to_idle(&mut self) -> Result<(), PairingCoordinatorError> {
        let state = HostPairingState::try_from(self.status.state)
            .map_err(|_| PairingCoordinatorError::InvalidState)?;
        if self.active.is_some()
            || matches!(
                state,
                HostPairingState::Idle
                    | HostPairingState::Creating
                    | HostPairingState::Inviting
                    | HostPairingState::VerifyingController
                    | HostPairingState::WaitingLocalDecision
                    | HostPairingState::Unspecified
            )
        {
            return Err(PairingCoordinatorError::InvalidState);
        }
        self.terminal_rendezvous_id = None;
        self.revision = self.revision.saturating_add(1);
        self.status = idle_snapshot(self.revision);
        Ok(())
    }

    #[must_use]
    pub fn take_outbound(&mut self) -> Vec<PairingOutbound> {
        self.outbound.drain(..).collect()
    }

    fn generate_desktop_code(&mut self) -> Result<String, PairingCoordinatorError> {
        let mut random = [0_u8; DESKTOP_CODE_RANDOM_BYTES];
        self.random
            .fill(&mut random)
            .map_err(PairingCoordinatorError::Random)?;
        let bits = u64::from_be_bytes([
            0, 0, 0, random[0], random[1], random[2], random[3], random[4],
        ]);
        Ok((0..8)
            .map(|index| {
                let shift = (7 - index) * 5;
                char::from(BASE32_ALPHABET[((bits >> shift) & 0x1f) as usize])
            })
            .collect())
    }

    fn handle_created(
        &mut self,
        rendezvous_id: &[u8],
        kind: PairingRendezvousKind,
        server_expires_at_unix_ms: u64,
        now_unix_ms: u64,
    ) -> Result<(), PairingCoordinatorError> {
        if self.active.is_none() && self.pending_cancelled_create.as_deref() == Some(rendezvous_id)
        {
            self.pending_cancelled_create = None;
            self.outbound.push_back(PairingOutbound::Complete {
                rendezvous_id: rendezvous_id.to_vec(),
                completion: PairingRendezvousCompletion::Rejected,
            });
            return Ok(());
        }
        let active = self
            .active
            .as_mut()
            .ok_or(PairingCoordinatorError::InvalidState)?;
        if active.phase != ActivePhase::Creating
            || active.invitation.rendezvous_id != rendezvous_id
            || signaling_kind(
                PairingInvitationKind::try_from(active.invitation.kind)
                    .map_err(|_| PairingCoordinatorError::InvalidState)?,
            ) != kind
            || server_expires_at_unix_ms <= now_unix_ms
        {
            return Err(PairingCoordinatorError::InvalidState);
        }
        active.server_expires_at_unix_ms = server_expires_at_unix_ms;
        active.invitation.expires_at_unix_ms = active
            .invitation
            .expires_at_unix_ms
            .min(server_expires_at_unix_ms);
        active.phase = ActivePhase::Inviting;
        self.publish_active(HostPairingState::Inviting);
        Ok(())
    }

    fn handle_joined(
        &mut self,
        rendezvous_id: &[u8],
        peer_device_id: Vec<u8>,
        expires_at_unix_ms: u64,
        now_unix_ms: u64,
    ) -> Result<(), PairingCoordinatorError> {
        let active = self
            .active
            .as_mut()
            .ok_or(PairingCoordinatorError::InvalidState)?;
        if active.phase != ActivePhase::Inviting
            || active.invitation.rendezvous_id != rendezvous_id
            || active.server_expires_at_unix_ms != expires_at_unix_ms
            || active.invitation.expires_at_unix_ms <= now_unix_ms
            || peer_device_id == self.host_identity.device_id
        {
            return Err(PairingCoordinatorError::InvalidState);
        }
        active.peer_device_id = Some(peer_device_id);
        active.phase = ActivePhase::WaitingHello;
        if active.invitation.kind == PairingInvitationKind::DesktopCode as i32 {
            self.outbound.push_back(PairingOutbound::Relay {
                rendezvous_id: rendezvous_id.to_vec(),
                opaque_envelope: encode_pairing_payload(pairing_message::Payload::HostInvitation(
                    active.invitation.clone(),
                )),
            });
        }
        self.publish_active(HostPairingState::VerifyingController);
        Ok(())
    }

    fn handle_routed(
        &mut self,
        rendezvous_id: &[u8],
        sender_device_id: &[u8],
        opaque_envelope: &[u8],
        signing_identity: &HostIdentity,
    ) -> Result<(), PairingCoordinatorError> {
        let result = self.handle_routed_inner(
            rendezvous_id,
            sender_device_id,
            opaque_envelope,
            signing_identity,
        );
        if result.is_err() && self.active.is_some() {
            self.fail_active();
        }
        result
    }

    fn handle_routed_inner(
        &mut self,
        rendezvous_id: &[u8],
        sender_device_id: &[u8],
        opaque_envelope: &[u8],
        signing_identity: &HostIdentity,
    ) -> Result<(), PairingCoordinatorError> {
        let phase = self
            .active
            .as_ref()
            .ok_or(PairingCoordinatorError::InvalidState)?
            .phase;
        let active = self.active.as_ref().expect("active checked");
        if active.invitation.rendezvous_id != rendezvous_id
            || active.peer_device_id.as_deref() != Some(sender_device_id)
        {
            return Err(PairingCoordinatorError::Authentication);
        }
        match phase {
            ActivePhase::WaitingHello => {
                let message = decode_pairing_message(opaque_envelope).map_err(map_crypto_error)?;
                let Some(pairing_message::Payload::ControllerHello(hello)) = message.payload else {
                    return Err(PairingCoordinatorError::Authentication);
                };
                self.handle_controller_hello(hello, sender_device_id, signing_identity)
            }
            ActivePhase::WaitingReady => self.handle_controller_ready(opaque_envelope),
            ActivePhase::Creating | ActivePhase::Inviting | ActivePhase::WaitingDecision => {
                Err(PairingCoordinatorError::Authentication)
            }
        }
    }

    fn handle_controller_hello(
        &mut self,
        hello: roammand_protocol::roammand::v1::ControllerPairingHello,
        sender_device_id: &[u8],
        signing_identity: &HostIdentity,
    ) -> Result<(), PairingCoordinatorError> {
        let active = self.active.as_ref().expect("active checked");
        let verified = verify_controller_hello(
            hello,
            sender_device_id,
            &active.invitation.rendezvous_id,
            &self.host_identity,
            active.host_ephemeral_private_key.as_ref(),
            &active.invitation.host_ephemeral_public_key,
        )
        .map_err(map_crypto_error)?;
        let signature = signing_identity
            .sign_pairing_transcript(&verified.transcript, PairingIdentityRole::Host)
            .map_err(|_| PairingCoordinatorError::Authentication)?;
        let confirmation = confirmation_data(&verified, active);
        let proof = PairingPlaintext {
            payload: Some(pairing_plaintext::Payload::HostProof(HostPairingProof {
                confirmation: Some(confirmation),
                host_signature: signature.signature,
                expires_at_unix_ms: active.invitation.expires_at_unix_ms,
            })),
        };
        let encrypted = seal_host_plaintext(
            &verified.keys.host_to_controller,
            1,
            &active.invitation.rendezvous_id,
            &verified.controller.device_id,
            &self.host_identity.device_id,
            &proof,
        )
        .map_err(map_crypto_error)?;
        let sas_words = if active.invitation.kind == PairingInvitationKind::DesktopCode as i32 {
            pairing_sas_words(&verified.transcript_sha256).map_err(map_crypto_error)?
        } else {
            Vec::new()
        };
        let active = self.active.as_mut().expect("active checked");
        active.controller = Some(verified.controller);
        active.controller_ephemeral_public_key = verified.controller_ephemeral_public_key;
        active.transcript_sha256 = verified.transcript_sha256.to_vec();
        active.keys = Some(HostPairingKeys {
            controller_to_host: Zeroizing::new(verified.keys.controller_to_host),
            host_to_controller: Zeroizing::new(verified.keys.host_to_controller),
        });
        active.sas_words = sas_words;
        active.phase = ActivePhase::WaitingReady;
        self.outbound.push_back(PairingOutbound::Relay {
            rendezvous_id: active.invitation.rendezvous_id.clone(),
            opaque_envelope: encrypted,
        });
        Ok(())
    }

    fn handle_controller_ready(
        &mut self,
        opaque_envelope: &[u8],
    ) -> Result<(), PairingCoordinatorError> {
        let active = self.active.as_ref().expect("active checked");
        let controller = active
            .controller
            .as_ref()
            .ok_or(PairingCoordinatorError::Authentication)?;
        let keys = active
            .keys
            .as_ref()
            .ok_or(PairingCoordinatorError::Authentication)?;
        let plaintext = open_controller_plaintext(
            keys.controller_to_host.as_ref(),
            1,
            &active.invitation.rendezvous_id,
            &controller.device_id,
            &self.host_identity.device_id,
            opaque_envelope,
        )
        .map_err(map_crypto_error)?;
        let Some(pairing_plaintext::Payload::ControllerReady(ready)) = plaintext.payload else {
            return Err(PairingCoordinatorError::Authentication);
        };
        if ready.transcript_sha256 != active.transcript_sha256 {
            return Err(PairingCoordinatorError::Authentication);
        }
        self.active.as_mut().expect("active checked").phase = ActivePhase::WaitingDecision;
        self.publish_active(HostPairingState::WaitingLocalDecision);
        Ok(())
    }

    fn handle_closed(
        &mut self,
        rendezvous_id: &[u8],
        completion: PairingRendezvousCompletion,
    ) -> Result<(), PairingCoordinatorError> {
        if self.terminal_rendezvous_id.as_deref() == Some(rendezvous_id) {
            return Ok(());
        }
        let active = self
            .active
            .as_ref()
            .ok_or(PairingCoordinatorError::InvalidState)?;
        if active.invitation.rendezvous_id != rendezvous_id {
            return Err(PairingCoordinatorError::InvalidState);
        }
        let state = match completion {
            PairingRendezvousCompletion::Rejected => HostPairingState::Rejected,
            PairingRendezvousCompletion::Expired => HostPairingState::Expired,
            PairingRendezvousCompletion::Disconnected => HostPairingState::Failed,
            PairingRendezvousCompletion::Succeeded | PairingRendezvousCompletion::Unspecified => {
                HostPairingState::Failed
            }
        };
        let error = (state == HostPairingState::Failed).then(pairing_failed_error);
        self.finish(state, error);
        Ok(())
    }

    fn ensure_waiting_decision(
        &mut self,
        rendezvous_id: &[u8],
        controller_device_id: &[u8],
        now_unix_ms: u64,
    ) -> Result<(), PairingCoordinatorError> {
        self.tick(now_unix_ms);
        let active = self.active.as_ref().ok_or({
            if self.status.state == HostPairingState::Expired as i32 {
                PairingCoordinatorError::Expired
            } else {
                PairingCoordinatorError::InvalidState
            }
        })?;
        if active.phase != ActivePhase::WaitingDecision
            || active.invitation.rendezvous_id != rendezvous_id
            || active
                .controller
                .as_ref()
                .map(|value| value.device_id.as_slice())
                != Some(controller_device_id)
        {
            return Err(PairingCoordinatorError::InvalidState);
        }
        Ok(())
    }

    fn encrypt_final_decision(
        &self,
        status: PairingDecisionStatus,
        grant: Option<ControllerGrant>,
    ) -> Result<Vec<u8>, PairingCoordinatorError> {
        let active = self
            .active
            .as_ref()
            .ok_or(PairingCoordinatorError::InvalidState)?;
        let controller = active
            .controller
            .as_ref()
            .ok_or(PairingCoordinatorError::InvalidState)?;
        let keys = active
            .keys
            .as_ref()
            .ok_or(PairingCoordinatorError::InvalidState)?;
        seal_host_plaintext(
            keys.host_to_controller.as_ref(),
            2,
            &active.invitation.rendezvous_id,
            &controller.device_id,
            &self.host_identity.device_id,
            &PairingPlaintext {
                payload: Some(pairing_plaintext::Payload::FinalDecision(
                    PairingFinalDecision {
                        status: status as i32,
                        transcript_sha256: active.transcript_sha256.clone(),
                        grant,
                    },
                )),
            },
        )
        .map_err(map_crypto_error)
    }

    fn publish_active(&mut self, state: HostPairingState) {
        self.revision = self.revision.saturating_add(1);
        let active = self.active.as_ref().expect("active state required");
        let waiting = state == HostPairingState::WaitingLocalDecision;
        self.status = HostPairingStatusSnapshot {
            state: state as i32,
            revision: self.revision,
            invitation: Some(active.invitation.clone()),
            pending_controller: waiting.then(|| active.controller.clone()).flatten(),
            pending_controller_fingerprint_sha256: if waiting {
                active
                    .controller
                    .as_ref()
                    .map_or_else(Vec::new, |controller| {
                        public_key_fingerprint(&controller.public_key).to_vec()
                    })
            } else {
                Vec::new()
            },
            sas_words: if waiting {
                active.sas_words.clone()
            } else {
                Vec::new()
            },
            expires_at_unix_ms: active.invitation.expires_at_unix_ms,
            error: None,
        };
    }

    fn fail_active(&mut self) {
        if let Some(active) = self.active.as_ref()
            && active.phase != ActivePhase::Creating
        {
            self.outbound.push_back(PairingOutbound::Complete {
                rendezvous_id: active.invitation.rendezvous_id.clone(),
                completion: PairingRendezvousCompletion::Rejected,
            });
        }
        self.finish(HostPairingState::Failed, Some(pairing_failed_error()));
    }

    fn finish(&mut self, state: HostPairingState, error: Option<UnifiedError>) {
        let rendezvous_id = self
            .active
            .as_ref()
            .map(|active| active.invitation.rendezvous_id.clone());
        self.active = None;
        if rendezvous_id.is_some() {
            self.terminal_rendezvous_id = rendezvous_id;
        }
        self.revision = self.revision.saturating_add(1);
        self.status = HostPairingStatusSnapshot {
            state: state as i32,
            revision: self.revision,
            invitation: None,
            pending_controller: None,
            pending_controller_fingerprint_sha256: Vec::new(),
            sas_words: Vec::new(),
            expires_at_unix_ms: 0,
            error,
        };
    }
}

impl fmt::Debug for HostPairingCoordinator {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HostPairingCoordinator")
            .field("state", &self.status.state)
            .field("revision", &self.revision)
            .field("active", &self.active.is_some())
            .field("sensitive", &"[REDACTED]")
            .finish_non_exhaustive()
    }
}

fn confirmation_data(
    verified: &VerifiedControllerHello,
    active: &ActivePairing,
) -> PairingConfirmationData {
    let host = active
        .invitation
        .host_identity
        .as_ref()
        .expect("validated Host identity");
    PairingConfirmationData {
        controller_device_id: verified.controller.device_id.clone(),
        host_device_id: host.device_id.clone(),
        rendezvous_id: active.invitation.rendezvous_id.clone(),
        controller_identity_public_key: verified.controller.public_key.clone(),
        host_identity_public_key: host.public_key.clone(),
        controller_ephemeral_public_key: verified.controller_ephemeral_public_key.clone(),
        host_ephemeral_public_key: active.invitation.host_ephemeral_public_key.clone(),
        transcript_sha256: verified.transcript_sha256.to_vec(),
    }
}

const fn signaling_kind(kind: PairingInvitationKind) -> PairingRendezvousKind {
    match kind {
        PairingInvitationKind::Qr => PairingRendezvousKind::Qr,
        PairingInvitationKind::DesktopCode => PairingRendezvousKind::DesktopCode,
        PairingInvitationKind::Unspecified => PairingRendezvousKind::Unspecified,
    }
}

const fn map_crypto_error(_error: HostPairingCryptoError) -> PairingCoordinatorError {
    PairingCoordinatorError::Authentication
}

fn pairing_failed_error() -> UnifiedError {
    UnifiedError {
        code: ErrorCode::AuthInvalid as i32,
        message_key: "pairing.failed".to_owned(),
        retryable: false,
        request_id: String::new(),
        details: None,
    }
}

const fn idle_snapshot(revision: u64) -> HostPairingStatusSnapshot {
    HostPairingStatusSnapshot {
        state: HostPairingState::Idle as i32,
        revision,
        invitation: None,
        pending_controller: None,
        pending_controller_fingerprint_sha256: Vec::new(),
        sas_words: Vec::new(),
        expires_at_unix_ms: 0,
        error: None,
    }
}
