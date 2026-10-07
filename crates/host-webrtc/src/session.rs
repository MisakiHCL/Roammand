// SPDX-License-Identifier: MPL-2.0

use std::{collections::BTreeSet, fmt};

use roammand_protocol::{
    protocol_limits::{NONCE_OR_HASH_BYTES, SESSION_ID_BYTES},
    roammand::v1::{
        ButtonAction, KeyboardAction, PointerButton, SessionControlAction, SessionPermission,
        pointer_fast_envelope, reliable_input_envelope,
    },
    validation::{
        decode_and_validate_pointer_fast_envelope, decode_and_validate_reliable_input_envelope,
    },
};

use crate::{
    HostWebRtcError, NORMALIZED_POINTER_MAX, PeerAnswer, PeerBackend, PeerIceCandidate,
    RemoteInputSink, SessionConfig,
};

const MINIMUM_USB_HID_KEYBOARD_USAGE: u32 = 0x04;
const MAXIMUM_USB_HID_KEYBOARD_USAGE: u32 = 0xe7;
const MAXIMUM_MODIFIER_BITS: u32 = 0xff;
const MAXIMUM_POINTER_BUTTON_BITS: u32 = 0x07;
const MAXIMUM_SCROLL_DELTA: i32 = 10_000;
const MAXIMUM_TEXT_INPUT_BYTES: usize = 1024;
const MAXIMUM_SDP_BYTES: usize = 131_072;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HostSessionState {
    New,
    Negotiating,
    Connected,
    Reconnecting,
    Closing,
    Closed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InputDisposition {
    Applied,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PointerDisposition {
    Applied,
    DroppedStale,
}

pub struct HostPeerSession {
    session_id: Vec<u8>,
    input_allowed: bool,
    config: SessionConfig,
    peer: Box<dyn PeerBackend>,
    input: Box<dyn RemoteInputSink>,
    state: HostSessionState,
    last_reliable_sequence: u64,
    last_pointer_sequence: u64,
    pressed_keys: BTreeSet<u32>,
    pressed_buttons: BTreeSet<i32>,
    input_cleanup_pending: bool,
}

impl HostPeerSession {
    /// Creates a non-negotiated Host peer session.
    ///
    /// # Errors
    ///
    /// Returns an error for invalid session ID or permission combinations.
    pub fn new(
        session_id: Vec<u8>,
        permissions: &[SessionPermission],
        config: SessionConfig,
        peer: Box<dyn PeerBackend>,
        input: Box<dyn RemoteInputSink>,
    ) -> Result<Self, HostWebRtcError> {
        if session_id.len() != SESSION_ID_BYTES {
            return Err(HostWebRtcError::InvalidSession);
        }
        validate_permissions(permissions)?;
        Ok(Self {
            session_id,
            input_allowed: permissions.contains(&SessionPermission::ControlInput),
            config,
            peer,
            input,
            state: HostSessionState::New,
            last_reliable_sequence: 0,
            last_pointer_sequence: 0,
            pressed_keys: BTreeSet::new(),
            pressed_buttons: BTreeSet::new(),
            input_cleanup_pending: false,
        })
    }

    #[must_use]
    pub const fn state(&self) -> HostSessionState {
        self.state
    }

    /// Starts capture and peer negotiation for one SDP offer.
    ///
    /// # Errors
    ///
    /// Returns an error for invalid state/SDP or backend failure.
    pub fn accept_offer(&mut self, offer_sdp: &str) -> Result<PeerAnswer, HostWebRtcError> {
        if self.state != HostSessionState::New {
            return Err(HostWebRtcError::InvalidState);
        }
        if offer_sdp.is_empty() || offer_sdp.len() > MAXIMUM_SDP_BYTES {
            return Err(HostWebRtcError::InvalidSdp);
        }
        let answer = match self.peer.start(&self.config, offer_sdp) {
            Ok(answer) => answer,
            Err(error) => {
                let _ = self.close();
                return Err(error);
            }
        };
        if answer.sdp.is_empty()
            || answer.sdp.len() > MAXIMUM_SDP_BYTES
            || answer.dtls_fingerprint_sha256.len() != NONCE_OR_HASH_BYTES
        {
            let _ = self.close();
            return Err(HostWebRtcError::InvalidAnswer);
        }
        self.state = HostSessionState::Negotiating;
        Ok(answer)
    }

    /// Marks a negotiated or recovering peer as connected.
    ///
    /// # Errors
    ///
    /// Returns an error unless the session already has a live peer. Duplicate
    /// connected callbacks are idempotent because native WebRTC backends can
    /// publish them while an ICE path is being recovered.
    pub fn mark_connected(&mut self) -> Result<(), HostWebRtcError> {
        if !matches!(
            self.state,
            HostSessionState::Negotiating
                | HostSessionState::Connected
                | HostSessionState::Reconnecting
        ) {
            return Err(HostWebRtcError::InvalidState);
        }
        self.state = HostSessionState::Connected;
        Ok(())
    }

    /// Releases pressed input and enters the bounded reconnect state.
    ///
    /// # Errors
    ///
    /// Returns an error unless a negotiated peer exists or input release
    /// fails. Repeated disconnect notifications are idempotent.
    pub fn begin_reconnect(&mut self) -> Result<(), HostWebRtcError> {
        if self.state == HostSessionState::Reconnecting {
            return Ok(());
        }
        if !matches!(
            self.state,
            HostSessionState::Connected | HostSessionState::Negotiating
        ) {
            return Err(HostWebRtcError::InvalidState);
        }
        self.release_all()?;
        self.state = HostSessionState::Reconnecting;
        Ok(())
    }

    /// Applies an authenticated ICE Restart offer without replacing capture,
    /// data channels, input sequence state, or the peer backend.
    ///
    /// # Errors
    ///
    /// Returns a stable state, SDP, answer, or backend error while keeping the
    /// session available for another bounded attempt.
    pub fn accept_reconnect_offer(
        &mut self,
        offer_sdp: &str,
    ) -> Result<PeerAnswer, HostWebRtcError> {
        if !matches!(
            self.state,
            HostSessionState::Reconnecting | HostSessionState::Negotiating
        ) {
            return Err(HostWebRtcError::InvalidState);
        }
        if offer_sdp.is_empty() || offer_sdp.len() > MAXIMUM_SDP_BYTES {
            return Err(HostWebRtcError::InvalidSdp);
        }
        self.state = HostSessionState::Reconnecting;
        let answer = self.peer.restart(&self.config, offer_sdp)?;
        if answer.sdp.is_empty()
            || answer.sdp.len() > MAXIMUM_SDP_BYTES
            || answer.dtls_fingerprint_sha256.len() != NONCE_OR_HASH_BYTES
        {
            return Err(HostWebRtcError::InvalidAnswer);
        }
        self.state = HostSessionState::Negotiating;
        Ok(answer)
    }

    /// Forwards one authenticated remote ICE candidate to the active peer.
    ///
    /// # Errors
    ///
    /// Returns an error before negotiation or after deterministic close.
    pub fn add_remote_ice_candidate(
        &mut self,
        candidate: &PeerIceCandidate,
    ) -> Result<(), HostWebRtcError> {
        if !matches!(
            self.state,
            HostSessionState::Negotiating | HostSessionState::Connected
        ) {
            return Err(HostWebRtcError::InvalidState);
        }
        self.peer.add_remote_ice_candidate(candidate)
    }

    /// Validates and applies one ordered reliable input envelope.
    ///
    /// # Errors
    ///
    /// Returns an error for state, permission, wire, session, sequence, input
    /// value, pressed-state, or platform injection failures.
    pub fn handle_reliable(&mut self, encoded: &[u8]) -> Result<InputDisposition, HostWebRtcError> {
        self.require_input_ready()?;
        let envelope = decode_and_validate_reliable_input_envelope(encoded)
            .map_err(|_| HostWebRtcError::InvalidInputEnvelope)?;
        if envelope.session_id != self.session_id {
            return Err(HostWebRtcError::SessionMismatch);
        }
        if envelope.sequence != self.last_reliable_sequence.saturating_add(1) {
            return Err(HostWebRtcError::ReliableSequence);
        }
        let event = envelope
            .event
            .ok_or(HostWebRtcError::InvalidInputEnvelope)?;
        let should_close = match self.apply_reliable_event(event) {
            Ok(should_close) => should_close,
            Err(HostWebRtcError::InputFailure) => {
                let _ = self.close();
                return Err(HostWebRtcError::InputFailure);
            }
            Err(error) => return Err(error),
        };
        self.last_reliable_sequence = envelope.sequence;
        if should_close {
            self.close()?;
        }
        Ok(InputDisposition::Applied)
    }

    /// Validates and applies only the newest pointer-fast envelope.
    ///
    /// # Errors
    ///
    /// Returns an error for state, permission, wire, session, input value, or
    /// platform injection failures. Stale sequence numbers are dropped.
    pub fn handle_pointer_fast(
        &mut self,
        encoded: &[u8],
    ) -> Result<PointerDisposition, HostWebRtcError> {
        self.require_input_ready()?;
        let envelope = decode_and_validate_pointer_fast_envelope(encoded)
            .map_err(|_| HostWebRtcError::InvalidInputEnvelope)?;
        if envelope.session_id != self.session_id {
            return Err(HostWebRtcError::SessionMismatch);
        }
        if envelope.sequence <= self.last_pointer_sequence {
            return Ok(PointerDisposition::DroppedStale);
        }
        let input_result = match envelope
            .event
            .ok_or(HostWebRtcError::InvalidInputEnvelope)?
        {
            pointer_fast_envelope::Event::Move(event) => {
                validate_coordinates(event.x, event.y)?;
                if event.pressed_button_bits > MAXIMUM_POINTER_BUTTON_BITS {
                    return Err(HostWebRtcError::InvalidPointerButtons);
                }
                self.input
                    .pointer_move(event.x, event.y, event.pressed_button_bits)
            }
            pointer_fast_envelope::Event::Scroll(event) => {
                if event.delta_x.unsigned_abs() > MAXIMUM_SCROLL_DELTA as u32
                    || event.delta_y.unsigned_abs() > MAXIMUM_SCROLL_DELTA as u32
                {
                    return Err(HostWebRtcError::InvalidScrollDelta);
                }
                self.input.pointer_scroll(event.delta_x, event.delta_y)
            }
        };
        if let Err(error) = input_result {
            if error == HostWebRtcError::InputFailure {
                let _ = self.close();
            }
            return Err(error);
        }
        self.last_pointer_sequence = envelope.sequence;
        Ok(PointerDisposition::Applied)
    }

    /// Releases all input and closes the peer idempotently.
    ///
    /// # Errors
    ///
    /// Returns the first shutdown error after still attempting every cleanup.
    /// Failed input releases are retried by a later close or drop without
    /// reopening the peer or accepting new input.
    pub fn close(&mut self) -> Result<(), HostWebRtcError> {
        if self.state == HostSessionState::Closed {
            return if self.input_cleanup_pending {
                self.release_all()
            } else {
                Ok(())
            };
        }
        self.state = HostSessionState::Closing;
        let input_result = self.release_all();
        let peer_result = self.peer.close();
        self.state = HostSessionState::Closed;
        input_result.and(peer_result)
    }

    fn require_input_ready(&self) -> Result<(), HostWebRtcError> {
        if self.state != HostSessionState::Connected {
            return Err(HostWebRtcError::InvalidState);
        }
        if !self.input_allowed {
            return Err(HostWebRtcError::InputPermissionDenied);
        }
        Ok(())
    }

    fn apply_reliable_event(
        &mut self,
        event: reliable_input_envelope::Event,
    ) -> Result<bool, HostWebRtcError> {
        match event {
            reliable_input_envelope::Event::Keyboard(event) => {
                let action = KeyboardAction::try_from(event.action)
                    .map_err(|_| HostWebRtcError::InvalidInputEnvelope)?;
                validate_keyboard(event.usb_hid_usage, event.modifier_bits)?;
                match action {
                    KeyboardAction::Down => {
                        if !self.pressed_keys.insert(event.usb_hid_usage) {
                            return Err(HostWebRtcError::PressedInputState);
                        }
                        self.input
                            .keyboard(action, event.usb_hid_usage, event.modifier_bits)?;
                    }
                    KeyboardAction::Up => {
                        if self.pressed_keys.remove(&event.usb_hid_usage) {
                            self.input.keyboard(
                                action,
                                event.usb_hid_usage,
                                event.modifier_bits,
                            )?;
                        }
                    }
                    KeyboardAction::Unspecified => {
                        return Err(HostWebRtcError::InvalidInputEnvelope);
                    }
                }
                Ok(false)
            }
            reliable_input_envelope::Event::PointerButton(event) => {
                validate_coordinates(event.x, event.y)?;
                let button = PointerButton::try_from(event.button)
                    .map_err(|_| HostWebRtcError::InvalidInputEnvelope)?;
                let action = ButtonAction::try_from(event.action)
                    .map_err(|_| HostWebRtcError::InvalidInputEnvelope)?;
                match action {
                    ButtonAction::Down => {
                        if !self.pressed_buttons.insert(event.button) {
                            return Err(HostWebRtcError::PressedInputState);
                        }
                        self.input
                            .pointer_button(button, action, event.x, event.y)?;
                    }
                    ButtonAction::Up => {
                        if self.pressed_buttons.remove(&event.button) {
                            self.input
                                .pointer_button(button, action, event.x, event.y)?;
                        }
                    }
                    ButtonAction::Click | ButtonAction::DoubleClick => self
                        .input
                        .pointer_button(button, action, event.x, event.y)?,
                    ButtonAction::Unspecified => {
                        return Err(HostWebRtcError::InvalidInputEnvelope);
                    }
                }
                Ok(false)
            }
            reliable_input_envelope::Event::Text(event) => {
                if event.text.is_empty() || event.text.len() > MAXIMUM_TEXT_INPUT_BYTES {
                    return Err(HostWebRtcError::InvalidInputEnvelope);
                }
                self.input.text(&event.text)?;
                Ok(false)
            }
            reliable_input_envelope::Event::ReleaseAllInput(_) => {
                self.release_all()?;
                Ok(false)
            }
            reliable_input_envelope::Event::SessionControl(event) => {
                let action = SessionControlAction::try_from(event.action)
                    .map_err(|_| HostWebRtcError::InvalidInputEnvelope)?;
                match action {
                    SessionControlAction::Close | SessionControlAction::EmergencyStop => Ok(true),
                    SessionControlAction::Unspecified => Err(HostWebRtcError::InvalidInputEnvelope),
                }
            }
        }
    }

    fn release_all(&mut self) -> Result<(), HostWebRtcError> {
        let result = self.input.release_all();
        self.input_cleanup_pending = result.is_err();
        self.pressed_keys.clear();
        self.pressed_buttons.clear();
        result
    }
}

impl Drop for HostPeerSession {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct SessionLease {
    session_id: Vec<u8>,
    generation: u64,
}

impl fmt::Debug for SessionLease {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SessionLease")
            .field("generation", &self.generation)
            .field("session_id", &"[REDACTED]")
            .finish()
    }
}

pub struct SessionGate {
    active: Option<SessionLease>,
    generation: u64,
}

impl SessionGate {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            active: None,
            generation: 0,
        }
    }

    /// Acquires the single inbound session slot.
    ///
    /// # Errors
    ///
    /// Returns an error for invalid identity or an already active session.
    pub fn acquire(&mut self, session_id: &[u8]) -> Result<SessionLease, HostWebRtcError> {
        if session_id.len() != SESSION_ID_BYTES {
            return Err(HostWebRtcError::InvalidSession);
        }
        if self.active.is_some() {
            return Err(HostWebRtcError::DeviceBusy);
        }
        self.generation = self.generation.saturating_add(1);
        let lease = SessionLease {
            session_id: session_id.to_vec(),
            generation: self.generation,
        };
        self.active = Some(lease.clone());
        Ok(lease)
    }

    /// Releases only the currently active lease.
    ///
    /// # Errors
    ///
    /// Returns an error for a stale or unrelated lease.
    pub fn release(&mut self, lease: &SessionLease) -> Result<(), HostWebRtcError> {
        if self.active.as_ref() != Some(lease) {
            return Err(HostWebRtcError::InvalidLease);
        }
        self.active = None;
        Ok(())
    }
}

impl Default for SessionGate {
    fn default() -> Self {
        Self::new()
    }
}

fn validate_permissions(permissions: &[SessionPermission]) -> Result<(), HostWebRtcError> {
    if permissions.is_empty()
        || !permissions.contains(&SessionPermission::ViewScreen)
        || permissions.contains(&SessionPermission::Unspecified)
    {
        return Err(HostWebRtcError::InvalidPermissions);
    }
    let unique = permissions.iter().copied().collect::<BTreeSet<_>>();
    if unique.len() != permissions.len() {
        return Err(HostWebRtcError::InvalidPermissions);
    }
    Ok(())
}

fn validate_coordinates(x: i32, y: i32) -> Result<(), HostWebRtcError> {
    if !(0..=NORMALIZED_POINTER_MAX).contains(&x) || !(0..=NORMALIZED_POINTER_MAX).contains(&y) {
        return Err(HostWebRtcError::InvalidCoordinates);
    }
    Ok(())
}

fn validate_keyboard(usage: u32, modifier_bits: u32) -> Result<(), HostWebRtcError> {
    if !(MINIMUM_USB_HID_KEYBOARD_USAGE..=MAXIMUM_USB_HID_KEYBOARD_USAGE).contains(&usage) {
        return Err(HostWebRtcError::InvalidKeyboardUsage);
    }
    if modifier_bits > MAXIMUM_MODIFIER_BITS {
        return Err(HostWebRtcError::InvalidModifierBits);
    }
    Ok(())
}
