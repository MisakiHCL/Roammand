// SPDX-License-Identifier: MPL-2.0

use std::collections::BTreeSet;

use roammand_host_webrtc::{HostWebRtcError, NORMALIZED_POINTER_MAX, RemoteInputSink};
use roammand_protocol::roammand::v1::{ButtonAction, KeyboardAction, PointerButton};
use thiserror::Error;

pub const PRESSED_LEFT_BUTTON_BIT: u32 = 1;
pub const PRESSED_RIGHT_BUTTON_BIT: u32 = 1 << 1;
pub const PRESSED_MIDDLE_BUTTON_BIT: u32 = 1 << 2;

const FIRST_MODIFIER_USAGE: u32 = 0xe0;
const MODIFIER_COUNT: u32 = 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeDirection {
    Press,
    Release,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum NativeButton {
    Left,
    Right,
    Middle,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PlatformInputError {
    #[error("remote input is unsupported on this platform")]
    UnsupportedPlatform,
    #[error("accessibility input permission is required")]
    PermissionDenied,
    #[error("the native input backend is unavailable")]
    BackendUnavailable,
    #[error("the main display geometry is invalid")]
    InvalidMainDisplay,
    #[error("the USB HID keyboard usage is unsupported")]
    UnsupportedKeyboardUsage,
    #[error("native input injection failed")]
    InjectionFailed,
    #[error("the operating system accepted only part of an input batch")]
    PartialInjection,
}

pub trait PlatformInputBackend: Send {
    /// Returns the main display's pixel width and height.
    ///
    /// # Errors
    ///
    /// Returns a stable platform input error when geometry is unavailable.
    fn main_display_size(&mut self) -> Result<(i32, i32), PlatformInputError>;

    /// Injects one physical USB HID keyboard transition.
    ///
    /// # Errors
    ///
    /// Returns a stable platform input error when mapping or injection fails.
    fn keyboard(
        &mut self,
        usb_hid_usage: u32,
        direction: NativeDirection,
    ) -> Result<(), PlatformInputError>;

    /// Injects one pointer button transition.
    ///
    /// # Errors
    ///
    /// Returns a stable platform input error when injection fails.
    fn pointer_button(
        &mut self,
        button: NativeButton,
        direction: NativeDirection,
    ) -> Result<(), PlatformInputError>;

    /// Moves the pointer to an absolute main-display pixel coordinate.
    ///
    /// # Errors
    ///
    /// Returns a stable platform input error when injection fails.
    fn pointer_move(&mut self, x: i32, y: i32) -> Result<(), PlatformInputError>;

    /// Injects horizontal and vertical scroll deltas.
    ///
    /// # Errors
    ///
    /// Returns a stable platform input error when injection fails.
    fn pointer_scroll(&mut self, delta_x: i32, delta_y: i32) -> Result<(), PlatformInputError>;

    /// Injects Unicode text through the platform text path.
    ///
    /// # Errors
    ///
    /// Returns a stable platform input error when injection fails.
    fn text(&mut self, text: &str) -> Result<(), PlatformInputError>;
}

pub struct PlatformInputSink<B> {
    backend: B,
    display_width: i32,
    display_height: i32,
    pressed_keys: BTreeSet<u32>,
    pressed_buttons: BTreeSet<NativeButton>,
}

impl<B: PlatformInputBackend> PlatformInputSink<B> {
    /// Creates a session-scoped input sink after validating main-display geometry.
    ///
    /// # Errors
    ///
    /// Returns a backend error or [`PlatformInputError::InvalidMainDisplay`].
    pub fn new(mut backend: B) -> Result<Self, PlatformInputError> {
        let (display_width, display_height) = backend.main_display_size()?;
        if display_width <= 0 || display_height <= 0 {
            return Err(PlatformInputError::InvalidMainDisplay);
        }
        Ok(Self {
            backend,
            display_width,
            display_height,
            pressed_keys: BTreeSet::new(),
            pressed_buttons: BTreeSet::new(),
        })
    }

    fn reconcile_modifiers(
        &mut self,
        modifier_bits: u32,
        current_usage: u32,
    ) -> Result<(), HostWebRtcError> {
        for bit in 0..MODIFIER_COUNT {
            let usage = FIRST_MODIFIER_USAGE + bit;
            if usage == current_usage {
                continue;
            }
            let desired = modifier_bits & (1 << bit) != 0;
            let pressed = self.pressed_keys.contains(&usage);
            if desired && !pressed {
                self.set_key(usage, NativeDirection::Press)?;
            } else if !desired && pressed {
                self.set_key(usage, NativeDirection::Release)?;
            }
        }
        Ok(())
    }

    fn set_key(&mut self, usage: u32, direction: NativeDirection) -> Result<(), HostWebRtcError> {
        let pressed = self.pressed_keys.contains(&usage);
        if (direction == NativeDirection::Press) == pressed {
            return Ok(());
        }
        if let Err(error) = self.backend.keyboard(usage, direction) {
            if direction == NativeDirection::Press {
                self.pressed_keys.insert(usage);
            }
            return Err(map_input_error(error));
        }
        match direction {
            NativeDirection::Press => {
                self.pressed_keys.insert(usage);
            }
            NativeDirection::Release => {
                self.pressed_keys.remove(&usage);
            }
        }
        Ok(())
    }

    fn set_button(
        &mut self,
        button: NativeButton,
        direction: NativeDirection,
    ) -> Result<(), HostWebRtcError> {
        let pressed = self.pressed_buttons.contains(&button);
        if (direction == NativeDirection::Press) == pressed {
            return Ok(());
        }
        if let Err(error) = self.backend.pointer_button(button, direction) {
            if direction == NativeDirection::Press {
                self.pressed_buttons.insert(button);
            }
            return Err(map_input_error(error));
        }
        match direction {
            NativeDirection::Press => {
                self.pressed_buttons.insert(button);
            }
            NativeDirection::Release => {
                self.pressed_buttons.remove(&button);
            }
        }
        Ok(())
    }

    fn reconcile_pointer_buttons(&mut self, bits: u32) -> Result<(), HostWebRtcError> {
        for (button, bit) in [
            (NativeButton::Left, PRESSED_LEFT_BUTTON_BIT),
            (NativeButton::Right, PRESSED_RIGHT_BUTTON_BIT),
            (NativeButton::Middle, PRESSED_MIDDLE_BUTTON_BIT),
        ] {
            let direction = if bits & bit == 0 {
                NativeDirection::Release
            } else {
                NativeDirection::Press
            };
            self.set_button(button, direction)?;
        }
        Ok(())
    }

    fn move_normalized(&mut self, x: i32, y: i32) -> Result<(), HostWebRtcError> {
        let (pixel_x, pixel_y) =
            normalized_to_pixels(x, y, self.display_width, self.display_height)?;
        self.backend
            .pointer_move(pixel_x, pixel_y)
            .map_err(map_input_error)
    }

    fn click_button(
        &mut self,
        button: NativeButton,
        click_count: u8,
    ) -> Result<(), HostWebRtcError> {
        if self.pressed_buttons.contains(&button) {
            return Err(HostWebRtcError::InputFailure);
        }
        for _ in 0..click_count {
            self.set_button(button, NativeDirection::Press)?;
            self.set_button(button, NativeDirection::Release)?;
        }
        Ok(())
    }
}

impl<B: PlatformInputBackend> RemoteInputSink for PlatformInputSink<B> {
    fn keyboard(
        &mut self,
        action: KeyboardAction,
        usb_hid_usage: u32,
        modifier_bits: u32,
    ) -> Result<(), HostWebRtcError> {
        self.reconcile_modifiers(modifier_bits, usb_hid_usage)?;
        let direction = match action {
            KeyboardAction::Down => NativeDirection::Press,
            KeyboardAction::Up => NativeDirection::Release,
            KeyboardAction::Unspecified => return Err(HostWebRtcError::InputFailure),
        };
        self.set_key(usb_hid_usage, direction)
    }

    fn pointer_button(
        &mut self,
        button: PointerButton,
        action: ButtonAction,
        x: i32,
        y: i32,
    ) -> Result<(), HostWebRtcError> {
        self.move_normalized(x, y)?;
        let button = native_button(button)?;
        match action {
            ButtonAction::Down => self.set_button(button, NativeDirection::Press),
            ButtonAction::Up => self.set_button(button, NativeDirection::Release),
            ButtonAction::Click => self.click_button(button, 1),
            ButtonAction::DoubleClick => self.click_button(button, 2),
            ButtonAction::Unspecified => Err(HostWebRtcError::InputFailure),
        }
    }

    fn pointer_move(
        &mut self,
        x: i32,
        y: i32,
        pressed_button_bits: u32,
    ) -> Result<(), HostWebRtcError> {
        self.reconcile_pointer_buttons(pressed_button_bits)?;
        self.move_normalized(x, y)
    }

    fn pointer_scroll(&mut self, delta_x: i32, delta_y: i32) -> Result<(), HostWebRtcError> {
        self.backend
            .pointer_scroll(delta_x, delta_y)
            .map_err(map_input_error)
    }

    fn text(&mut self, text: &str) -> Result<(), HostWebRtcError> {
        self.backend.text(text).map_err(map_input_error)
    }

    fn release_all(&mut self) -> Result<(), HostWebRtcError> {
        let mut first_error = None;
        // A failed release can leave the OS key/button pressed. Keep that
        // state so a later cleanup attempt can retry just the failed items.
        let backend = &mut self.backend;
        self.pressed_keys.retain(|usage| {
            if backend.keyboard(*usage, NativeDirection::Release).is_err() {
                first_error.get_or_insert(HostWebRtcError::InputFailure);
                return true;
            }
            false
        });
        self.pressed_buttons.retain(|button| {
            if backend
                .pointer_button(*button, NativeDirection::Release)
                .is_err()
            {
                first_error.get_or_insert(HostWebRtcError::InputFailure);
                return true;
            }
            false
        });
        first_error.map_or(Ok(()), Err)
    }
}

fn normalized_to_pixels(
    x: i32,
    y: i32,
    display_width: i32,
    display_height: i32,
) -> Result<(i32, i32), HostWebRtcError> {
    if !(0..=NORMALIZED_POINTER_MAX).contains(&x) || !(0..=NORMALIZED_POINTER_MAX).contains(&y) {
        return Err(HostWebRtcError::InvalidCoordinates);
    }
    let maximum = i64::from(NORMALIZED_POINTER_MAX);
    let rounding = maximum / 2;
    let pixel_x = (i64::from(x) * i64::from(display_width - 1) + rounding) / maximum;
    let pixel_y = (i64::from(y) * i64::from(display_height - 1) + rounding) / maximum;
    Ok((
        i32::try_from(pixel_x).map_err(|_| HostWebRtcError::InvalidCoordinates)?,
        i32::try_from(pixel_y).map_err(|_| HostWebRtcError::InvalidCoordinates)?,
    ))
}

const fn native_button(button: PointerButton) -> Result<NativeButton, HostWebRtcError> {
    match button {
        PointerButton::Left => Ok(NativeButton::Left),
        PointerButton::Right => Ok(NativeButton::Right),
        PointerButton::Middle => Ok(NativeButton::Middle),
        PointerButton::Unspecified => Err(HostWebRtcError::InputFailure),
    }
}

const fn map_input_error(_error: PlatformInputError) -> HostWebRtcError {
    HostWebRtcError::InputFailure
}
