// SPDX-License-Identifier: MPL-2.0

use std::{fmt, time::Duration};

use roammand_host_webrtc::{
    IceTransportPolicy, PeerBackend, PeerIceCandidate, RemoteInputSink, SessionConfig,
    native::{
        NativeConnectionState, NativeIceServer, NativePeerBackend, NativePeerEvent,
        NativePeerEventReceiveError, NativePeerEvents, NativePeerOptions,
    },
};
use roammand_protocol::roammand::v1::{
    ButtonAction, IceCandidate, KeyboardAction, PointerButton, PrivilegedIceTransportPolicy,
    PrivilegedInputCommand, PrivilegedPeerConfiguration, WebRtcSessionDescription,
    privileged_input_command,
};

use crate::{
    helper::{HelperBackend, HelperProtocolError},
    native_indicator::NativeIndicatorClient,
    proxy::ProxyEvent,
};

pub struct NativeHelperBackend {
    peer: Option<NativePeerBackend>,
    events: Option<NativePeerEvents>,
    input: Option<Box<dyn RemoteInputSink>>,
    secure_attention_allowed: bool,
    indicator: Option<NativeIndicatorClient>,
}

impl NativeHelperBackend {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            peer: None,
            events: None,
            input: None,
            secure_attention_allowed: false,
            indicator: None,
        }
    }

    #[must_use]
    pub const fn with_secure_attention(mut self, allowed: bool) -> Self {
        self.secure_attention_allowed = allowed;
        self
    }

    #[must_use]
    pub fn with_indicator(mut self, indicator: NativeIndicatorClient) -> Self {
        self.indicator = Some(indicator);
        self
    }

    fn create_peer(
        &mut self,
        configuration: &PrivilegedPeerConfiguration,
    ) -> Result<SessionConfig, HelperProtocolError> {
        self.close()?;
        let config = session_config(configuration)?;
        let input = roammand_host_platform::remote_input_sink(false)
            .map_err(|_| HelperProtocolError::Backend)?;
        let options = NativePeerOptions {
            ice_servers: configuration
                .ice_servers
                .iter()
                .map(|server| NativeIceServer {
                    urls: server.urls.clone(),
                    username: server.username.clone(),
                    password: server.credential.clone(),
                })
                .collect(),
        };
        let (peer, events) = NativePeerBackend::new(options);
        self.peer = Some(peer);
        self.events = Some(events);
        self.input = Some(input);
        Ok(config)
    }

    fn peer(&mut self) -> Result<&mut NativePeerBackend, HelperProtocolError> {
        self.peer.as_mut().ok_or(HelperProtocolError::Backend)
    }

    fn input_sink(&mut self) -> Result<&mut dyn RemoteInputSink, HelperProtocolError> {
        match self.input.as_mut() {
            Some(input) => Ok(input.as_mut()),
            None => Err(HelperProtocolError::Backend),
        }
    }
}

impl Default for NativeHelperBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl fmt::Debug for NativeHelperBackend {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("NativeHelperBackend")
            .field("peer_active", &self.peer.is_some())
            .field("input_active", &self.input.is_some())
            .field("indicator_configured", &self.indicator.is_some())
            .finish_non_exhaustive()
    }
}

impl HelperBackend for NativeHelperBackend {
    fn start(
        &mut self,
        configuration: &PrivilegedPeerConfiguration,
        offer: &WebRtcSessionDescription,
        controller_display_name: &str,
    ) -> Result<roammand_host_webrtc::PeerAnswer, HelperProtocolError> {
        let config = self.create_peer(configuration)?;
        let answer = self
            .peer()?
            .start(&config, &offer.sdp)
            .map_err(|_| HelperProtocolError::Backend)?;
        if self
            .indicator
            .as_ref()
            .is_some_and(|indicator| indicator.show_controlled(controller_display_name).is_err())
        {
            self.fail_closed();
            return Err(HelperProtocolError::Backend);
        }
        Ok(answer)
    }

    fn restart(
        &mut self,
        configuration: &PrivilegedPeerConfiguration,
        offer: &WebRtcSessionDescription,
        controller_display_name: &str,
    ) -> Result<roammand_host_webrtc::PeerAnswer, HelperProtocolError> {
        let config = session_config(configuration)?;
        let answer = self
            .peer()?
            .restart(&config, &offer.sdp)
            .map_err(|_| HelperProtocolError::Backend)?;
        if self
            .indicator
            .as_ref()
            .is_some_and(|indicator| indicator.show_controlled(controller_display_name).is_err())
        {
            self.fail_closed();
            return Err(HelperProtocolError::Backend);
        }
        Ok(answer)
    }

    fn add_candidate(&mut self, candidate: &IceCandidate) -> Result<(), HelperProtocolError> {
        self.peer()?
            .add_remote_ice_candidate(&PeerIceCandidate {
                candidate: candidate.candidate.clone(),
                sdp_mid: candidate.sdp_mid.clone(),
                sdp_m_line_index: candidate.sdp_m_line_index,
            })
            .map_err(|_| HelperProtocolError::Backend)
    }

    fn input(&mut self, command: &PrivilegedInputCommand) -> Result<(), HelperProtocolError> {
        let input = command
            .input
            .as_ref()
            .ok_or(HelperProtocolError::InvalidMessage)?;
        let sink = self.input_sink()?;
        match input {
            privileged_input_command::Input::Keyboard(value) => sink.keyboard(
                KeyboardAction::try_from(value.action)
                    .map_err(|_| HelperProtocolError::InvalidMessage)?,
                value.usb_hid_usage,
                value.modifier_bits,
            ),
            privileged_input_command::Input::PointerButton(value) => sink.pointer_button(
                PointerButton::try_from(value.button)
                    .map_err(|_| HelperProtocolError::InvalidMessage)?,
                ButtonAction::try_from(value.action)
                    .map_err(|_| HelperProtocolError::InvalidMessage)?,
                value.x,
                value.y,
            ),
            privileged_input_command::Input::Text(value) => sink.text(&value.text),
            privileged_input_command::Input::PointerMove(value) => {
                sink.pointer_move(value.x, value.y, value.pressed_button_bits)
            }
            privileged_input_command::Input::PointerScroll(value) => {
                sink.pointer_scroll(value.delta_x, value.delta_y)
            }
            privileged_input_command::Input::ReleaseAll(_) => sink.release_all(),
        }
        .map_err(|_| HelperProtocolError::Backend)
    }

    fn secure_attention(&mut self) -> Result<(), HelperProtocolError> {
        if !self.secure_attention_allowed {
            return Err(HelperProtocolError::Backend);
        }
        #[cfg(windows)]
        return crate::windows_process_runtime::send_secure_attention()
            .map_err(|_| HelperProtocolError::Backend);

        #[cfg(not(windows))]
        Err(HelperProtocolError::Backend)
    }

    fn close(&mut self) -> Result<(), HelperProtocolError> {
        let input_result = self
            .input
            .as_mut()
            .map_or(Ok(()), |input| input.release_all())
            .map_err(|_| HelperProtocolError::Backend);
        let peer_result = self
            .peer
            .as_mut()
            .map_or(Ok(()), PeerBackend::close)
            .map_err(|_| HelperProtocolError::Backend);
        self.input = None;
        self.events = None;
        self.peer = None;
        if let Some(indicator) = &self.indicator {
            indicator.hide();
        }
        input_result.and(peer_result)
    }

    fn try_event(&mut self) -> Result<Option<ProxyEvent>, HelperProtocolError> {
        if self
            .indicator
            .as_ref()
            .is_some_and(NativeIndicatorClient::take_local_stop)
        {
            log_native_helper_failure("localStop", "requested");
            self.fail_closed();
            return Ok(Some(ProxyEvent::LocalStop));
        }
        let Some(events) = self.events.as_ref() else {
            return Ok(None);
        };
        match events.recv_timeout(Duration::ZERO) {
            Ok(NativePeerEvent::Connection(NativeConnectionState::Connected)) => {
                Ok(Some(ProxyEvent::Connected))
            }
            Ok(NativePeerEvent::Connection(NativeConnectionState::Disconnected)) => {
                Ok(Some(ProxyEvent::Disconnected))
            }
            Ok(NativePeerEvent::Connection(NativeConnectionState::Failed)) => {
                Ok(Some(ProxyEvent::Failed))
            }
            Ok(NativePeerEvent::LocalIceCandidate(candidate)) => {
                Ok(Some(ProxyEvent::LocalIceCandidate(candidate)))
            }
            Ok(NativePeerEvent::ReliableInput(encoded)) => {
                Ok(Some(ProxyEvent::ReliableInput(encoded)))
            }
            Ok(NativePeerEvent::FastPointer(encoded)) => Ok(Some(ProxyEvent::FastPointer(encoded))),
            Err(NativePeerEventReceiveError::Empty) => Ok(None),
            Err(
                error @ (NativePeerEventReceiveError::Disconnected
                | NativePeerEventReceiveError::Overflow
                | NativePeerEventReceiveError::CaptureFailed),
            ) => {
                log_native_helper_failure("eventQueue", error);
                Err(HelperProtocolError::Backend)
            }
        }
    }

    fn fail_closed(&mut self) {
        let _ = self.close();
    }
}

fn log_native_helper_failure(operation: &str, cause: impl fmt::Debug) {
    eprintln!("[remote] helper_operation={operation} cause={cause:?}");
}

fn session_config(
    configuration: &PrivilegedPeerConfiguration,
) -> Result<SessionConfig, HelperProtocolError> {
    let policy = match PrivilegedIceTransportPolicy::try_from(configuration.ice_transport_policy) {
        Ok(PrivilegedIceTransportPolicy::All) => IceTransportPolicy::All,
        Ok(PrivilegedIceTransportPolicy::Relay) => IceTransportPolicy::Relay,
        Ok(PrivilegedIceTransportPolicy::Unspecified) | Err(_) => {
            return Err(HelperProtocolError::InvalidMessage);
        }
    };
    Ok(SessionConfig::new(policy))
}
