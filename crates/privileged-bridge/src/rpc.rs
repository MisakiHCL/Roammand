// SPDX-License-Identifier: MPL-2.0

use prost::Message;
use roammand_protocol::{
    roammand::v1::{
        PrivilegedBridgeClientFrame, PrivilegedBridgeServerFrame, privileged_bridge_server_frame,
    },
    validation::decode_and_validate_privileged_bridge_server_frame,
};

use crate::{
    client::BridgeRpc,
    framing::EventQueue,
    proxy::ProxyError,
    transport::{LocalBridgeTransport, TransportError},
};

pub struct FramedBridgeRpc {
    transport: Box<dyn LocalBridgeTransport>,
    events: EventQueue<PrivilegedBridgeServerFrame>,
    failed: bool,
}

impl FramedBridgeRpc {
    #[must_use]
    pub fn new(transport: Box<dyn LocalBridgeTransport>) -> Self {
        Self {
            transport,
            events: EventQueue::new(),
            failed: false,
        }
    }

    fn decode(encoded: &[u8]) -> Result<PrivilegedBridgeServerFrame, ProxyError> {
        decode_and_validate_privileged_bridge_server_frame(encoded)
            .map_err(|_| ProxyError::InvalidMessage)
    }

    fn enqueue_event(
        &mut self,
        frame: PrivilegedBridgeServerFrame,
    ) -> Result<Option<PrivilegedBridgeServerFrame>, ProxyError> {
        let Some(payload) = frame.payload.as_ref() else {
            return Err(ProxyError::InvalidMessage);
        };
        match payload {
            privileged_bridge_server_frame::Payload::FastPointer(_) => self
                .events
                .push_fast(frame)
                .map_err(|_| ProxyError::FailedClosed)
                .map(|()| None),
            privileged_bridge_server_frame::Payload::LocalIceCandidate(_)
            | privileged_bridge_server_frame::Payload::PeerStateChanged(_)
            | privileged_bridge_server_frame::Payload::ReliableInput(_) => self
                .events
                .push_critical(frame)
                .map_err(|_| ProxyError::FailedClosed)
                .map(|()| None),
            _ => Ok(Some(frame)),
        }
    }

    fn queued_event(&mut self) -> Result<Option<PrivilegedBridgeServerFrame>, ProxyError> {
        if let Some(event) = self
            .events
            .pop_critical()
            .map_err(|_| ProxyError::FailedClosed)?
        {
            return Ok(Some(event));
        }
        Ok(self.events.pop_fast())
    }

    fn reject<T>(&mut self, error: ProxyError) -> Result<T, ProxyError> {
        self.fail_closed();
        Err(error)
    }
}

impl BridgeRpc for FramedBridgeRpc {
    fn call(
        &mut self,
        request: PrivilegedBridgeClientFrame,
    ) -> Result<PrivilegedBridgeServerFrame, ProxyError> {
        if self.failed {
            return Err(ProxyError::FailedClosed);
        }
        if let Err(error) = self.transport.send(&request.encode_to_vec()) {
            return self.reject(map_transport_error(error));
        }
        loop {
            let encoded = match self.transport.receive() {
                Ok(encoded) => encoded,
                Err(error) => return self.reject(map_transport_error(error)),
            };
            let response = match Self::decode(&encoded) {
                Ok(response) => response,
                Err(error) => return self.reject(error),
            };
            let response = match self.enqueue_event(response) {
                Ok(None) => continue,
                Ok(Some(response)) => response,
                Err(error) => return self.reject(error),
            };
            if response.request_id != request.request_id || response.sequence != request.sequence {
                return self.reject(ProxyError::StaleResponse);
            }
            return Ok(response);
        }
    }

    fn try_event(&mut self) -> Result<Option<PrivilegedBridgeServerFrame>, ProxyError> {
        if self.failed {
            return Err(ProxyError::FailedClosed);
        }
        if let Some(event) = self.queued_event()? {
            return Ok(Some(event));
        }
        let encoded = match self.transport.try_receive() {
            Ok(Some(encoded)) => encoded,
            Ok(None) => return Ok(None),
            Err(error) => return self.reject(map_transport_error(error)),
        };
        let frame = match Self::decode(&encoded) {
            Ok(frame) => frame,
            Err(error) => return self.reject(error),
        };
        match self.enqueue_event(frame) {
            Ok(None) => self.queued_event(),
            Ok(Some(_)) => self.reject(ProxyError::StaleResponse),
            Err(error) => self.reject(error),
        }
    }

    fn fail_closed(&mut self) {
        if !self.failed {
            self.failed = true;
            self.transport.fail_closed();
        }
    }
}

const fn map_transport_error(_error: TransportError) -> ProxyError {
    ProxyError::Transport
}
