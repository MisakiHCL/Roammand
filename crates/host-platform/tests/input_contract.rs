// SPDX-License-Identifier: MPL-2.0

use std::sync::{Arc, Mutex};

use roammand_host_platform::{
    NativeButton, NativeDirection, PRESSED_LEFT_BUTTON_BIT, PRESSED_RIGHT_BUTTON_BIT,
    PlatformInputBackend, PlatformInputError, PlatformInputSink,
};
use roammand_host_webrtc::{HostWebRtcError, RemoteInputSink};
use roammand_protocol::roammand::v1::{ButtonAction, KeyboardAction, PointerButton};

const LEFT_CONTROL_MODIFIER_BIT: u32 = 1;
#[test]
fn maps_normalized_coordinates_tracks_pressed_state_and_releases_idempotently() {
    let events = Arc::new(Mutex::new(Vec::<String>::new()));
    let backend = RecordingBackend::new(Arc::clone(&events), (1920, 1080));
    let mut sink = PlatformInputSink::new(backend).expect("display preflight must succeed");

    sink.keyboard(KeyboardAction::Down, 0x04, LEFT_CONTROL_MODIFIER_BIT)
        .expect("keyboard input must succeed");
    sink.pointer_button(PointerButton::Left, ButtonAction::Down, 10_000, 0)
        .expect("pointer button must succeed");
    sink.pointer_move(
        5000,
        10_000,
        PRESSED_LEFT_BUTTON_BIT | PRESSED_RIGHT_BUTTON_BIT,
    )
    .expect("drag move must succeed");
    sink.pointer_scroll(-2, 3).expect("scroll must succeed");
    sink.text("hello").expect("text must succeed");
    sink.release_all().expect("release must succeed");
    sink.release_all()
        .expect("repeated release must be a no-op");

    assert_eq!(
        *events.lock().expect("events lock"),
        vec![
            "key:224:press",
            "key:4:press",
            "move:1919:0",
            "button:left:press",
            "button:right:press",
            "move:960:1079",
            "scroll:-2:3",
            "text:hello",
            "key:4:release",
            "key:224:release",
            "button:left:release",
            "button:right:release",
        ]
    );
}

#[test]
fn rejects_invalid_display_preflight_and_maps_backend_failures() {
    let invalid = RecordingBackend::new(Arc::new(Mutex::new(Vec::new())), (0, 1080));
    assert!(matches!(
        PlatformInputSink::new(invalid),
        Err(PlatformInputError::InvalidMainDisplay)
    ));

    let backend = RecordingBackend::failing(Arc::new(Mutex::new(Vec::new())), (1920, 1080));
    let mut sink = PlatformInputSink::new(backend).expect("display preflight must succeed");
    assert_eq!(
        sink.keyboard(KeyboardAction::Down, 0x04, 0),
        Err(HostWebRtcError::InputFailure)
    );
}

#[test]
fn releases_a_press_that_the_os_reports_as_partially_injected() {
    let events = Arc::new(Mutex::new(Vec::<String>::new()));
    let backend = PartialPressBackend {
        events: Arc::clone(&events),
        failed_once: false,
    };
    let mut sink = PlatformInputSink::new(backend).expect("display preflight must succeed");

    assert_eq!(
        sink.keyboard(KeyboardAction::Down, 0x04, 0),
        Err(HostWebRtcError::InputFailure)
    );
    sink.release_all()
        .expect("release after partial injection must succeed");
    assert_eq!(
        *events.lock().expect("events lock"),
        vec!["key:4:press-partial", "key:4:release"]
    );
}

#[test]
fn retries_failed_releases_without_repeating_successful_releases() {
    let events = Arc::new(Mutex::new(Vec::<String>::new()));
    let mut backend = RecordingBackend::new(Arc::clone(&events), (1920, 1080));
    backend.fail_key_release_once = true;
    backend.fail_button_release_once = true;
    let mut sink = PlatformInputSink::new(backend).expect("display preflight must succeed");
    sink.keyboard(KeyboardAction::Down, 0x04, 0)
        .expect("first key must press");
    sink.keyboard(KeyboardAction::Down, 0x05, 0)
        .expect("second key must press");
    sink.pointer_move(
        5000,
        5000,
        PRESSED_LEFT_BUTTON_BIT | PRESSED_RIGHT_BUTTON_BIT,
    )
    .expect("buttons must press");
    events.lock().expect("events lock").clear();

    assert_eq!(sink.release_all(), Err(HostWebRtcError::InputFailure));
    sink.release_all().expect("failed releases must retry");
    sink.release_all()
        .expect("successful cleanup must be idempotent");

    assert_eq!(
        *events.lock().expect("events lock"),
        vec![
            "key:4:release-failed",
            "key:5:release",
            "button:left:release-failed",
            "button:right:release",
            "key:4:release",
            "button:left:release",
        ]
    );
}

struct RecordingBackend {
    events: Arc<Mutex<Vec<String>>>,
    display: (i32, i32),
    fail_injection: bool,
    fail_key_release_once: bool,
    fail_button_release_once: bool,
}

impl RecordingBackend {
    fn new(events: Arc<Mutex<Vec<String>>>, display: (i32, i32)) -> Self {
        Self {
            events,
            display,
            fail_injection: false,
            fail_key_release_once: false,
            fail_button_release_once: false,
        }
    }

    fn failing(events: Arc<Mutex<Vec<String>>>, display: (i32, i32)) -> Self {
        Self {
            events,
            display,
            fail_injection: true,
            fail_key_release_once: false,
            fail_button_release_once: false,
        }
    }

    fn record(&self, event: String) -> Result<(), PlatformInputError> {
        if self.fail_injection {
            return Err(PlatformInputError::InjectionFailed);
        }
        self.events.lock().expect("events lock").push(event);
        Ok(())
    }
}

impl PlatformInputBackend for RecordingBackend {
    fn main_display_size(&mut self) -> Result<(i32, i32), PlatformInputError> {
        Ok(self.display)
    }

    fn keyboard(
        &mut self,
        usb_hid_usage: u32,
        direction: NativeDirection,
    ) -> Result<(), PlatformInputError> {
        if direction == NativeDirection::Release && self.fail_key_release_once {
            self.fail_key_release_once = false;
            self.record(format!("key:{usb_hid_usage}:release-failed"))?;
            return Err(PlatformInputError::InjectionFailed);
        }
        self.record(format!("key:{usb_hid_usage}:{}", direction_name(direction)))
    }

    fn pointer_button(
        &mut self,
        button: NativeButton,
        direction: NativeDirection,
    ) -> Result<(), PlatformInputError> {
        if direction == NativeDirection::Release && self.fail_button_release_once {
            self.fail_button_release_once = false;
            self.record(format!("button:{}:release-failed", button_name(button)))?;
            return Err(PlatformInputError::InjectionFailed);
        }
        self.record(format!(
            "button:{}:{}",
            button_name(button),
            direction_name(direction)
        ))
    }

    fn pointer_move(&mut self, x: i32, y: i32) -> Result<(), PlatformInputError> {
        self.record(format!("move:{x}:{y}"))
    }

    fn pointer_scroll(&mut self, delta_x: i32, delta_y: i32) -> Result<(), PlatformInputError> {
        self.record(format!("scroll:{delta_x}:{delta_y}"))
    }

    fn text(&mut self, text: &str) -> Result<(), PlatformInputError> {
        self.record(format!("text:{text}"))
    }
}

struct PartialPressBackend {
    events: Arc<Mutex<Vec<String>>>,
    failed_once: bool,
}

impl PlatformInputBackend for PartialPressBackend {
    fn main_display_size(&mut self) -> Result<(i32, i32), PlatformInputError> {
        Ok((1920, 1080))
    }

    fn keyboard(
        &mut self,
        usb_hid_usage: u32,
        direction: NativeDirection,
    ) -> Result<(), PlatformInputError> {
        let suffix = direction_name(direction);
        if !self.failed_once && direction == NativeDirection::Press {
            self.failed_once = true;
            self.events
                .lock()
                .expect("events lock")
                .push(format!("key:{usb_hid_usage}:{suffix}-partial"));
            return Err(PlatformInputError::PartialInjection);
        }
        self.events
            .lock()
            .expect("events lock")
            .push(format!("key:{usb_hid_usage}:{suffix}"));
        Ok(())
    }

    fn pointer_button(
        &mut self,
        _button: NativeButton,
        _direction: NativeDirection,
    ) -> Result<(), PlatformInputError> {
        Ok(())
    }

    fn pointer_move(&mut self, _x: i32, _y: i32) -> Result<(), PlatformInputError> {
        Ok(())
    }

    fn pointer_scroll(&mut self, _delta_x: i32, _delta_y: i32) -> Result<(), PlatformInputError> {
        Ok(())
    }

    fn text(&mut self, _text: &str) -> Result<(), PlatformInputError> {
        Ok(())
    }
}

const fn direction_name(direction: NativeDirection) -> &'static str {
    match direction {
        NativeDirection::Press => "press",
        NativeDirection::Release => "release",
    }
}

const fn button_name(button: NativeButton) -> &'static str {
    match button {
        NativeButton::Left => "left",
        NativeButton::Right => "right",
        NativeButton::Middle => "middle",
    }
}
