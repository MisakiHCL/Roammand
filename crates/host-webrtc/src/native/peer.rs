// SPDX-License-Identifier: MPL-2.0

use std::{
    collections::BTreeSet,
    fmt,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc::{Receiver, RecvTimeoutError, SyncSender, TryRecvError, TrySendError, sync_channel},
    },
    time::{Duration, Instant},
};

use futures::executor::block_on;
use libwebrtc::{
    MediaType,
    data_channel::{DataChannel, DataChannelState},
    ice_candidate::IceCandidate,
    media_stream_track::MediaStreamTrack,
    peer_connection::{AnswerOptions, PeerConnection, PeerConnectionState},
    peer_connection_factory::{
        ContinualGatheringPolicy, IceServer, IceTransportsType, PeerConnectionFactory,
        RtcConfiguration, native::PeerConnectionFactoryExt,
    },
    rtp_parameters::RtpCodecCapability,
    rtp_transceiver::RtpTransceiver,
    session_description::{SdpType, SessionDescription},
    video_source::native::NativeVideoSource,
    video_track::RtcVideoTrack,
};
use roammand_protocol::protocol_limits::{
    MAX_ICE_CANDIDATE_UTF8_BYTES, MAX_POINTER_FAST_ENVELOPE_BYTES,
    MAX_RELIABLE_INPUT_ENVELOPE_BYTES, MAX_SDP_MID_UTF8_BYTES,
};
use thiserror::Error;

use super::capture::CapturePipeline;
use crate::{
    DATA_CHANNEL_INPUT_RELIABLE, DATA_CHANNEL_POINTER_FAST, HostWebRtcError, IceTransportPolicy,
    PeerAnswer, PeerBackend, PeerIceCandidate, SessionConfig,
};

const EVENT_QUEUE_CAPACITY: usize = 256;
const FAST_EVENT_POLL_INTERVAL: Duration = Duration::from_millis(5);
const VIDEO_STREAM_ID: &str = "roammand-screen";
const VIDEO_TRACK_ID: &str = "roammand-main-display";

#[derive(Clone)]
pub struct NativeIceServer {
    pub urls: Vec<String>,
    pub username: String,
    pub password: String,
}

impl fmt::Debug for NativeIceServer {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("NativeIceServer")
            .field("url_count", &self.urls.len())
            .field("has_username", &!self.username.is_empty())
            .field("has_password", &!self.password.is_empty())
            .finish()
    }
}

#[derive(Clone, Default)]
pub struct NativePeerOptions {
    pub ice_servers: Vec<NativeIceServer>,
}

impl fmt::Debug for NativePeerOptions {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("NativePeerOptions")
            .field("ice_server_count", &self.ice_servers.len())
            .finish()
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum NativeDataChannelKind {
    ReliableInput,
    FastPointer,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeConnectionState {
    Connected,
    Disconnected,
    Failed,
}

#[derive(Clone, Eq, PartialEq)]
pub enum NativePeerEvent {
    Connection(NativeConnectionState),
    LocalIceCandidate(PeerIceCandidate),
    ReliableInput(Vec<u8>),
    FastPointer(Vec<u8>),
}

impl fmt::Debug for NativePeerEvent {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let (kind, payload_bytes) = match self {
            Self::Connection(_) => ("connection", 0),
            Self::LocalIceCandidate(_) => ("local_ice_candidate", 0),
            Self::ReliableInput(encoded) => ("reliable_input", encoded.len()),
            Self::FastPointer(encoded) => ("fast_pointer", encoded.len()),
        };
        formatter
            .debug_struct("NativePeerEvent")
            .field("kind", &kind)
            .field("payload_bytes", &payload_bytes)
            .finish()
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum NativePeerEventReceiveError {
    #[error("native peer event queue is empty")]
    Empty,
    #[error("native peer event queue is disconnected")]
    Disconnected,
    #[error("native peer critical event queue overflowed")]
    Overflow,
}

pub struct NativePeerEvents {
    receiver: Receiver<NativePeerEvent>,
    latest_fast_pointer: Arc<Mutex<Option<Vec<u8>>>>,
    overflowed: Arc<AtomicBool>,
}

impl NativePeerEvents {
    /// Receives one bounded native peer event.
    ///
    /// # Errors
    ///
    /// Returns an empty, disconnected, or critical-overflow error.
    pub fn recv_timeout(
        &self,
        timeout: Duration,
    ) -> Result<NativePeerEvent, NativePeerEventReceiveError> {
        let deadline = Instant::now().checked_add(timeout);
        loop {
            if self.overflowed.swap(false, Ordering::AcqRel) {
                return Err(NativePeerEventReceiveError::Overflow);
            }
            match self.receiver.try_recv() {
                Ok(event) => return Ok(event),
                Err(TryRecvError::Disconnected) => {
                    return Err(NativePeerEventReceiveError::Disconnected);
                }
                Err(TryRecvError::Empty) => {}
            }
            match self.latest_fast_pointer.lock() {
                Ok(mut latest) => {
                    if let Some(payload) = latest.take() {
                        return Ok(NativePeerEvent::FastPointer(payload));
                    }
                }
                Err(_) => return Err(NativePeerEventReceiveError::Overflow),
            }
            let Some(remaining) =
                deadline.and_then(|value| value.checked_duration_since(Instant::now()))
            else {
                return Err(NativePeerEventReceiveError::Empty);
            };
            match self
                .receiver
                .recv_timeout(remaining.min(FAST_EVENT_POLL_INTERVAL))
            {
                Ok(event) => return Ok(event),
                Err(RecvTimeoutError::Disconnected) => {
                    return Err(NativePeerEventReceiveError::Disconnected);
                }
                Err(RecvTimeoutError::Timeout) => {}
            }
        }
    }
}

#[derive(Clone)]
struct EventPublisher {
    sender: SyncSender<NativePeerEvent>,
    latest_fast_pointer: Arc<Mutex<Option<Vec<u8>>>>,
    overflowed: Arc<AtomicBool>,
}

impl EventPublisher {
    fn critical(&self, event: NativePeerEvent) {
        if let Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) =
            self.sender.try_send(event)
        {
            self.overflowed.store(true, Ordering::Release);
        }
    }

    fn fast_pointer(&self, payload: Vec<u8>) {
        if let Ok(mut latest) = self.latest_fast_pointer.lock() {
            *latest = Some(payload);
        } else {
            self.overflowed.store(true, Ordering::Release);
        }
    }
}

pub struct NativePeerBackend {
    options: NativePeerOptions,
    publisher: EventPublisher,
    resources: Option<NativeResources>,
}

impl NativePeerBackend {
    #[must_use]
    pub fn new(options: NativePeerOptions) -> (Self, NativePeerEvents) {
        let (sender, receiver) = sync_channel(EVENT_QUEUE_CAPACITY);
        let latest_fast_pointer = Arc::new(Mutex::new(None));
        let overflowed = Arc::new(AtomicBool::new(false));
        (
            Self {
                options,
                publisher: EventPublisher {
                    sender,
                    latest_fast_pointer: Arc::clone(&latest_fast_pointer),
                    overflowed: Arc::clone(&overflowed),
                },
                resources: None,
            },
            NativePeerEvents {
                receiver,
                latest_fast_pointer,
                overflowed,
            },
        )
    }

    fn start_inner(
        &mut self,
        config: &SessionConfig,
        offer_sdp: &str,
    ) -> Result<PeerAnswer, HostWebRtcError> {
        if self.resources.is_some() {
            return Err(HostWebRtcError::InvalidState);
        }
        let capture = CapturePipeline::start()?;
        let video_source = capture.source();
        let factory = PeerConnectionFactory::default();
        let peer = factory
            .create_peer_connection(rtc_configuration(config, &self.options))
            .map_err(|_| HostWebRtcError::PeerFailure)?;
        let channels = Arc::new(Mutex::new(Vec::new()));
        configure_callbacks(&peer, self.publisher.clone(), Arc::clone(&channels));

        if let Err(error) = apply_remote_offer(&peer, offer_sdp) {
            peer.close();
            return Err(error);
        }
        let track = factory.create_video_track(VIDEO_TRACK_ID, video_source.clone());
        let track_id = track.id();
        if peer
            .add_track(MediaStreamTrack::from(track.clone()), &[VIDEO_STREAM_ID])
            .is_err()
        {
            peer.close();
            return Err(HostWebRtcError::PeerFailure);
        }
        let Some(transceiver) = peer.transceivers().into_iter().find(|transceiver| {
            transceiver
                .sender()
                .track()
                .is_some_and(|attached| attached.id() == track_id)
        }) else {
            peer.close();
            return Err(HostWebRtcError::PeerFailure);
        };
        let available_codecs = factory.get_rtp_sender_capabilities(MediaType::Video).codecs;
        let codecs = preferred_codec_capabilities(&available_codecs);
        if codecs.is_empty() {
            peer.close();
            return Err(HostWebRtcError::PeerFailure);
        }
        if transceiver.set_codec_preferences(codecs).is_err() {
            peer.close();
            return Err(HostWebRtcError::PeerFailure);
        }
        let answer = match create_local_answer(&peer) {
            Ok(answer) => answer,
            Err(error) => {
                peer.close();
                return Err(error);
            }
        };

        self.resources = Some(NativeResources {
            factory,
            peer,
            capture,
            video_source,
            track,
            transceiver,
            channels,
        });
        Ok(answer)
    }

    fn negotiate_answer(&self, offer_sdp: &str) -> Result<PeerAnswer, HostWebRtcError> {
        let resources = self
            .resources
            .as_ref()
            .ok_or(HostWebRtcError::InvalidState)?;
        apply_remote_offer(&resources.peer, offer_sdp)?;
        create_local_answer(&resources.peer)
    }

    fn shutdown(&mut self) {
        let Some(mut resources) = self.resources.take() else {
            return;
        };
        resources.capture.stop();
        resources.peer.on_connection_state_change(None);
        resources.peer.on_data_channel(None);
        resources.peer.on_ice_candidate(None);
        if let Ok(mut channels) = resources.channels.lock() {
            for channel in channels.drain(..) {
                channel.on_message(None);
                channel.on_state_change(None);
                channel.close();
            }
        }
        resources.peer.close();
    }
}

fn apply_remote_offer(peer: &PeerConnection, offer_sdp: &str) -> Result<(), HostWebRtcError> {
    let offer = SessionDescription::parse(offer_sdp, SdpType::Offer)
        .map_err(|_| HostWebRtcError::InvalidSdp)?;
    block_on(peer.set_remote_description(offer)).map_err(|_| HostWebRtcError::PeerFailure)
}

fn create_local_answer(peer: &PeerConnection) -> Result<PeerAnswer, HostWebRtcError> {
    let answer = block_on(peer.create_answer(AnswerOptions::default()))
        .map_err(|_| HostWebRtcError::PeerFailure)?;
    block_on(peer.set_local_description(answer.clone()))
        .map_err(|_| HostWebRtcError::PeerFailure)?;
    let sdp = answer.to_string();
    if !video_section_can_send(&sdp) {
        return Err(HostWebRtcError::PeerFailure);
    }
    let fingerprint = parse_dtls_sha256_fingerprint(&sdp).ok_or(HostWebRtcError::InvalidAnswer)?;
    Ok(PeerAnswer {
        sdp,
        dtls_fingerprint_sha256: fingerprint,
    })
}

fn video_section_can_send(sdp: &str) -> bool {
    let mut lines = sdp.lines();
    let Some(media) = lines.find(|line| line.starts_with("m=video ")) else {
        return false;
    };
    if media.split_whitespace().nth(1) == Some("0") {
        return false;
    }
    for line in lines {
        if line.starts_with("m=") {
            break;
        }
        match line.trim_end_matches('\r') {
            "a=sendonly" | "a=sendrecv" => return true,
            "a=recvonly" | "a=inactive" => return false,
            _ => {}
        }
    }
    true
}

impl PeerBackend for NativePeerBackend {
    fn start(
        &mut self,
        config: &SessionConfig,
        offer_sdp: &str,
    ) -> Result<PeerAnswer, HostWebRtcError> {
        let result = self.start_inner(config, offer_sdp);
        if result.is_err() {
            self.shutdown();
        }
        result
    }

    fn restart(
        &mut self,
        _config: &SessionConfig,
        offer_sdp: &str,
    ) -> Result<PeerAnswer, HostWebRtcError> {
        self.negotiate_answer(offer_sdp)
    }

    fn add_remote_ice_candidate(
        &mut self,
        candidate: &PeerIceCandidate,
    ) -> Result<(), HostWebRtcError> {
        if candidate.candidate.is_empty()
            || candidate.candidate.len() > MAX_ICE_CANDIDATE_UTF8_BYTES
            || candidate.sdp_mid.len() > MAX_SDP_MID_UTF8_BYTES
        {
            return Err(HostWebRtcError::PeerFailure);
        }
        let m_line_index =
            i32::try_from(candidate.sdp_m_line_index).map_err(|_| HostWebRtcError::PeerFailure)?;
        let parsed = IceCandidate::parse(&candidate.sdp_mid, m_line_index, &candidate.candidate)
            .map_err(|_| HostWebRtcError::PeerFailure)?;
        let peer = &self
            .resources
            .as_ref()
            .ok_or(HostWebRtcError::InvalidState)?
            .peer;
        block_on(peer.add_ice_candidate(parsed)).map_err(|_| HostWebRtcError::PeerFailure)
    }

    fn close(&mut self) -> Result<(), HostWebRtcError> {
        self.shutdown();
        Ok(())
    }
}

impl Drop for NativePeerBackend {
    fn drop(&mut self) {
        self.shutdown();
    }
}

struct NativeResources {
    factory: PeerConnectionFactory,
    peer: PeerConnection,
    capture: CapturePipeline,
    video_source: NativeVideoSource,
    track: RtcVideoTrack,
    transceiver: RtpTransceiver,
    channels: Arc<Mutex<Vec<DataChannel>>>,
}

impl fmt::Debug for NativeResources {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("NativeResources")
            .field("peer", &self.peer)
            .field("video_source", &self.video_source)
            .field("track", &self.track)
            .field("transceiver", &self.transceiver)
            .field(
                "channel_count",
                &self.channels.lock().map_or(0, |channels| channels.len()),
            )
            .field("factory", &self.factory)
            .finish_non_exhaustive()
    }
}

fn rtc_configuration(config: &SessionConfig, options: &NativePeerOptions) -> RtcConfiguration {
    RtcConfiguration {
        ice_servers: options
            .ice_servers
            .iter()
            .map(|server| IceServer {
                urls: server.urls.clone(),
                username: server.username.clone(),
                password: server.password.clone(),
            })
            .collect(),
        continual_gathering_policy: ContinualGatheringPolicy::GatherContinually,
        ice_transport_type: match config.ice_transport_policy() {
            IceTransportPolicy::All => IceTransportsType::All,
            IceTransportPolicy::Relay => IceTransportsType::Relay,
        },
    }
}

fn configure_callbacks(
    peer: &PeerConnection,
    publisher: EventPublisher,
    channels: Arc<Mutex<Vec<DataChannel>>>,
) {
    let connection_publisher = publisher.clone();
    peer.on_connection_state_change(Some(Box::new(move |state| {
        let state = match state {
            PeerConnectionState::Connected => Some(NativeConnectionState::Connected),
            PeerConnectionState::Disconnected | PeerConnectionState::Closed => {
                Some(NativeConnectionState::Disconnected)
            }
            PeerConnectionState::Failed => Some(NativeConnectionState::Failed),
            PeerConnectionState::New | PeerConnectionState::Connecting => None,
        };
        if let Some(state) = state {
            connection_publisher.critical(NativePeerEvent::Connection(state));
        }
    })));

    let ice_publisher = publisher.clone();
    peer.on_ice_candidate(Some(Box::new(move |candidate| {
        let Ok(sdp_m_line_index) = u32::try_from(candidate.sdp_mline_index()) else {
            ice_publisher.overflowed.store(true, Ordering::Release);
            return;
        };
        ice_publisher.critical(NativePeerEvent::LocalIceCandidate(PeerIceCandidate {
            candidate: candidate.candidate(),
            sdp_mid: candidate.sdp_mid(),
            sdp_m_line_index,
        }));
    })));

    let data_publisher = publisher;
    let labels = Arc::new(Mutex::new(BTreeSet::new()));
    peer.on_data_channel(Some(Box::new(move |channel| {
        let Some(kind) = classify_data_channel(&channel.label()) else {
            channel.close();
            return;
        };
        let accepted = labels.lock().is_ok_and(|mut labels| labels.insert(kind));
        if !accepted {
            channel.close();
            data_publisher.overflowed.store(true, Ordering::Release);
            return;
        }
        let message_publisher = data_publisher.clone();
        channel.on_message(Some(Box::new(move |buffer| {
            if !buffer.binary {
                message_publisher.overflowed.store(true, Ordering::Release);
                return;
            }
            publish_input_payload(&message_publisher, kind, buffer.data);
        })));
        let state_publisher = data_publisher.clone();
        channel.on_state_change(Some(Box::new(move |state| {
            if state == DataChannelState::Closed {
                state_publisher.critical(NativePeerEvent::Connection(
                    NativeConnectionState::Disconnected,
                ));
            }
        })));
        if let Ok(mut channels) = channels.lock() {
            channels.push(channel);
        } else {
            channel.close();
            data_publisher.overflowed.store(true, Ordering::Release);
        }
    })));
}

fn publish_input_payload(publisher: &EventPublisher, kind: NativeDataChannelKind, data: &[u8]) {
    // Validate the borrowed native payload before allocating its owned copy.
    match kind {
        NativeDataChannelKind::ReliableInput if data.len() > MAX_RELIABLE_INPUT_ENVELOPE_BYTES => {
            publisher.overflowed.store(true, Ordering::Release);
            return;
        }
        NativeDataChannelKind::FastPointer if data.len() > MAX_POINTER_FAST_ENVELOPE_BYTES => {
            return;
        }
        _ => {}
    }
    let payload = data.to_vec();
    match kind {
        NativeDataChannelKind::ReliableInput => {
            publisher.critical(NativePeerEvent::ReliableInput(payload));
        }
        NativeDataChannelKind::FastPointer => publisher.fast_pointer(payload),
    }
}

#[must_use]
pub fn classify_data_channel(label: &str) -> Option<NativeDataChannelKind> {
    if label == DATA_CHANNEL_INPUT_RELIABLE {
        Some(NativeDataChannelKind::ReliableInput)
    } else if label == DATA_CHANNEL_POINTER_FAST {
        Some(NativeDataChannelKind::FastPointer)
    } else {
        None
    }
}

#[must_use]
pub fn preferred_video_codec_mime_types(available: &[String]) -> Vec<String> {
    ["video/H264", "video/VP8"]
        .into_iter()
        .flat_map(|preferred| {
            available
                .iter()
                .filter(move |mime| mime.eq_ignore_ascii_case(preferred))
                .cloned()
        })
        .collect()
}

fn preferred_codec_capabilities(available: &[RtpCodecCapability]) -> Vec<RtpCodecCapability> {
    ["video/H264", "video/VP8"]
        .into_iter()
        .flat_map(|preferred| {
            available
                .iter()
                .filter(move |codec| codec.mime_type.eq_ignore_ascii_case(preferred))
                .cloned()
        })
        .collect()
}

#[must_use]
pub fn probe_native_video_codecs() -> Vec<String> {
    PeerConnectionFactory::default()
        .get_rtp_sender_capabilities(MediaType::Video)
        .codecs
        .into_iter()
        .map(|codec| codec.mime_type)
        .collect()
}

#[must_use]
pub fn parse_dtls_sha256_fingerprint(sdp: &str) -> Option<Vec<u8>> {
    let encoded = sdp.lines().find_map(|line| {
        let value = line.trim_end_matches('\r').strip_prefix("a=fingerprint:")?;
        let (algorithm, fingerprint) = value.split_once(' ')?;
        algorithm
            .eq_ignore_ascii_case("sha-256")
            .then_some(fingerprint)
    })?;
    let parts = encoded.split(':').collect::<Vec<_>>();
    if parts.len() != 32 || parts.iter().any(|part| part.len() != 2) {
        return None;
    }
    parts
        .into_iter()
        .map(|part| u8::from_str_radix(part, 16).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oversized_input_payloads_do_not_enter_event_queues() {
        let (peer, events) = NativePeerBackend::new(NativePeerOptions::default());
        publish_input_payload(&peer.publisher, NativeDataChannelKind::FastPointer, &[7]);
        publish_input_payload(
            &peer.publisher,
            NativeDataChannelKind::FastPointer,
            &vec![0; MAX_POINTER_FAST_ENVELOPE_BYTES + 1],
        );
        assert_eq!(
            events.recv_timeout(Duration::ZERO),
            Ok(NativePeerEvent::FastPointer(vec![7]))
        );

        publish_input_payload(
            &peer.publisher,
            NativeDataChannelKind::ReliableInput,
            &vec![0; MAX_RELIABLE_INPUT_ENVELOPE_BYTES + 1],
        );
        assert_eq!(
            events.recv_timeout(Duration::ZERO),
            Err(NativePeerEventReceiveError::Overflow)
        );
        assert_eq!(
            events.recv_timeout(Duration::ZERO),
            Err(NativePeerEventReceiveError::Empty)
        );
    }

    #[test]
    fn fast_pointer_events_coalesce_without_filling_the_critical_queue() {
        let (peer, events) = NativePeerBackend::new(NativePeerOptions::default());
        for value in 0..(EVENT_QUEUE_CAPACITY * 2) {
            peer.publisher.fast_pointer(value.to_be_bytes().to_vec());
        }
        peer.publisher.critical(NativePeerEvent::Connection(
            NativeConnectionState::Connected,
        ));

        assert_eq!(
            events.recv_timeout(Duration::ZERO),
            Ok(NativePeerEvent::Connection(
                NativeConnectionState::Connected
            ))
        );
        assert_eq!(
            events.recv_timeout(Duration::ZERO),
            Ok(NativePeerEvent::FastPointer(
                ((EVENT_QUEUE_CAPACITY * 2) - 1).to_be_bytes().to_vec()
            ))
        );
    }

    #[test]
    fn critical_queue_overflow_remains_fail_closed() {
        let (peer, events) = NativePeerBackend::new(NativePeerOptions::default());
        for _ in 0..=EVENT_QUEUE_CAPACITY {
            peer.publisher.critical(NativePeerEvent::Connection(
                NativeConnectionState::Connected,
            ));
        }

        assert_eq!(
            events.recv_timeout(Duration::ZERO),
            Err(NativePeerEventReceiveError::Overflow)
        );
    }
}
