// SPDX-License-Identifier: MPL-2.0

#![allow(unsafe_code)]

use core_graphics::display::CGDisplay;
use cxx::UniquePtr;
use webrtc_sys::desktop_capturer::{
    CaptureError as NativeCaptureError, DesktopCapturerCallback, DesktopCapturerCallbackWrapper,
    ffi::{self as native_capture_ffi, new_desktop_capturer},
};

use super::{
    CaptureMessage, CapturePublisher, CapturedVideoFrame, HostWebRtcError, required_frame_bytes,
};

pub(super) struct DesktopCaptureDriver {
    handle: UniquePtr<native_capture_ffi::DesktopCapturer>,
}

impl DesktopCaptureDriver {
    pub(super) fn new() -> Result<Self, HostWebRtcError> {
        let options = native_capture_ffi::DesktopCapturerOptions {
            source_type: native_capture_ffi::SourceType::Screen,
            include_cursor: false,
            allow_sck_system_picker: false,
        };
        let handle = new_desktop_capturer(options);
        if handle.is_null() {
            return Err(HostWebRtcError::PeerFailure);
        }
        // With the system picker disabled ScreenCaptureKit expects a raw
        // CGDirectDisplayID even though its source list is empty.
        if !handle.select_source(u64::from(CGDisplay::main().id)) {
            return Err(HostWebRtcError::PeerFailure);
        }
        Ok(Self { handle })
    }

    pub(super) fn start(&mut self, publisher: CapturePublisher) {
        let callback = NativeCaptureCallback { publisher };
        let wrapper = DesktopCapturerCallbackWrapper::new(Box::new(callback));
        self.handle.pin_mut().start(Box::new(wrapper));
    }

    pub(super) fn capture_frame(&mut self) {
        self.handle.capture_frame();
    }
}

struct NativeCaptureCallback {
    publisher: CapturePublisher,
}

impl DesktopCapturerCallback for NativeCaptureCallback {
    fn on_capture_result(
        &mut self,
        result: Result<UniquePtr<native_capture_ffi::DesktopFrame>, NativeCaptureError>,
    ) {
        self.publisher.publish(|| match result {
            Ok(frame) => match frame.as_ref().map(convert_native_frame) {
                Some(Ok(frame)) => CaptureMessage::Frame(frame),
                Some(Err(_)) | None => CaptureMessage::InvalidFrame,
            },
            Err(NativeCaptureError::Temporary) => CaptureMessage::TemporaryError,
            Err(NativeCaptureError::Permanent) => CaptureMessage::PermanentError,
        });
    }
}

fn convert_native_frame(
    frame: &native_capture_ffi::DesktopFrame,
) -> Result<CapturedVideoFrame, HostWebRtcError> {
    let width = frame.width();
    let height = frame.height();
    let stride = u32::try_from(frame.stride()).map_err(|_| HostWebRtcError::PeerFailure)?;
    let required = required_frame_bytes(width, height, stride)?;
    let data = frame.data();
    if data.is_null() {
        return Err(HostWebRtcError::PeerFailure);
    }
    // SAFETY: libwebrtc owns the buffer for the callback duration and a
    // successful DesktopFrame exposes stride * height readable bytes.
    let data = unsafe { std::slice::from_raw_parts(data, required) };
    CapturedVideoFrame::from_argb(width, height, stride, data)
}
