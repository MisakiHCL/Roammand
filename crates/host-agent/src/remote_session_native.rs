// SPDX-License-Identifier: MPL-2.0

use roammand_host_webrtc::{
    SessionConfig,
    native::{
        NativeConnectionState, NativePeerBackend, NativePeerEvent, NativePeerEventReceiveError,
        NativePeerEvents, NativePeerOptions,
    },
};

use crate::{
    RemotePeerEvent, RemotePeerEventSource, RemoteSessionContext, RemoteSessionError,
    RemoteSessionFactory, RemoteSessionParts,
};

pub struct NativeRemoteSessionFactory {
    options: NativePeerOptions,
}

impl NativeRemoteSessionFactory {
    #[must_use]
    pub const fn new(options: NativePeerOptions) -> Self {
        Self { options }
    }
}

impl RemoteSessionFactory for NativeRemoteSessionFactory {
    fn create(
        &mut self,
        _config: &SessionConfig,
        _context: &RemoteSessionContext,
    ) -> Result<RemoteSessionParts, RemoteSessionError> {
        let input =
            roammand_host_platform::remote_input_sink(false).map_err(|error| match error {
                roammand_host_platform::PlatformInputError::PermissionDenied => {
                    RemoteSessionError::InputPermission
                }
                _ => RemoteSessionError::Input,
            })?;
        let (peer, events) = NativePeerBackend::new(self.options.clone());
        Ok(RemoteSessionParts::new(
            Box::new(peer),
            input,
            Box::new(NativeEventSource(events)),
        ))
    }
}

struct NativeEventSource(NativePeerEvents);

impl RemotePeerEventSource for NativeEventSource {
    fn try_recv(&self) -> Result<Option<RemotePeerEvent>, RemoteSessionError> {
        match self.0.recv_timeout(std::time::Duration::ZERO) {
            Ok(NativePeerEvent::Connection(NativeConnectionState::Connected)) => {
                Ok(Some(RemotePeerEvent::Connected))
            }
            Ok(NativePeerEvent::Connection(NativeConnectionState::Disconnected)) => {
                Ok(Some(RemotePeerEvent::Disconnected))
            }
            Ok(NativePeerEvent::Connection(NativeConnectionState::Failed)) => {
                Ok(Some(RemotePeerEvent::Failed))
            }
            Ok(NativePeerEvent::LocalIceCandidate(candidate)) => {
                Ok(Some(RemotePeerEvent::LocalIceCandidate(candidate)))
            }
            Ok(NativePeerEvent::ReliableInput(encoded)) => {
                Ok(Some(RemotePeerEvent::ReliableInput(encoded)))
            }
            Ok(NativePeerEvent::FastPointer(encoded)) => {
                Ok(Some(RemotePeerEvent::FastPointer(encoded)))
            }
            Err(NativePeerEventReceiveError::Empty) => Ok(None),
            Err(
                NativePeerEventReceiveError::Disconnected
                | NativePeerEventReceiveError::Overflow
                | NativePeerEventReceiveError::CaptureFailed,
            ) => Err(RemoteSessionError::Peer),
        }
    }
}
