// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Roammand';

  @override
  String get brandTagline => 'Leave the desk. Keep work moving.';

  @override
  String get brandPrivacyLabel => 'Private · Account-free';

  @override
  String get mobileHomeSubtitle =>
      'Use this device to securely control your own Mac.';

  @override
  String get desktopHomeSubtitle =>
      'Choose a paired computer to connect securely.';

  @override
  String get mobileIdentitySecurityNote =>
      'No account required. Pairing information stays on this device.';

  @override
  String get computerReadyLabel => 'Ready to connect';

  @override
  String get developmentStatus => 'Remote control is not available yet.';

  @override
  String get desktopHostTitle => 'This Mac';

  @override
  String get hostAgentConnectingTitle => 'Getting this Mac ready…';

  @override
  String get hostAgentConnectingBody =>
      'Checking whether this Mac can receive remote connections.';

  @override
  String get hostAgentOfflineTitle =>
      'Roammand\'s background service is not running';

  @override
  String get hostAgentOfflineBody =>
      'Try again. If it still does not start, reinstall Roammand.';

  @override
  String get hostAgentProtectedSessionUnavailableTitle =>
      'Lock-screen control is not available';

  @override
  String get hostAgentProtectedSessionUnavailableBody =>
      'Roammand could not start the service used on the lock and login screens. Try again or reinstall Roammand.';

  @override
  String get hostAgentPrivilegedBridgeUnavailableTitle =>
      'Remote control is unavailable';

  @override
  String get hostAgentPrivilegedBridgeUnavailableBody =>
      'Roammand could not connect to a required macOS background feature. Reinstall Roammand, then try again.';

  @override
  String get hostAgentComponentMissingTitle =>
      'Roammand\'s installation is incomplete';

  @override
  String get hostAgentComponentMissingBody =>
      'Files needed for remote control are missing. Reinstall Roammand, then try again.';

  @override
  String get hostAgentLaunchFailedTitle =>
      'Roammand\'s background service could not start';

  @override
  String get hostAgentLaunchFailedBody =>
      'macOS could not open a background feature needed for remote control. Reinstall Roammand, then try again.';

  @override
  String get hostAgentConfigurationInvalidTitle =>
      'Connection settings need attention';

  @override
  String get hostAgentConfigurationInvalidBody =>
      'Open Connection settings, check the service addresses, and try again.';

  @override
  String get hostAgentUnexpectedExitTitle =>
      'Roammand\'s background service stopped';

  @override
  String get hostAgentUnexpectedExitBody =>
      'Try again. If it keeps stopping, reinstall Roammand.';

  @override
  String get hostAgentErrorTitle => 'This Mac\'s status is unavailable';

  @override
  String get hostAgentErrorBody =>
      'Roammand could not read the current status. Wait a moment and try again.';

  @override
  String get retryAction => 'Retry';

  @override
  String get refreshAction => 'Refresh';

  @override
  String get privilegedBridgeSectionTitle => 'Remote control readiness';

  @override
  String get privilegedBridgeNotInstalledTitle => 'Setup is incomplete';

  @override
  String get privilegedBridgeNotInstalledBody =>
      'Reinstall Roammand to enable remote control on the desktop, lock screen, and login screen.';

  @override
  String get privilegedBridgeApprovalRequiredTitle =>
      'Administrator approval is needed';

  @override
  String get privilegedBridgeApprovalRequiredBody =>
      'Approve Roammand when macOS asks so its background service can run.';

  @override
  String get privilegedBridgePermissionRequiredTitle =>
      'Turn on macOS permissions';

  @override
  String get privilegedBridgePermissionRequiredBody =>
      'Allow Screen Recording and Accessibility for Roammand in System Settings.';

  @override
  String get macOsHostPermissionsTitle => 'Finish Mac permissions';

  @override
  String get macOsHostPermissionsBody =>
      'Remote connections stay unavailable until Screen Recording and Accessibility are both allowed. Set them up here before connecting from another device.';

  @override
  String get macOsHostPermissionsUnavailable =>
      'Roammand could not check the installed Host permissions. Make sure the Host Agent is installed, then try again.';

  @override
  String get macOsScreenRecordingPermission => 'Screen Recording';

  @override
  String get macOsAccessibilityPermission => 'Accessibility';

  @override
  String get macOsPermissionGranted => 'Allowed';

  @override
  String get macOsPermissionNotGranted => 'Not allowed';

  @override
  String get macOsPermissionSetUpAction => 'Set up';

  @override
  String get privilegedBridgeUserSessionOnlyTitle =>
      'Available only while this Mac is unlocked';

  @override
  String get privilegedBridgeUserSessionOnlyBody =>
      'You can control the desktop now, but not the lock or login screen.';

  @override
  String get privilegedBridgeReadyNormalTitle => 'This Mac is ready';

  @override
  String get privilegedBridgeReadyNormalBody =>
      'Approved devices can connect to this Mac.';

  @override
  String get privilegedBridgeReadyLockedTitle => 'Lock-screen control is ready';

  @override
  String get privilegedBridgeReadyLockedBody =>
      'Approved devices can stay connected when this Mac is locked or showing the login screen.';

  @override
  String get privilegedBridgeReadySecureTitle =>
      'System screens can also be controlled';

  @override
  String get privilegedBridgeReadySecureBody =>
      'Remote control stays available on macOS screens such as the lock and login screens.';

  @override
  String get privilegedBridgeReadyUnavailableTitle => 'Waiting for the desktop';

  @override
  String get privilegedBridgeReadyUnavailableBody =>
      'There is no desktop to control right now. Roammand will become available when macOS is ready.';

  @override
  String get privilegedBridgeTransitioningTitle => 'Switching screens…';

  @override
  String get privilegedBridgeTransitioningBody =>
      'Remote input is paused briefly while macOS changes screens.';

  @override
  String get privilegedBridgeReconnectingTitle => 'Restoring remote control…';

  @override
  String get privilegedBridgeReconnectingBody =>
      'Remote input stays paused until the connection to this Mac is safe again.';

  @override
  String privilegedBridgeControlledTitle(String controllerName) {
    return 'Controlled by $controllerName';
  }

  @override
  String get privilegedBridgeControlledUnknownTitle =>
      'Remote control is active';

  @override
  String get privilegedBridgeControlledBody =>
      'Select Emergency stop below to end every remote connection immediately.';

  @override
  String get privilegedBridgeFailedTitle =>
      'Remote control service is unavailable';

  @override
  String get privilegedBridgeFailedBody =>
      'Check Roammand\'s macOS permissions. If they are already on, reinstall Roammand.';

  @override
  String get privilegedBridgeUnknownTitle =>
      'Remote control status is unavailable';

  @override
  String get privilegedBridgeUnknownBody =>
      'Refresh the page. If the status does not return, reopen Roammand.';

  @override
  String get emergencyStopAction => 'Emergency stop';

  @override
  String get emergencyStoppingAction => 'Stopping…';

  @override
  String get emergencyStopDialogTitle => 'Stop remote control?';

  @override
  String get emergencyStopDialogBody =>
      'This immediately disconnects every device and stops its mouse and keyboard control. Your approved-device list is kept.';

  @override
  String get confirmEmergencyStopAction => 'Stop now';

  @override
  String get emergencyStopSucceeded => 'Remote control stopped.';

  @override
  String get emergencyStopFailed =>
      'Remote control could not be stopped. Exit Roammand from the menu bar and reopen it.';

  @override
  String get trayExitAction => 'Quit Roammand';

  @override
  String get trayExitControlledTitle => 'Exit while remote control is active?';

  @override
  String get trayExitControlledBody =>
      'Roammand will first disconnect every device and stop its mouse and keyboard control.';

  @override
  String get trayConfirmExitAction => 'Stop and exit';

  @override
  String get hostIdentitySectionTitle => 'This computer';

  @override
  String hostShortFingerprint(String fingerprint) {
    return 'Safety code: $fingerprint';
  }

  @override
  String get authorizedControllersSectionTitle => 'Approved devices';

  @override
  String authorizedControllerCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count approved devices',
      one: '1 approved device',
      zero: 'No approved devices',
    );
    return '$_temp0';
  }

  @override
  String get noAuthorizedControllers =>
      'No devices have permission to control this Mac.';

  @override
  String get unknownControllerName => 'Unknown device';

  @override
  String grantCreatedLabel(String date) {
    return 'Allowed: $date';
  }

  @override
  String grantLastConnectedLabel(String date) {
    return 'Last connected: $date';
  }

  @override
  String get neverConnected => 'Never';

  @override
  String get unknownDate => 'Unknown';

  @override
  String get revokeAction => 'Remove access';

  @override
  String revokeDialogTitle(String controllerName) {
    return 'Stop allowing $controllerName?';
  }

  @override
  String get revokeDialogBody =>
      'This device will immediately lose access to this Mac. Pair it again to reconnect later.';

  @override
  String get cancelAction => 'Cancel';

  @override
  String get confirmRevokeAction => 'Remove access';

  @override
  String get revokingAction => 'Removing…';

  @override
  String get hostPairingSectionTitle => 'Add a new device';

  @override
  String get hostPairingSectionBody =>
      'Use a QR code for a phone or a one-time code for another computer. You will confirm the device before it gets access.';

  @override
  String get hostPairingEndpointMissing =>
      'Open Connection settings before pairing and choose a connection service.';

  @override
  String get hostPairingStartQrAction => 'Show mobile QR code';

  @override
  String get hostPairingStartCodeAction => 'Generate computer pairing code';

  @override
  String get hostPairingViewActiveAction => 'View current pairing';

  @override
  String get hostPairingQrTitle => 'Pair a phone';

  @override
  String get hostPairingCodeTitle => 'Pair a computer';

  @override
  String get hostPairingQrInstructions =>
      'Scan this code with the Roammand camera scanner.';

  @override
  String get hostPairingCodeInstructions =>
      'Enter this one-time code on the other computer.';

  @override
  String get hostPairingQrSemantics => 'Mobile pairing QR code';

  @override
  String hostPairingExpiresIn(String remaining) {
    return 'Expires in $remaining';
  }

  @override
  String get hostPairingCreating => 'Preparing a secure pairing code…';

  @override
  String get hostPairingWaitingController => 'Waiting for the other device…';

  @override
  String get hostPairingVerifyingController => 'Checking the other device…';

  @override
  String get hostPairingPendingControllerTitle => 'Device requesting access';

  @override
  String deviceFingerprintLabel(String fingerprint) {
    return 'Device fingerprint: $fingerprint';
  }

  @override
  String get hostPairingCompareSas => 'Compare these four words';

  @override
  String get hostPairingSasInstructions =>
      'Confirm that all four words match on both computers. If any word differs, reject the request.';

  @override
  String get hostPairingOneWayGrant =>
      'After you allow it, this device can view and control this Mac without asking again. This does not let this Mac control the other device.';

  @override
  String get hostPairingAllowAction => 'Allow control';

  @override
  String get hostPairingRejectAction => 'Reject';

  @override
  String get hostPairingCancelAction => 'Cancel pairing';

  @override
  String get hostPairingActionPending => 'Applying…';

  @override
  String get hostPairingAccepted => 'Device allowed';

  @override
  String get hostPairingRejected => 'Device rejected';

  @override
  String get hostPairingExpired => 'Pairing expired';

  @override
  String get hostPairingCancelled => 'Pairing cancelled';

  @override
  String get hostPairingFailed => 'Pairing failed';

  @override
  String get closeAction => 'Close';

  @override
  String get devicePlatformIos => 'iPhone or iPad';

  @override
  String get devicePlatformAndroid => 'Android';

  @override
  String get devicePlatformMacos => 'Mac';

  @override
  String get devicePlatformWindows => 'Windows PC';

  @override
  String get devicePlatformUnknown => 'Unknown platform';

  @override
  String get trustedComputersTitle => 'My computers';

  @override
  String get trustedComputersEmptyTitle => 'No computers paired yet';

  @override
  String get trustedComputersEmptyBody =>
      'Open Roammand on the computer you want to control, then enter its one-time pairing code here.';

  @override
  String get pairComputerAction => 'Pair a computer';

  @override
  String get trustedComputersLoadFailed => 'Saved computers are unavailable.';

  @override
  String get desktopPairingDialogTitle => 'Pair a computer';

  @override
  String get desktopPairingCodeLabel => 'One-time pairing code';

  @override
  String get desktopPairingCodeHint => 'ABCD-EFGH';

  @override
  String get invalidDesktopPairingCode => 'Pairing code is invalid.';

  @override
  String get pairAction => 'Pair';

  @override
  String get desktopPairingConnecting => 'Connecting to the computer…';

  @override
  String get desktopPairingVerifying =>
      'Checking that this is the right computer…';

  @override
  String get desktopPairingWaitingApproval =>
      'Waiting for approval on the other computer…';

  @override
  String get desktopPairingSuccess => 'Computer paired';

  @override
  String get desktopPairingRejected => 'The other computer rejected pairing';

  @override
  String get desktopPairingExpired => 'Pairing expired';

  @override
  String get desktopPairingFailed => 'Pairing failed';

  @override
  String trustedHostPairedLabel(String date) {
    return 'Paired: $date';
  }

  @override
  String trustedHostLastConnectedLabel(String date) {
    return 'Last connected: $date';
  }

  @override
  String get openRemoteAction => 'Connect';

  @override
  String get renameTrustedHostAction => 'Rename';

  @override
  String get renameTrustedHostTitle => 'Rename computer';

  @override
  String get trustedHostNameLabel => 'Computer name';

  @override
  String get trustedHostNameInvalid => 'Enter a valid computer name.';

  @override
  String get renameTrustedHostSaveAction => 'Save name';

  @override
  String get renameTrustedHostFailed => 'The computer name could not be saved.';

  @override
  String get deleteTrustedHostAction => 'Delete';

  @override
  String deleteTrustedHostTitle(String hostName) {
    return 'Delete $hostName from this device?';
  }

  @override
  String get deleteTrustedHostBody =>
      'This removes the computer from this device\'s list. To fully remove access, also revoke this device on the other computer.';

  @override
  String get confirmDeleteAction => 'Delete locally';

  @override
  String get deleteTrustedHostFailed =>
      'The computer could not be deleted from this device.';

  @override
  String get mobileDeviceFallbackName => 'My device';

  @override
  String get mobileOnboardingTitle => 'Control your Mac from this device';

  @override
  String get mobileOnboardingBody =>
      'Roammand works on both devices. Install it on the Mac you want to control, then name this device so you can recognize it when approving pairing.';

  @override
  String get mobileDeviceNameLabel => 'Device name';

  @override
  String get mobileConfirmIdentityAction => 'Continue';

  @override
  String get mobileIdentityLoading => 'Loading pairing information…';

  @override
  String get mobileIdentityFailed =>
      'Secure pairing information is unavailable.';

  @override
  String get mobileHomeTitle => 'My computers';

  @override
  String get mobileHomeEmptyTitle => 'Start on your Mac';

  @override
  String get mobileHomeEmptyBody =>
      'This device is the controller. Set up Roammand on the Mac you want to control, then create a pairing QR code there.';

  @override
  String get mobileSetupStepInstall =>
      'Install and open Roammand on the Mac you want to control.';

  @override
  String get mobileSetupStepCreateQr =>
      'On the Mac, open “This computer” and create a mobile pairing QR code.';

  @override
  String get mobileSetupStepScanApprove =>
      'Scan the code here, compare the verification words, and approve this device on the Mac.';

  @override
  String get mobileMacDownloadAction => 'Get Roammand for Mac';

  @override
  String get mobileAboutAction => 'How Roammand works';

  @override
  String get mobileScanQrAction => 'Scan computer QR code';

  @override
  String get mobileScannerTitle => 'Scan QR code';

  @override
  String get mobileScannerInstructions =>
      'Point the camera at the QR code shown on your computer.';

  @override
  String get mobileScannerTorchAction => 'Toggle flashlight';

  @override
  String get mobileScannerSwitchCameraAction => 'Switch camera';

  @override
  String get mobileScannerPermissionDenied =>
      'Camera access was denied. Allow camera access in system settings to scan a pairing QR code.';

  @override
  String get mobileScannerRestricted =>
      'Camera access is restricted on this device.';

  @override
  String get mobileScannerNoCamera => 'No usable camera is available.';

  @override
  String get mobileScannerInitializationFailed =>
      'The camera could not be started.';

  @override
  String get mobileInvalidQr =>
      'This pairing QR code is invalid or expired. Scan a new code.';

  @override
  String get mobilePairingJoining => 'Connecting to the computer…';

  @override
  String get mobilePairingVerifying =>
      'Checking that this is the right computer…';

  @override
  String get mobilePairingWaitingApproval =>
      'Waiting for approval on the computer…';

  @override
  String get mobilePairingSuccess => 'Computer paired';

  @override
  String get mobilePairingRejected => 'The computer rejected pairing';

  @override
  String get mobilePairingExpired => 'Pairing expired';

  @override
  String get mobilePairingCancelled => 'Pairing cancelled';

  @override
  String get mobilePairingFailed => 'Pairing failed';

  @override
  String get mobilePairingSignalingFailed =>
      'Could not reach the pairing service. Check the connection settings and local network access.';

  @override
  String get mobilePairingAuthenticationFailed =>
      'Could not safely confirm this computer. Generate a new QR code and try again.';

  @override
  String get mobilePairingPersistenceFailed =>
      'Pairing was approved, but this computer could not be saved securely.';

  @override
  String get mobilePairingInternalFailed =>
      'Pairing encountered an internal error. Please try again.';

  @override
  String pairingSecondsRemaining(int seconds) {
    return '${seconds}s remaining';
  }

  @override
  String get mobileControlLaterNotice =>
      'Paired and ready for a secure connection.';

  @override
  String get mobileGestureHint => 'Tap, double-tap, drag, scroll, or pinch';

  @override
  String get mobileKeyboardAction => 'Keyboard';

  @override
  String get mobileHideKeyboardAction => 'Hide keyboard';

  @override
  String get mobileLockControlsAction => 'Lock controls';

  @override
  String get mobileUnlockControlsAction => 'Unlock controls';

  @override
  String get mobileTextInputLabel => 'Text to computer';

  @override
  String get mobileSendTextAction => 'Send text';

  @override
  String get mobileModifierControl => 'Ctrl';

  @override
  String get mobileModifierShift => 'Shift';

  @override
  String get mobileModifierAlt => 'Alt';

  @override
  String get mobileModifierCommand => 'Command';

  @override
  String get mobileKeyEscape => 'Esc';

  @override
  String get mobileKeyTab => 'Tab';

  @override
  String get mobileKeyArrowLeft => 'Left';

  @override
  String get mobileKeyArrowUp => 'Up';

  @override
  String get mobileKeyArrowRight => 'Right';

  @override
  String get mobileKeyArrowDown => 'Down';

  @override
  String get remoteControlTab => 'Remote control';

  @override
  String get thisComputerTab => 'This computer';

  @override
  String get languageMenuTooltip => 'Change language';

  @override
  String get languageSystemOption => 'Follow system';

  @override
  String get languageEnglishOption => 'English';

  @override
  String get languageSimplifiedChineseOption => '简体中文';

  @override
  String get settingsTooltip => 'Settings';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsGeneralSection => 'General';

  @override
  String get settingsConnectionSection => 'Connection';

  @override
  String get settingsAdvancedSection => 'Advanced';

  @override
  String get settingsHelpSection => 'About & help';

  @override
  String get aboutSettingsTitle => 'About Roammand';

  @override
  String get aboutSettingsBody =>
      'Mac setup, user guide, open-source project, and app version.';

  @override
  String get desktopAboutSettingsBody =>
      'Set up this Mac, build the iPhone or iPad app, read the user guide, and view the open-source project.';

  @override
  String get aboutPageTitle => 'About Roammand';

  @override
  String get aboutHeroTitle => 'Your Mac, within reach';

  @override
  String get aboutHeroBody =>
      'Roammand turns this device into a trusted controller for your own Mac. The mobile app works together with Roammand installed on the Mac.';

  @override
  String get desktopAboutHeroTitle => 'Make this Mac reachable';

  @override
  String get desktopAboutHeroBody =>
      'Roammand lets devices you approve securely view and control this Mac. From Remote control, this Mac can also connect to another paired computer.';

  @override
  String get aboutGettingStartedTitle => 'How to get started';

  @override
  String get aboutGettingStartedBody =>
      'Pair the two devices once, then reconnect from My computers whenever you need your Mac.';

  @override
  String get desktopAboutGettingStartedBody =>
      'Finish the one-time Mac setup, then pair your phone. Future connections use the permission you approve here.';

  @override
  String get desktopSetupStepPermissions =>
      'Allow Screen Recording and Accessibility for Roammand in macOS System Settings.';

  @override
  String get desktopSetupStepCreateQr =>
      'Open This computer and choose Show mobile QR code.';

  @override
  String get desktopSetupStepScanApprove =>
      'Scan the code with Roammand on your iPhone or iPad, confirm the device details, then approve it on this Mac.';

  @override
  String get aboutMacAppTitle => 'Roammand for Mac';

  @override
  String get aboutMacAppBody =>
      'Install the Developer ID-signed Mac app on macOS 14.4 or later. Version 1.1.0 has not been notarized by Apple; Gatekeeper may block opening it. The Mac app provides the screen and accepts remote input only from devices you approve.';

  @override
  String get aboutMacDownloadNote =>
      'Open the download page on your Mac, or share the link from this device.';

  @override
  String get aboutIosAppTitle => 'Roammand for iPhone and iPad';

  @override
  String get aboutIosAppBody =>
      'The mobile controller is available from source. Build it for the iPhone or iPad you want to use, then pair it with this Mac by scanning a QR code.';

  @override
  String get aboutIosBuildAction => 'Open the iOS build guide';

  @override
  String get aboutIosAvailabilityNote =>
      'A public App Store download is not currently available.';

  @override
  String get aboutHelpTitle => 'User guide';

  @override
  String get aboutHelpBody =>
      'Read the complete instructions for installation, permissions, pairing, connecting, and troubleshooting.';

  @override
  String get aboutOpenGuideAction => 'Read the user guide';

  @override
  String get aboutOpenSourceTitle => 'Open source on GitHub';

  @override
  String get aboutOpenSourceBody =>
      'Review the source code, releases, security design, and project documentation on GitHub.';

  @override
  String get aboutOpenGitHubAction => 'View GitHub project';

  @override
  String get aboutPrivacyTitle => 'Private by design';

  @override
  String get aboutPrivacyBody =>
      'No account is required. Device identity and pairing permissions are stored locally, and the Mac must approve this device before it can connect.';

  @override
  String get aboutOpenPrivacyPolicyAction => 'Read the privacy policy';

  @override
  String get desktopAboutPrivacyBody =>
      'No account is required. Device identity and pairing permissions stay on this Mac. Only devices you approve can connect, and you can revoke access or stop an active session at any time.';

  @override
  String aboutVersionLabel(String version) {
    return 'Version $version';
  }

  @override
  String get externalLinkFailed =>
      'The link could not be opened. Please try again.';

  @override
  String get settingsLanguageTitle => 'Language';

  @override
  String get settingsLanguageBody => 'Choose the language used by Roammand.';

  @override
  String get uninstallSettingsTitle => 'Uninstall Roammand';

  @override
  String get uninstallSettingsBody =>
      'Completely remove the app, background components, local data, and system permissions from this Mac.';

  @override
  String get uninstallDevelopmentBuildBody =>
      'Uninstall is available from the installed macOS app, not a development build.';

  @override
  String get uninstallUnavailableBody =>
      'Uninstall is unavailable. Reinstall Roammand before trying again.';

  @override
  String get uninstallCheckingBody => 'Preparing to uninstall…';

  @override
  String get uninstallConfirmTitle => 'Uninstall Roammand?';

  @override
  String get uninstallConfirmBody =>
      'Remote connections will stop. Roammand and all of its background services will be removed from this Mac.';

  @override
  String get uninstallDeleteDataNotice =>
      'Device identity, pairing records, preferences, caches, and Roammand’s Screen Recording and Accessibility permissions will also be deleted. This cannot be undone.';

  @override
  String get uninstallConfirmAction => 'Uninstall';

  @override
  String get uninstallFailed =>
      'Roammand could not be uninstalled. No personal data was removed.';

  @override
  String get desktopControlTitle => 'Control a computer';

  @override
  String get desktopControlBody =>
      'Paste the connection information shown on the other computer to start controlling it.';

  @override
  String get hostConnectionDescriptorLabel => 'Computer connection information';

  @override
  String get hostConnectionDescriptorHint =>
      'Paste the other computer\'s connection information here';

  @override
  String get hostConnectionDescriptorPrivacy =>
      'This contains only public information needed to connect. It does not contain passwords or other secrets.';

  @override
  String get invalidHostDescriptor => 'Connection information is invalid.';

  @override
  String get connectAction => 'Connect';

  @override
  String get connectingAction => 'Connecting…';

  @override
  String remoteDesktopTitle(String hostName) {
    return 'Remote desktop — $hostName';
  }

  @override
  String get closeSessionAction => 'Close connection';

  @override
  String get remoteInputHint =>
      'Click the desktop to send mouse and keyboard input.';

  @override
  String get localExitShortcutHint => 'Local exit: Ctrl+Alt+Shift+Esc';

  @override
  String get remoteIdle => 'Ready';

  @override
  String get remoteConnecting => 'Connecting to the other computer…';

  @override
  String get remoteReconnectingPending =>
      'Connection interrupted. Preparing a secure retry…';

  @override
  String remoteReconnecting(int attempt, int maximum, int seconds) {
    return 'Reconnecting… attempt $attempt of $maximum. $seconds seconds remaining.';
  }

  @override
  String get remoteAuthenticating => 'Checking both devices…';

  @override
  String get remoteNegotiating => 'Waiting for the other computer to respond…';

  @override
  String get remoteConnected => 'Connected';

  @override
  String get remoteClosing => 'Closing and releasing input…';

  @override
  String get remoteAuthenticationFailed =>
      'Roammand could not safely confirm this is your paired computer.';

  @override
  String get remoteHostAgentFailed =>
      'The other computer\'s remote-control service is unavailable.';

  @override
  String get remoteLocalIdentityFailed =>
      'Roammand could not read this device\'s secure pairing information.';

  @override
  String get remoteSignalingFailed =>
      'Roammand could not reach the connection service.';

  @override
  String get remoteConfigurationFailed =>
      'Remote connection settings are invalid.';

  @override
  String get remoteConnectionFailed => 'The remote connection failed.';

  @override
  String get retryRemoteAction => 'Try again';

  @override
  String get diagnosticsAction => 'Diagnostics';

  @override
  String get diagnosticsTitle => 'Privacy-protected diagnostics';

  @override
  String get diagnosticsPreviewBody =>
      'If a connection fails, save this local report to review connection steps, timing, and overall network quality. You can see what is included before saving. Nothing is uploaded or copied to the clipboard.';

  @override
  String get diagnosticsIncludedTitle => 'Included';

  @override
  String get diagnosticsExcludedTitle => 'Excluded';

  @override
  String get diagnosticsIncludedVersions =>
      'Roammand and operating system versions';

  @override
  String get diagnosticsIncludedSession =>
      'Connection steps and safe error codes';

  @override
  String get diagnosticsIncludedReconnect => 'Reconnect attempts and timing';

  @override
  String get diagnosticsIncludedWebRtc =>
      'Overall connection-quality measurements';

  @override
  String get diagnosticsExcludedDeviceIdentifiers =>
      'Information that can identify a device';

  @override
  String get diagnosticsExcludedDeviceNames => 'Device names';

  @override
  String get diagnosticsExcludedKeys => 'Keys and signatures';

  @override
  String get diagnosticsExcludedTokens =>
      'Login details, passwords, and other secrets';

  @override
  String get diagnosticsExcludedSdpIce => 'Detailed networking information';

  @override
  String get diagnosticsExcludedNetworkAddresses => 'IP addresses and ports';

  @override
  String get diagnosticsExcludedInput => 'Input content and coordinates';

  @override
  String get diagnosticsExcludedScreen => 'Screen content';

  @override
  String get diagnosticsExcludedRawPayloads =>
      'Unprocessed communication content';

  @override
  String get diagnosticsExcludedRawStats => 'Unprocessed connection data';

  @override
  String diagnosticsEventSummary(int count, String truncated) {
    return 'Captured events: $count. Truncated: $truncated.';
  }

  @override
  String get diagnosticsTruncatedYes => 'yes';

  @override
  String get diagnosticsTruncatedNo => 'no';

  @override
  String get diagnosticsSaveAction => 'Save report';

  @override
  String get diagnosticsSavingAction => 'Saving…';

  @override
  String diagnosticsSaved(String path) {
    return 'Saved locally to $path';
  }

  @override
  String get diagnosticsSaveFailed => 'Unable to save the diagnostics report.';

  @override
  String get networkSettingsTooltip => 'Connection settings';

  @override
  String get networkSettingsTitle => 'Connection service';

  @override
  String get networkSettingsBody =>
      'Roammand\'s official service is recommended. Custom addresses are intended for advanced users and self-hosted setups.';

  @override
  String get networkProfileLabel => 'Choose a service';

  @override
  String get networkOfficialProfile => 'Official service';

  @override
  String get networkOfficialProfileBody =>
      'Recommended. Roammand configures the required addresses for you.';

  @override
  String get networkCustomProfile => 'Custom service';

  @override
  String get networkCustomProfileBody =>
      'For advanced users who run their own signaling and STUN services.';

  @override
  String get networkSignalingEndpointLabel => 'Signaling WebSocket address';

  @override
  String get networkSignalingEndpointHint =>
      'wss://signal.example.com/v1/connect';

  @override
  String get networkStunUrlsLabel => 'STUN addresses';

  @override
  String get networkStunUrlsHint => 'One stun: or stuns: address per line';

  @override
  String get networkStunOptionalNotice =>
      'STUN is optional for local testing. This release has no TURN fallback, so some restrictive networks cannot connect.';

  @override
  String get networkMobileHostBindingNotice =>
      'This device continues using the service address from its pairing QR code. These settings apply to computer-to-computer connections and become the default for future pairing.';

  @override
  String get networkSaveAction => 'Save settings';

  @override
  String get networkSavingAction => 'Saving…';

  @override
  String get networkRestoreAction => 'Restore official settings';

  @override
  String get networkInvalidSignaling =>
      'Enter a valid secure signaling WebSocket address. Private ws:// addresses are allowed only in an explicitly enabled debug build.';

  @override
  String get networkInvalidStun =>
      'Enter only valid stun: or stuns: addresses, one per line.';

  @override
  String get networkInvalidConfiguration =>
      'The signaling or STUN configuration is invalid.';

  @override
  String get networkSaveFailed => 'The connection settings could not be saved.';

  @override
  String get networkChangeHostTitle =>
      'Change this computer\'s network service?';

  @override
  String get networkChangeHostBody =>
      'Roammand\'s background service will restart and current remote connections will close. If the service address changes, previously paired devices must pair again.';

  @override
  String get networkConfirmChangeAction => 'Save and restart';

  @override
  String get networkConfigurationSaved => 'Connection settings saved.';

  @override
  String get networkHostMigrationSaved =>
      'Server changed. Show a new QR code to previously paired devices.';

  @override
  String get networkExternalHostRestartRequired =>
      'Settings saved. A separately started developer service is running; restart it manually with the same settings.';

  @override
  String get networkHostRestartFailed =>
      'Settings saved, but Roammand\'s background service could not restart. Exit and reopen Roammand, then check Connection settings.';

  @override
  String get mobileUnfamiliarServerTitle =>
      'Use a different connection service?';

  @override
  String mobileUnfamiliarServerBody(String endpoint) {
    return 'This QR code uses $endpoint. The service may see basic connection information or interrupt connections. Continue only if you trust the computer and the service provider.';
  }

  @override
  String get mobileTrustServerAction => 'Trust and continue';
}
