// SPDX-License-Identifier: MPL-2.0

use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{Receiver, RecvTimeoutError, SyncSender, sync_channel},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use crate::HostWebRtcError;
#[cfg(target_os = "macos")]
use core_graphics::access::ScreenCaptureAccess;
#[cfg(not(target_os = "macos"))]
use libwebrtc::desktop_capturer::{
    CaptureError, CaptureSource, DesktopCaptureSourceType, DesktopCapturer, DesktopCapturerOptions,
    DesktopFrame,
};
use libwebrtc::{
    native::yuv_helper,
    video_frame::{I420Buffer, VideoFrame, VideoRotation},
    video_source::{VideoResolution, native::NativeVideoSource},
};

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
use macos::DesktopCaptureDriver;

const BYTES_PER_DESKTOP_PIXEL: u32 = 4;
const CAPTURE_FRAME_INTERVAL: Duration = Duration::from_millis(33);
const CAPTURE_RESULT_TIMEOUT: Duration = Duration::from_millis(250);
const INITIAL_CAPTURE_TIMEOUT: Duration = Duration::from_secs(5);
const INITIAL_CAPTURE_RETRY_INTERVAL: Duration = Duration::from_millis(100);
const MAXIMUM_CAPTURE_DIMENSION: i32 = 16_384;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NativeSourceDescriptor {
    pub source_id: u64,
    pub display_id: i64,
}

#[must_use]
pub fn select_main_display_source_id(
    sources: &[NativeSourceDescriptor],
    main_display_source_id: u64,
) -> Option<u64> {
    sources
        .iter()
        .find(|source| source.source_id == main_display_source_id)
        .map(|source| source.source_id)
}

pub(crate) struct CapturePipeline {
    source: NativeVideoSource,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl CapturePipeline {
    pub(crate) fn start() -> Result<Self, HostWebRtcError> {
        #[cfg(target_os = "macos")]
        if !macos_screen_capture_access(false) {
            return Err(HostWebRtcError::PeerFailure);
        }
        let mut capturer = DesktopCaptureDriver::new()?;
        let (publisher, receiver) = capture_channel();
        capturer.start(publisher);

        let first = receive_initial_frame(
            &receiver,
            || capturer.capture_frame(),
            INITIAL_CAPTURE_TIMEOUT,
            INITIAL_CAPTURE_RETRY_INTERVAL,
        )?;
        let resolution = VideoResolution {
            width: u32::try_from(first.width).map_err(|_| HostWebRtcError::PeerFailure)?,
            height: u32::try_from(first.height).map_err(|_| HostWebRtcError::PeerFailure)?,
        };
        let video_source = NativeVideoSource::new(resolution, true);
        publish_frame(&video_source, &first);
        drop(first);

        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let thread_source = video_source.clone();
        let capture_thread = thread::Builder::new()
            .name("roammand-main-display-capture".to_owned())
            .spawn(move || {
                capture_loop(&mut capturer, &receiver, &thread_source, &thread_stop);
            })
            .map_err(|_| HostWebRtcError::PeerFailure)?;

        Ok(Self {
            source: video_source,
            stop,
            thread: Some(capture_thread),
        })
    }

    pub(crate) fn source(&self) -> NativeVideoSource {
        self.source.clone()
    }

    pub(crate) fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

#[cfg(not(target_os = "macos"))]
struct DesktopCaptureDriver {
    handle: DesktopCapturer,
    source: Option<CaptureSource>,
}

#[cfg(not(target_os = "macos"))]
impl DesktopCaptureDriver {
    fn new() -> Result<Self, HostWebRtcError> {
        let mut options = DesktopCapturerOptions::new(DesktopCaptureSourceType::Screen);
        options.set_include_cursor(false);
        let handle = DesktopCapturer::new(options).ok_or(HostWebRtcError::PeerFailure)?;
        let source = main_display_source(&handle)?;
        Ok(Self {
            handle,
            source: Some(source),
        })
    }

    fn start(&mut self, publisher: CapturePublisher) {
        let source = self
            .source
            .take()
            .expect("capture source is consumed only once");
        self.handle.start_capture(Some(source), move |result| {
            publish_capture_result(&publisher, result);
        });
    }

    fn capture_frame(&mut self) {
        self.handle.capture_frame();
    }
}

#[cfg(target_os = "macos")]
#[must_use]
pub fn macos_screen_capture_access(request: bool) -> bool {
    let access = ScreenCaptureAccess;
    access.preflight() || (request && access.request())
}

impl Drop for CapturePipeline {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(not(target_os = "macos"))]
fn main_display_source(capturer: &DesktopCapturer) -> Result<CaptureSource, HostWebRtcError> {
    let sources = capturer.get_source_list();
    if sources.is_empty() {
        return Err(HostWebRtcError::PeerFailure);
    }
    let descriptors = sources
        .iter()
        .map(|source| NativeSourceDescriptor {
            source_id: source.id(),
            display_id: source.display_id(),
        })
        .collect::<Vec<_>>();
    let main_display_source_id = platform_main_display_source_id(&descriptors);
    let selected_id = select_main_display_source_id(&descriptors, main_display_source_id)
        .ok_or(HostWebRtcError::PeerFailure)?;
    sources
        .into_iter()
        .find(|source| source.id() == selected_id)
        .ok_or(HostWebRtcError::PeerFailure)
}

#[cfg(target_os = "windows")]
fn platform_main_display_source_id(sources: &[NativeSourceDescriptor]) -> u64 {
    sources
        .first()
        .expect("capture sources are checked non-empty")
        .source_id
}

#[cfg(not(any(target_os = "macos", windows)))]
fn platform_main_display_source_id(sources: &[NativeSourceDescriptor]) -> u64 {
    sources
        .first()
        .expect("capture sources are checked non-empty")
        .source_id
}

enum CaptureMessage {
    Frame(CapturedVideoFrame),
    TemporaryError,
    PermanentError,
    InvalidFrame,
}

struct CapturePublisher {
    sender: SyncSender<CaptureMessage>,
    ready: Arc<AtomicBool>,
}

struct CaptureReceiver {
    receiver: Receiver<CaptureMessage>,
    ready: Arc<AtomicBool>,
}

fn capture_channel() -> (CapturePublisher, CaptureReceiver) {
    let (sender, receiver) = sync_channel(1);
    let ready = Arc::new(AtomicBool::new(true));
    (
        CapturePublisher {
            sender,
            ready: Arc::clone(&ready),
        },
        CaptureReceiver { receiver, ready },
    )
}

impl CapturePublisher {
    fn publish(&self, prepare: impl FnOnce() -> CaptureMessage) {
        // Reserve the one-frame queue before allocating or converting pixels.
        // Some native capturers deliver callbacks after a request timed out.
        if !self.ready.swap(false, Ordering::AcqRel) {
            return;
        }
        if self.sender.try_send(prepare()).is_err() {
            self.ready.store(true, Ordering::Release);
        }
    }
}

impl CaptureReceiver {
    fn recv_timeout(&self, timeout: Duration) -> Result<CaptureMessage, RecvTimeoutError> {
        let result = self.receiver.recv_timeout(timeout);
        if result.is_ok() {
            self.ready.store(true, Ordering::Release);
        }
        result
    }
}

struct CapturedVideoFrame {
    width: i32,
    height: i32,
    buffer: I420Buffer,
}

impl CapturedVideoFrame {
    #[cfg(not(target_os = "macos"))]
    fn from_desktop_frame(frame: &DesktopFrame) -> Result<Self, HostWebRtcError> {
        Self::from_argb(frame.width(), frame.height(), frame.stride(), frame.data())
    }

    fn from_argb(
        width: i32,
        height: i32,
        stride: u32,
        data: &[u8],
    ) -> Result<Self, HostWebRtcError> {
        let required = required_frame_bytes(width, height, stride)?;
        if data.len() < required {
            return Err(HostWebRtcError::PeerFailure);
        }
        let buffer_width = u32::try_from(width).map_err(|_| HostWebRtcError::PeerFailure)?;
        let buffer_height = u32::try_from(height).map_err(|_| HostWebRtcError::PeerFailure)?;
        // WebRTC can retain published buffers for asynchronous encoding. Its
        // Rust API provides no exclusive-reference check for writable reuse.
        let mut buffer = I420Buffer::new(buffer_width, buffer_height);
        let (stride_y, stride_u, stride_v) = buffer.strides();
        let (data_y, data_u, data_v) = buffer.data_mut();
        // Borrow the desktop pixels only while the native frame is alive in
        // its callback. Send the converted, independently owned I420 buffer
        // across threads instead of making a second full-size ARGB allocation.
        yuv_helper::argb_to_i420(
            &data[..required],
            stride,
            data_y,
            stride_y,
            data_u,
            stride_u,
            data_v,
            stride_v,
            width,
            height,
        );
        Ok(Self {
            width,
            height,
            buffer,
        })
    }
}

fn required_frame_bytes(width: i32, height: i32, stride: u32) -> Result<usize, HostWebRtcError> {
    if width <= 0
        || height <= 0
        || width > MAXIMUM_CAPTURE_DIMENSION
        || height > MAXIMUM_CAPTURE_DIMENSION
    {
        return Err(HostWebRtcError::PeerFailure);
    }
    let minimum_stride = u32::try_from(width)
        .ok()
        .and_then(|value| value.checked_mul(BYTES_PER_DESKTOP_PIXEL))
        .ok_or(HostWebRtcError::PeerFailure)?;
    let required = usize::try_from(stride)
        .ok()
        .and_then(|value| value.checked_mul(usize::try_from(height).ok()?))
        .ok_or(HostWebRtcError::PeerFailure)?;
    if stride < minimum_stride {
        return Err(HostWebRtcError::PeerFailure);
    }
    Ok(required)
}

#[cfg(not(target_os = "macos"))]
fn publish_capture_result(
    publisher: &CapturePublisher,
    result: Result<DesktopFrame, CaptureError>,
) {
    publisher.publish(|| match result {
        Ok(frame) => match CapturedVideoFrame::from_desktop_frame(&frame) {
            Ok(frame) => CaptureMessage::Frame(frame),
            Err(_) => CaptureMessage::InvalidFrame,
        },
        Err(CaptureError::Temporary) => CaptureMessage::TemporaryError,
        Err(CaptureError::Permanent) => CaptureMessage::PermanentError,
    });
}

fn receive_initial_frame(
    receiver: &CaptureReceiver,
    mut request_frame: impl FnMut(),
    timeout: Duration,
    retry_interval: Duration,
) -> Result<CapturedVideoFrame, HostWebRtcError> {
    let deadline = Instant::now() + timeout;
    loop {
        request_frame();
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(HostWebRtcError::PeerFailure);
        }
        match receiver.recv_timeout(remaining.min(CAPTURE_RESULT_TIMEOUT)) {
            Ok(CaptureMessage::Frame(frame)) => return Ok(frame),
            Ok(CaptureMessage::TemporaryError) | Err(RecvTimeoutError::Timeout) => {}
            Ok(CaptureMessage::PermanentError | CaptureMessage::InvalidFrame)
            | Err(RecvTimeoutError::Disconnected) => return Err(HostWebRtcError::PeerFailure),
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(HostWebRtcError::PeerFailure);
        }
        thread::sleep(retry_interval.min(remaining));
    }
}

fn capture_loop(
    capturer: &mut DesktopCaptureDriver,
    receiver: &CaptureReceiver,
    source: &NativeVideoSource,
    stop: &AtomicBool,
) {
    let resolution = source.video_resolution();
    while !stop.load(Ordering::Acquire) {
        let started = std::time::Instant::now();
        capturer.capture_frame();
        match receiver.recv_timeout(CAPTURE_RESULT_TIMEOUT) {
            Ok(CaptureMessage::Frame(frame)) => {
                let same_resolution = u32::try_from(frame.width).ok() == Some(resolution.width)
                    && u32::try_from(frame.height).ok() == Some(resolution.height);
                if !same_resolution {
                    break;
                }
                publish_frame(source, &frame);
            }
            Ok(CaptureMessage::TemporaryError) | Err(RecvTimeoutError::Timeout) => {}
            Ok(CaptureMessage::PermanentError | CaptureMessage::InvalidFrame)
            | Err(RecvTimeoutError::Disconnected) => break,
        }
        if let Some(remaining) = CAPTURE_FRAME_INTERVAL.checked_sub(started.elapsed()) {
            thread::sleep(remaining);
        }
    }
}

fn publish_frame(source: &NativeVideoSource, frame: &CapturedVideoFrame) {
    let timestamp_us = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros()
        .try_into()
        .unwrap_or(i64::MAX);
    source.capture_frame(&VideoFrame {
        rotation: VideoRotation::VideoRotation0,
        timestamp_us,
        buffer: &frame.buffer,
    });
}

#[cfg(test)]
mod tests {
    use std::{cell::Cell, collections::VecDeque};

    use super::*;

    #[test]
    fn full_capture_queue_skips_pixel_preparation_until_consumed() {
        let (publisher, receiver) = capture_channel();
        let preparations = Cell::new(0);
        let prepare = || {
            preparations.set(preparations.get() + 1);
            CaptureMessage::TemporaryError
        };

        publisher.publish(prepare);
        publisher.publish(prepare);
        assert_eq!(preparations.get(), 1);
        assert!(matches!(
            receiver.recv_timeout(Duration::ZERO),
            Ok(CaptureMessage::TemporaryError)
        ));

        publisher.publish(prepare);
        assert_eq!(preparations.get(), 2);
        assert!(matches!(
            receiver.recv_timeout(Duration::ZERO),
            Ok(CaptureMessage::TemporaryError)
        ));
    }

    #[test]
    fn capture_timeout_does_not_reopen_an_in_flight_conversion() {
        let (publisher, receiver) = capture_channel();
        let (started, wait_started) = sync_channel(1);
        let (resume, wait_resume) = sync_channel(1);
        let additional_preparations = Cell::new(0);
        thread::scope(|scope| {
            let publisher_ref = &publisher;
            scope.spawn(move || {
                publisher_ref.publish(|| {
                    started.send(()).expect("announce conversion");
                    wait_resume.recv().expect("resume conversion");
                    CaptureMessage::TemporaryError
                });
            });
            wait_started.recv().expect("conversion must start");
            assert!(matches!(
                receiver.recv_timeout(Duration::ZERO),
                Err(RecvTimeoutError::Timeout)
            ));
            publisher.publish(|| {
                additional_preparations.set(additional_preparations.get() + 1);
                CaptureMessage::PermanentError
            });
            resume.send(()).expect("resume conversion");
            assert!(matches!(
                receiver.recv_timeout(Duration::from_secs(1)),
                Ok(CaptureMessage::TemporaryError)
            ));
        });
        assert_eq!(additional_preparations.get(), 0);

        publisher.publish(|| CaptureMessage::PermanentError);
        assert!(matches!(
            receiver.recv_timeout(Duration::ZERO),
            Ok(CaptureMessage::PermanentError)
        ));
    }

    #[test]
    fn converted_frames_own_pixels_after_native_storage_is_released() {
        let mut native_pixels = [0_u8, 0, 255, 255].repeat(4);
        let first =
            CapturedVideoFrame::from_argb(2, 2, 8, &native_pixels).expect("valid red frame");
        let (y, u, v) = first.buffer.data();
        let first_planes = (y.to_vec(), u.to_vec(), v.to_vec());

        // Reusing the capture storage and preparing a later frame must not
        // overwrite a buffer that WebRTC can still be encoding.
        for pixel in native_pixels.chunks_exact_mut(4) {
            pixel.copy_from_slice(&[255, 0, 0, 255]);
        }
        let second =
            CapturedVideoFrame::from_argb(2, 2, 8, &native_pixels).expect("valid blue frame");
        drop(native_pixels);

        assert_eq!(
            first.buffer.data(),
            (
                first_planes.0.as_slice(),
                first_planes.1.as_slice(),
                first_planes.2.as_slice()
            )
        );
        assert_ne!(first.buffer.data(), second.buffer.data());
        assert_eq!((first.width, first.height), (2, 2));
    }

    #[test]
    fn conversion_rejects_truncated_or_invalid_desktop_buffers() {
        assert!(CapturedVideoFrame::from_argb(2, 2, 8, &[0; 15]).is_err());
        assert!(CapturedVideoFrame::from_argb(2, 2, 4, &[0; 16]).is_err());
        assert!(CapturedVideoFrame::from_argb(0, 2, 8, &[0; 16]).is_err());
    }

    #[test]
    fn initial_capture_retries_temporary_errors_until_a_frame_arrives() {
        let (publisher, receiver) = capture_channel();
        let mut messages = VecDeque::from([
            CaptureMessage::TemporaryError,
            CaptureMessage::TemporaryError,
            CaptureMessage::Frame(
                CapturedVideoFrame::from_argb(1, 1, BYTES_PER_DESKTOP_PIXEL, &[0; 4])
                    .expect("valid test frame"),
            ),
        ]);

        let frame = receive_initial_frame(
            &receiver,
            || {
                publisher.publish(|| messages.pop_front().expect("test message must exist"));
            },
            Duration::from_secs(1),
            Duration::ZERO,
        )
        .expect("temporary errors must be retried");

        assert_eq!((frame.width, frame.height), (1, 1));
        assert!(messages.is_empty());
    }
}
