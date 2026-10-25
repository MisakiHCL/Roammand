import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Roammand'**
  String get appTitle;

  /// No description provided for @brandTagline.
  ///
  /// In en, this message translates to:
  /// **'Leave the desk. Keep work moving.'**
  String get brandTagline;

  /// No description provided for @brandPrivacyLabel.
  ///
  /// In en, this message translates to:
  /// **'Private · Account-free'**
  String get brandPrivacyLabel;

  /// No description provided for @mobileHomeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use this device to securely control your own Mac.'**
  String get mobileHomeSubtitle;

  /// No description provided for @desktopHomeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose a paired computer to connect securely.'**
  String get desktopHomeSubtitle;

  /// No description provided for @mobileIdentitySecurityNote.
  ///
  /// In en, this message translates to:
  /// **'No account required. Pairing information stays on this device.'**
  String get mobileIdentitySecurityNote;

  /// No description provided for @computerReadyLabel.
  ///
  /// In en, this message translates to:
  /// **'Ready to connect'**
  String get computerReadyLabel;

  /// No description provided for @developmentStatus.
  ///
  /// In en, this message translates to:
  /// **'Remote control is not available yet.'**
  String get developmentStatus;

  /// No description provided for @desktopHostTitle.
  ///
  /// In en, this message translates to:
  /// **'This Mac'**
  String get desktopHostTitle;

  /// No description provided for @hostAgentConnectingTitle.
  ///
  /// In en, this message translates to:
  /// **'Getting this Mac ready…'**
  String get hostAgentConnectingTitle;

  /// No description provided for @hostAgentConnectingBody.
  ///
  /// In en, this message translates to:
  /// **'Checking whether this Mac can receive remote connections.'**
  String get hostAgentConnectingBody;

  /// No description provided for @hostAgentOfflineTitle.
  ///
  /// In en, this message translates to:
  /// **'Roammand\'s background service is not running'**
  String get hostAgentOfflineTitle;

  /// No description provided for @hostAgentOfflineBody.
  ///
  /// In en, this message translates to:
  /// **'Try again. If it still does not start, reinstall Roammand.'**
  String get hostAgentOfflineBody;

  /// No description provided for @hostAgentProtectedSessionUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Lock-screen control is not available'**
  String get hostAgentProtectedSessionUnavailableTitle;

  /// No description provided for @hostAgentProtectedSessionUnavailableBody.
  ///
  /// In en, this message translates to:
  /// **'Roammand could not start the service used on the lock and login screens. Try again or reinstall Roammand.'**
  String get hostAgentProtectedSessionUnavailableBody;

  /// No description provided for @hostAgentPrivilegedBridgeUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Remote control is unavailable'**
  String get hostAgentPrivilegedBridgeUnavailableTitle;

  /// No description provided for @hostAgentPrivilegedBridgeUnavailableBody.
  ///
  /// In en, this message translates to:
  /// **'Roammand could not connect to a required macOS background feature. Reinstall Roammand, then try again.'**
  String get hostAgentPrivilegedBridgeUnavailableBody;

  /// No description provided for @hostAgentComponentMissingTitle.
  ///
  /// In en, this message translates to:
  /// **'Roammand\'s installation is incomplete'**
  String get hostAgentComponentMissingTitle;

  /// No description provided for @hostAgentComponentMissingBody.
  ///
  /// In en, this message translates to:
  /// **'Files needed for remote control are missing. Reinstall Roammand, then try again.'**
  String get hostAgentComponentMissingBody;

  /// No description provided for @hostAgentLaunchFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Roammand\'s background service could not start'**
  String get hostAgentLaunchFailedTitle;

  /// No description provided for @hostAgentLaunchFailedBody.
  ///
  /// In en, this message translates to:
  /// **'macOS could not open a background feature needed for remote control. Reinstall Roammand, then try again.'**
  String get hostAgentLaunchFailedBody;

  /// No description provided for @hostAgentConfigurationInvalidTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection settings need attention'**
  String get hostAgentConfigurationInvalidTitle;

  /// No description provided for @hostAgentConfigurationInvalidBody.
  ///
  /// In en, this message translates to:
  /// **'Open Connection settings, check the service addresses, and try again.'**
  String get hostAgentConfigurationInvalidBody;

  /// No description provided for @hostAgentUnexpectedExitTitle.
  ///
  /// In en, this message translates to:
  /// **'Roammand\'s background service stopped'**
  String get hostAgentUnexpectedExitTitle;

  /// No description provided for @hostAgentUnexpectedExitBody.
  ///
  /// In en, this message translates to:
  /// **'Try again. If it keeps stopping, reinstall Roammand.'**
  String get hostAgentUnexpectedExitBody;

  /// No description provided for @hostAgentErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'This Mac\'s status is unavailable'**
  String get hostAgentErrorTitle;

  /// No description provided for @hostAgentErrorBody.
  ///
  /// In en, this message translates to:
  /// **'Roammand could not read the current status. Wait a moment and try again.'**
  String get hostAgentErrorBody;

  /// No description provided for @retryAction.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retryAction;

  /// No description provided for @refreshAction.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refreshAction;

  /// No description provided for @privilegedBridgeSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Remote control readiness'**
  String get privilegedBridgeSectionTitle;

  /// No description provided for @privilegedBridgeNotInstalledTitle.
  ///
  /// In en, this message translates to:
  /// **'Setup is incomplete'**
  String get privilegedBridgeNotInstalledTitle;

  /// No description provided for @privilegedBridgeNotInstalledBody.
  ///
  /// In en, this message translates to:
  /// **'Reinstall Roammand to enable remote control on the desktop, lock screen, and login screen.'**
  String get privilegedBridgeNotInstalledBody;

  /// No description provided for @privilegedBridgeApprovalRequiredTitle.
  ///
  /// In en, this message translates to:
  /// **'Administrator approval is needed'**
  String get privilegedBridgeApprovalRequiredTitle;

  /// No description provided for @privilegedBridgeApprovalRequiredBody.
  ///
  /// In en, this message translates to:
  /// **'Approve Roammand when macOS asks so its background service can run.'**
  String get privilegedBridgeApprovalRequiredBody;

  /// No description provided for @privilegedBridgePermissionRequiredTitle.
  ///
  /// In en, this message translates to:
  /// **'Turn on macOS permissions'**
  String get privilegedBridgePermissionRequiredTitle;

  /// No description provided for @privilegedBridgePermissionRequiredBody.
  ///
  /// In en, this message translates to:
  /// **'Allow Screen Recording and Accessibility for Roammand in System Settings.'**
  String get privilegedBridgePermissionRequiredBody;

  /// No description provided for @macOsHostPermissionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Finish Mac permissions'**
  String get macOsHostPermissionsTitle;

  /// No description provided for @macOsHostPermissionsBody.
  ///
  /// In en, this message translates to:
  /// **'Remote connections stay unavailable until Screen Recording and Accessibility are both allowed. Set them up here before connecting from another device.'**
  String get macOsHostPermissionsBody;

  /// No description provided for @macOsHostPermissionsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Roammand could not check the installed Host permissions. Make sure the Host Agent is installed, then try again.'**
  String get macOsHostPermissionsUnavailable;

  /// No description provided for @macOsScreenRecordingPermission.
  ///
  /// In en, this message translates to:
  /// **'Screen Recording'**
  String get macOsScreenRecordingPermission;

  /// No description provided for @macOsAccessibilityPermission.
  ///
  /// In en, this message translates to:
  /// **'Accessibility'**
  String get macOsAccessibilityPermission;

  /// No description provided for @macOsPermissionGranted.
  ///
  /// In en, this message translates to:
  /// **'Allowed'**
  String get macOsPermissionGranted;

  /// No description provided for @macOsPermissionNotGranted.
  ///
  /// In en, this message translates to:
  /// **'Not allowed'**
  String get macOsPermissionNotGranted;

  /// No description provided for @macOsPermissionSetUpAction.
  ///
  /// In en, this message translates to:
  /// **'Set up'**
  String get macOsPermissionSetUpAction;

  /// No description provided for @privilegedBridgeUserSessionOnlyTitle.
  ///
  /// In en, this message translates to:
  /// **'Available only while this Mac is unlocked'**
  String get privilegedBridgeUserSessionOnlyTitle;

  /// No description provided for @privilegedBridgeUserSessionOnlyBody.
  ///
  /// In en, this message translates to:
  /// **'You can control the desktop now, but not the lock or login screen.'**
  String get privilegedBridgeUserSessionOnlyBody;

  /// No description provided for @privilegedBridgeReadyNormalTitle.
  ///
  /// In en, this message translates to:
  /// **'This Mac is ready'**
  String get privilegedBridgeReadyNormalTitle;

  /// No description provided for @privilegedBridgeReadyNormalBody.
  ///
  /// In en, this message translates to:
  /// **'Approved devices can connect to this Mac.'**
  String get privilegedBridgeReadyNormalBody;

  /// No description provided for @privilegedBridgeReadyLockedTitle.
  ///
  /// In en, this message translates to:
  /// **'Lock-screen control is ready'**
  String get privilegedBridgeReadyLockedTitle;

  /// No description provided for @privilegedBridgeReadyLockedBody.
  ///
  /// In en, this message translates to:
  /// **'Approved devices can stay connected when this Mac is locked or showing the login screen.'**
  String get privilegedBridgeReadyLockedBody;

  /// No description provided for @privilegedBridgeReadySecureTitle.
  ///
  /// In en, this message translates to:
  /// **'System screens can also be controlled'**
  String get privilegedBridgeReadySecureTitle;

  /// No description provided for @privilegedBridgeReadySecureBody.
  ///
  /// In en, this message translates to:
  /// **'Remote control stays available on macOS screens such as the lock and login screens.'**
  String get privilegedBridgeReadySecureBody;

  /// No description provided for @privilegedBridgeReadyUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the desktop'**
  String get privilegedBridgeReadyUnavailableTitle;

  /// No description provided for @privilegedBridgeReadyUnavailableBody.
  ///
  /// In en, this message translates to:
  /// **'There is no desktop to control right now. Roammand will become available when macOS is ready.'**
  String get privilegedBridgeReadyUnavailableBody;

  /// No description provided for @privilegedBridgeTransitioningTitle.
  ///
  /// In en, this message translates to:
  /// **'Switching screens…'**
  String get privilegedBridgeTransitioningTitle;

  /// No description provided for @privilegedBridgeTransitioningBody.
  ///
  /// In en, this message translates to:
  /// **'Remote input is paused briefly while macOS changes screens.'**
  String get privilegedBridgeTransitioningBody;

  /// No description provided for @privilegedBridgeReconnectingTitle.
  ///
  /// In en, this message translates to:
  /// **'Restoring remote control…'**
  String get privilegedBridgeReconnectingTitle;

  /// No description provided for @privilegedBridgeReconnectingBody.
  ///
  /// In en, this message translates to:
  /// **'Remote input stays paused until the connection to this Mac is safe again.'**
  String get privilegedBridgeReconnectingBody;

  /// No description provided for @privilegedBridgeControlledTitle.
  ///
  /// In en, this message translates to:
  /// **'Controlled by {controllerName}'**
  String privilegedBridgeControlledTitle(String controllerName);

  /// No description provided for @privilegedBridgeControlledUnknownTitle.
  ///
  /// In en, this message translates to:
  /// **'Remote control is active'**
  String get privilegedBridgeControlledUnknownTitle;

  /// No description provided for @privilegedBridgeControlledBody.
  ///
  /// In en, this message translates to:
  /// **'Select Emergency stop below to end every remote connection immediately.'**
  String get privilegedBridgeControlledBody;

  /// No description provided for @privilegedBridgeFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Remote control service is unavailable'**
  String get privilegedBridgeFailedTitle;

  /// No description provided for @privilegedBridgeFailedBody.
  ///
  /// In en, this message translates to:
  /// **'Check Roammand\'s macOS permissions. If they are already on, reinstall Roammand.'**
  String get privilegedBridgeFailedBody;

  /// No description provided for @privilegedBridgeUnknownTitle.
  ///
  /// In en, this message translates to:
  /// **'Remote control status is unavailable'**
  String get privilegedBridgeUnknownTitle;

  /// No description provided for @privilegedBridgeUnknownBody.
  ///
  /// In en, this message translates to:
  /// **'Refresh the page. If the status does not return, reopen Roammand.'**
  String get privilegedBridgeUnknownBody;

  /// No description provided for @emergencyStopAction.
  ///
  /// In en, this message translates to:
  /// **'Emergency stop'**
  String get emergencyStopAction;

  /// No description provided for @emergencyStoppingAction.
  ///
  /// In en, this message translates to:
  /// **'Stopping…'**
  String get emergencyStoppingAction;

  /// No description provided for @emergencyStopDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Stop remote control?'**
  String get emergencyStopDialogTitle;

  /// No description provided for @emergencyStopDialogBody.
  ///
  /// In en, this message translates to:
  /// **'This immediately disconnects every device and stops its mouse and keyboard control. Your approved-device list is kept.'**
  String get emergencyStopDialogBody;

  /// No description provided for @confirmEmergencyStopAction.
  ///
  /// In en, this message translates to:
  /// **'Stop now'**
  String get confirmEmergencyStopAction;

  /// No description provided for @emergencyStopSucceeded.
  ///
  /// In en, this message translates to:
  /// **'Remote control stopped.'**
  String get emergencyStopSucceeded;

  /// No description provided for @emergencyStopFailed.
  ///
  /// In en, this message translates to:
  /// **'Remote control could not be stopped. Exit Roammand from the menu bar and reopen it.'**
  String get emergencyStopFailed;

  /// No description provided for @trayExitAction.
  ///
  /// In en, this message translates to:
  /// **'Quit Roammand'**
  String get trayExitAction;

  /// No description provided for @trayExitControlledTitle.
  ///
  /// In en, this message translates to:
  /// **'Exit while remote control is active?'**
  String get trayExitControlledTitle;

  /// No description provided for @trayExitControlledBody.
  ///
  /// In en, this message translates to:
  /// **'Roammand will first disconnect every device and stop its mouse and keyboard control.'**
  String get trayExitControlledBody;

  /// No description provided for @trayConfirmExitAction.
  ///
  /// In en, this message translates to:
  /// **'Stop and exit'**
  String get trayConfirmExitAction;

  /// No description provided for @hostIdentitySectionTitle.
  ///
  /// In en, this message translates to:
  /// **'This computer'**
  String get hostIdentitySectionTitle;

  /// No description provided for @hostShortFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Safety code: {fingerprint}'**
  String hostShortFingerprint(String fingerprint);

  /// No description provided for @authorizedControllersSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Approved devices'**
  String get authorizedControllersSectionTitle;

  /// No description provided for @authorizedControllerCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No approved devices} =1{1 approved device} other{{count} approved devices}}'**
  String authorizedControllerCount(int count);

  /// No description provided for @noAuthorizedControllers.
  ///
  /// In en, this message translates to:
  /// **'No devices have permission to control this Mac.'**
  String get noAuthorizedControllers;

  /// No description provided for @unknownControllerName.
  ///
  /// In en, this message translates to:
  /// **'Unknown device'**
  String get unknownControllerName;

  /// No description provided for @grantCreatedLabel.
  ///
  /// In en, this message translates to:
  /// **'Allowed: {date}'**
  String grantCreatedLabel(String date);

  /// No description provided for @grantLastConnectedLabel.
  ///
  /// In en, this message translates to:
  /// **'Last connected: {date}'**
  String grantLastConnectedLabel(String date);

  /// No description provided for @neverConnected.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get neverConnected;

  /// No description provided for @unknownDate.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get unknownDate;

  /// No description provided for @revokeAction.
  ///
  /// In en, this message translates to:
  /// **'Remove access'**
  String get revokeAction;

  /// No description provided for @revokeDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Stop allowing {controllerName}?'**
  String revokeDialogTitle(String controllerName);

  /// No description provided for @revokeDialogBody.
  ///
  /// In en, this message translates to:
  /// **'This device will immediately lose access to this Mac. Pair it again to reconnect later.'**
  String get revokeDialogBody;

  /// No description provided for @cancelAction.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancelAction;

  /// No description provided for @confirmRevokeAction.
  ///
  /// In en, this message translates to:
  /// **'Remove access'**
  String get confirmRevokeAction;

  /// No description provided for @revokingAction.
  ///
  /// In en, this message translates to:
  /// **'Removing…'**
  String get revokingAction;

  /// Heading for starting device pairing; authorization is confirmed later.
  ///
  /// In en, this message translates to:
  /// **'Add a new device'**
  String get hostPairingSectionTitle;

  /// No description provided for @hostPairingSectionBody.
  ///
  /// In en, this message translates to:
  /// **'Use a QR code for a phone or a one-time code for another computer. You will confirm the device before it gets access.'**
  String get hostPairingSectionBody;

  /// No description provided for @hostPairingEndpointMissing.
  ///
  /// In en, this message translates to:
  /// **'Open Connection settings before pairing and choose a connection service.'**
  String get hostPairingEndpointMissing;

  /// No description provided for @hostPairingStartQrAction.
  ///
  /// In en, this message translates to:
  /// **'Show mobile QR code'**
  String get hostPairingStartQrAction;

  /// No description provided for @hostPairingStartCodeAction.
  ///
  /// In en, this message translates to:
  /// **'Generate computer pairing code'**
  String get hostPairingStartCodeAction;

  /// No description provided for @hostPairingViewActiveAction.
  ///
  /// In en, this message translates to:
  /// **'View current pairing'**
  String get hostPairingViewActiveAction;

  /// No description provided for @hostPairingQrTitle.
  ///
  /// In en, this message translates to:
  /// **'Pair a phone'**
  String get hostPairingQrTitle;

  /// No description provided for @hostPairingCodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Pair a computer'**
  String get hostPairingCodeTitle;

  /// No description provided for @hostPairingQrInstructions.
  ///
  /// In en, this message translates to:
  /// **'Scan this code with the Roammand camera scanner.'**
  String get hostPairingQrInstructions;

  /// No description provided for @hostPairingCodeInstructions.
  ///
  /// In en, this message translates to:
  /// **'Enter this one-time code on the other computer.'**
  String get hostPairingCodeInstructions;

  /// No description provided for @hostPairingQrSemantics.
  ///
  /// In en, this message translates to:
  /// **'Mobile pairing QR code'**
  String get hostPairingQrSemantics;

  /// No description provided for @hostPairingExpiresIn.
  ///
  /// In en, this message translates to:
  /// **'Expires in {remaining}'**
  String hostPairingExpiresIn(String remaining);

  /// No description provided for @hostPairingCreating.
  ///
  /// In en, this message translates to:
  /// **'Preparing a secure pairing code…'**
  String get hostPairingCreating;

  /// No description provided for @hostPairingWaitingController.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the other device…'**
  String get hostPairingWaitingController;

  /// No description provided for @hostPairingVerifyingController.
  ///
  /// In en, this message translates to:
  /// **'Checking the other device…'**
  String get hostPairingVerifyingController;

  /// No description provided for @hostPairingPendingControllerTitle.
  ///
  /// In en, this message translates to:
  /// **'Device requesting access'**
  String get hostPairingPendingControllerTitle;

  /// No description provided for @deviceFingerprintLabel.
  ///
  /// In en, this message translates to:
  /// **'Device fingerprint: {fingerprint}'**
  String deviceFingerprintLabel(String fingerprint);

  /// No description provided for @hostPairingCompareSas.
  ///
  /// In en, this message translates to:
  /// **'Compare these four words'**
  String get hostPairingCompareSas;

  /// No description provided for @hostPairingSasInstructions.
  ///
  /// In en, this message translates to:
  /// **'Confirm that all four words match on both computers. If any word differs, reject the request.'**
  String get hostPairingSasInstructions;

  /// No description provided for @hostPairingOneWayGrant.
  ///
  /// In en, this message translates to:
  /// **'After you allow it, this device can view and control this Mac without asking again. This does not let this Mac control the other device.'**
  String get hostPairingOneWayGrant;

  /// No description provided for @hostPairingAllowAction.
  ///
  /// In en, this message translates to:
  /// **'Allow control'**
  String get hostPairingAllowAction;

  /// No description provided for @hostPairingRejectAction.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get hostPairingRejectAction;

  /// No description provided for @hostPairingCancelAction.
  ///
  /// In en, this message translates to:
  /// **'Cancel pairing'**
  String get hostPairingCancelAction;

  /// No description provided for @hostPairingActionPending.
  ///
  /// In en, this message translates to:
  /// **'Applying…'**
  String get hostPairingActionPending;

  /// No description provided for @hostPairingAccepted.
  ///
  /// In en, this message translates to:
  /// **'Device allowed'**
  String get hostPairingAccepted;

  /// No description provided for @hostPairingRejected.
  ///
  /// In en, this message translates to:
  /// **'Device rejected'**
  String get hostPairingRejected;

  /// No description provided for @hostPairingExpired.
  ///
  /// In en, this message translates to:
  /// **'Pairing expired'**
  String get hostPairingExpired;

  /// No description provided for @hostPairingCancelled.
  ///
  /// In en, this message translates to:
  /// **'Pairing cancelled'**
  String get hostPairingCancelled;

  /// No description provided for @hostPairingFailed.
  ///
  /// In en, this message translates to:
  /// **'Pairing failed'**
  String get hostPairingFailed;

  /// No description provided for @closeAction.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get closeAction;

  /// No description provided for @devicePlatformIos.
  ///
  /// In en, this message translates to:
  /// **'iPhone or iPad'**
  String get devicePlatformIos;

  /// No description provided for @devicePlatformAndroid.
  ///
  /// In en, this message translates to:
  /// **'Android'**
  String get devicePlatformAndroid;

  /// No description provided for @devicePlatformMacos.
  ///
  /// In en, this message translates to:
  /// **'Mac'**
  String get devicePlatformMacos;

  /// No description provided for @devicePlatformWindows.
  ///
  /// In en, this message translates to:
  /// **'Windows PC'**
  String get devicePlatformWindows;

  /// No description provided for @devicePlatformUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown platform'**
  String get devicePlatformUnknown;

  /// No description provided for @trustedComputersTitle.
  ///
  /// In en, this message translates to:
  /// **'My computers'**
  String get trustedComputersTitle;

  /// No description provided for @trustedComputersEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No computers paired yet'**
  String get trustedComputersEmptyTitle;

  /// No description provided for @trustedComputersEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Open Roammand on the computer you want to control, then enter its one-time pairing code here.'**
  String get trustedComputersEmptyBody;

  /// No description provided for @pairComputerAction.
  ///
  /// In en, this message translates to:
  /// **'Pair a computer'**
  String get pairComputerAction;

  /// No description provided for @trustedComputersLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Saved computers are unavailable.'**
  String get trustedComputersLoadFailed;

  /// No description provided for @desktopPairingDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Pair a computer'**
  String get desktopPairingDialogTitle;

  /// No description provided for @desktopPairingCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'One-time pairing code'**
  String get desktopPairingCodeLabel;

  /// No description provided for @desktopPairingCodeHint.
  ///
  /// In en, this message translates to:
  /// **'ABCD-EFGH'**
  String get desktopPairingCodeHint;

  /// No description provided for @invalidDesktopPairingCode.
  ///
  /// In en, this message translates to:
  /// **'Pairing code is invalid.'**
  String get invalidDesktopPairingCode;

  /// No description provided for @pairAction.
  ///
  /// In en, this message translates to:
  /// **'Pair'**
  String get pairAction;

  /// No description provided for @desktopPairingConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to the computer…'**
  String get desktopPairingConnecting;

  /// No description provided for @desktopPairingVerifying.
  ///
  /// In en, this message translates to:
  /// **'Checking that this is the right computer…'**
  String get desktopPairingVerifying;

  /// No description provided for @desktopPairingWaitingApproval.
  ///
  /// In en, this message translates to:
  /// **'Waiting for approval on the other computer…'**
  String get desktopPairingWaitingApproval;

  /// No description provided for @desktopPairingSuccess.
  ///
  /// In en, this message translates to:
  /// **'Computer paired'**
  String get desktopPairingSuccess;

  /// No description provided for @desktopPairingRejected.
  ///
  /// In en, this message translates to:
  /// **'The other computer rejected pairing'**
  String get desktopPairingRejected;

  /// No description provided for @desktopPairingExpired.
  ///
  /// In en, this message translates to:
  /// **'Pairing expired'**
  String get desktopPairingExpired;

  /// No description provided for @desktopPairingFailed.
  ///
  /// In en, this message translates to:
  /// **'Pairing failed'**
  String get desktopPairingFailed;

  /// No description provided for @trustedHostPairedLabel.
  ///
  /// In en, this message translates to:
  /// **'Paired: {date}'**
  String trustedHostPairedLabel(String date);

  /// No description provided for @trustedHostLastConnectedLabel.
  ///
  /// In en, this message translates to:
  /// **'Last connected: {date}'**
  String trustedHostLastConnectedLabel(String date);

  /// No description provided for @openRemoteAction.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get openRemoteAction;

  /// No description provided for @renameTrustedHostAction.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get renameTrustedHostAction;

  /// No description provided for @renameTrustedHostTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename computer'**
  String get renameTrustedHostTitle;

  /// No description provided for @trustedHostNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Computer name'**
  String get trustedHostNameLabel;

  /// No description provided for @trustedHostNameInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid computer name.'**
  String get trustedHostNameInvalid;

  /// No description provided for @renameTrustedHostSaveAction.
  ///
  /// In en, this message translates to:
  /// **'Save name'**
  String get renameTrustedHostSaveAction;

  /// No description provided for @renameTrustedHostFailed.
  ///
  /// In en, this message translates to:
  /// **'The computer name could not be saved.'**
  String get renameTrustedHostFailed;

  /// No description provided for @deleteTrustedHostAction.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get deleteTrustedHostAction;

  /// No description provided for @deleteTrustedHostTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete {hostName} from this device?'**
  String deleteTrustedHostTitle(String hostName);

  /// No description provided for @deleteTrustedHostBody.
  ///
  /// In en, this message translates to:
  /// **'This removes the computer from this device\'s list. To fully remove access, also revoke this device on the other computer.'**
  String get deleteTrustedHostBody;

  /// No description provided for @confirmDeleteAction.
  ///
  /// In en, this message translates to:
  /// **'Delete locally'**
  String get confirmDeleteAction;

  /// No description provided for @deleteTrustedHostFailed.
  ///
  /// In en, this message translates to:
  /// **'The computer could not be deleted from this device.'**
  String get deleteTrustedHostFailed;

  /// No description provided for @mobileDeviceFallbackName.
  ///
  /// In en, this message translates to:
  /// **'My device'**
  String get mobileDeviceFallbackName;

  /// No description provided for @mobileOnboardingTitle.
  ///
  /// In en, this message translates to:
  /// **'Control your Mac from this device'**
  String get mobileOnboardingTitle;

  /// No description provided for @mobileOnboardingBody.
  ///
  /// In en, this message translates to:
  /// **'Roammand works on both devices. Install it on the Mac you want to control, then name this device so you can recognize it when approving pairing.'**
  String get mobileOnboardingBody;

  /// No description provided for @mobileDeviceNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get mobileDeviceNameLabel;

  /// No description provided for @mobileConfirmIdentityAction.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get mobileConfirmIdentityAction;

  /// No description provided for @mobileIdentityLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading pairing information…'**
  String get mobileIdentityLoading;

  /// No description provided for @mobileIdentityFailed.
  ///
  /// In en, this message translates to:
  /// **'Secure pairing information is unavailable.'**
  String get mobileIdentityFailed;

  /// No description provided for @mobileHomeTitle.
  ///
  /// In en, this message translates to:
  /// **'My computers'**
  String get mobileHomeTitle;

  /// No description provided for @mobileHomeEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Start on your Mac'**
  String get mobileHomeEmptyTitle;

  /// No description provided for @mobileHomeEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'This device is the controller. Set up Roammand on the Mac you want to control, then create a pairing QR code there.'**
  String get mobileHomeEmptyBody;

  /// No description provided for @mobileSetupStepInstall.
  ///
  /// In en, this message translates to:
  /// **'Install and open Roammand on the Mac you want to control.'**
  String get mobileSetupStepInstall;

  /// No description provided for @mobileSetupStepCreateQr.
  ///
  /// In en, this message translates to:
  /// **'On the Mac, open “This computer” and create a mobile pairing QR code.'**
  String get mobileSetupStepCreateQr;

  /// No description provided for @mobileSetupStepScanApprove.
  ///
  /// In en, this message translates to:
  /// **'Scan the code here, compare the verification words, and approve this device on the Mac.'**
  String get mobileSetupStepScanApprove;

  /// No description provided for @mobileMacDownloadAction.
  ///
  /// In en, this message translates to:
  /// **'Get Roammand for Mac'**
  String get mobileMacDownloadAction;

  /// No description provided for @mobileAboutAction.
  ///
  /// In en, this message translates to:
  /// **'How Roammand works'**
  String get mobileAboutAction;

  /// No description provided for @mobileScanQrAction.
  ///
  /// In en, this message translates to:
  /// **'Scan computer QR code'**
  String get mobileScanQrAction;

  /// No description provided for @mobileScannerTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan QR code'**
  String get mobileScannerTitle;

  /// No description provided for @mobileScannerInstructions.
  ///
  /// In en, this message translates to:
  /// **'Point the camera at the QR code shown on your computer.'**
  String get mobileScannerInstructions;

  /// No description provided for @mobileScannerTorchAction.
  ///
  /// In en, this message translates to:
  /// **'Toggle flashlight'**
  String get mobileScannerTorchAction;

  /// No description provided for @mobileScannerSwitchCameraAction.
  ///
  /// In en, this message translates to:
  /// **'Switch camera'**
  String get mobileScannerSwitchCameraAction;

  /// No description provided for @mobileScannerPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Camera access was denied. Allow camera access in system settings to scan a pairing QR code.'**
  String get mobileScannerPermissionDenied;

  /// No description provided for @mobileScannerRestricted.
  ///
  /// In en, this message translates to:
  /// **'Camera access is restricted on this device.'**
  String get mobileScannerRestricted;

  /// No description provided for @mobileScannerNoCamera.
  ///
  /// In en, this message translates to:
  /// **'No usable camera is available.'**
  String get mobileScannerNoCamera;

  /// No description provided for @mobileScannerInitializationFailed.
  ///
  /// In en, this message translates to:
  /// **'The camera could not be started.'**
  String get mobileScannerInitializationFailed;

  /// No description provided for @mobileInvalidQr.
  ///
  /// In en, this message translates to:
  /// **'This pairing QR code is invalid or expired. Scan a new code.'**
  String get mobileInvalidQr;

  /// No description provided for @mobilePairingJoining.
  ///
  /// In en, this message translates to:
  /// **'Connecting to the computer…'**
  String get mobilePairingJoining;

  /// No description provided for @mobilePairingVerifying.
  ///
  /// In en, this message translates to:
  /// **'Checking that this is the right computer…'**
  String get mobilePairingVerifying;

  /// No description provided for @mobilePairingWaitingApproval.
  ///
  /// In en, this message translates to:
  /// **'Waiting for approval on the computer…'**
  String get mobilePairingWaitingApproval;

  /// No description provided for @mobilePairingSuccess.
  ///
  /// In en, this message translates to:
  /// **'Computer paired'**
  String get mobilePairingSuccess;

  /// No description provided for @mobilePairingRejected.
  ///
  /// In en, this message translates to:
  /// **'The computer rejected pairing'**
  String get mobilePairingRejected;

  /// No description provided for @mobilePairingExpired.
  ///
  /// In en, this message translates to:
  /// **'Pairing expired'**
  String get mobilePairingExpired;

  /// No description provided for @mobilePairingCancelled.
  ///
  /// In en, this message translates to:
  /// **'Pairing cancelled'**
  String get mobilePairingCancelled;

  /// No description provided for @mobilePairingFailed.
  ///
  /// In en, this message translates to:
  /// **'Pairing failed'**
  String get mobilePairingFailed;

  /// No description provided for @mobilePairingSignalingFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the pairing service. Check the connection settings and local network access.'**
  String get mobilePairingSignalingFailed;

  /// No description provided for @mobilePairingAuthenticationFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not safely confirm this computer. Generate a new QR code and try again.'**
  String get mobilePairingAuthenticationFailed;

  /// No description provided for @mobilePairingPersistenceFailed.
  ///
  /// In en, this message translates to:
  /// **'Pairing was approved, but this computer could not be saved securely.'**
  String get mobilePairingPersistenceFailed;

  /// No description provided for @mobilePairingInternalFailed.
  ///
  /// In en, this message translates to:
  /// **'Pairing encountered an internal error. Please try again.'**
  String get mobilePairingInternalFailed;

  /// No description provided for @pairingSecondsRemaining.
  ///
  /// In en, this message translates to:
  /// **'{seconds}s remaining'**
  String pairingSecondsRemaining(int seconds);

  /// No description provided for @mobileControlLaterNotice.
  ///
  /// In en, this message translates to:
  /// **'Paired and ready for a secure connection.'**
  String get mobileControlLaterNotice;

  /// No description provided for @mobileGestureHint.
  ///
  /// In en, this message translates to:
  /// **'Tap, double-tap, drag, scroll, or pinch'**
  String get mobileGestureHint;

  /// No description provided for @mobileKeyboardAction.
  ///
  /// In en, this message translates to:
  /// **'Keyboard'**
  String get mobileKeyboardAction;

  /// No description provided for @mobileHideKeyboardAction.
  ///
  /// In en, this message translates to:
  /// **'Hide keyboard'**
  String get mobileHideKeyboardAction;

  /// No description provided for @mobileLockControlsAction.
  ///
  /// In en, this message translates to:
  /// **'Lock controls'**
  String get mobileLockControlsAction;

  /// No description provided for @mobileUnlockControlsAction.
  ///
  /// In en, this message translates to:
  /// **'Unlock controls'**
  String get mobileUnlockControlsAction;

  /// No description provided for @mobileTextInputLabel.
  ///
  /// In en, this message translates to:
  /// **'Text to computer'**
  String get mobileTextInputLabel;

  /// No description provided for @mobileSendTextAction.
  ///
  /// In en, this message translates to:
  /// **'Send text'**
  String get mobileSendTextAction;

  /// No description provided for @mobileModifierControl.
  ///
  /// In en, this message translates to:
  /// **'Ctrl'**
  String get mobileModifierControl;

  /// No description provided for @mobileModifierShift.
  ///
  /// In en, this message translates to:
  /// **'Shift'**
  String get mobileModifierShift;

  /// No description provided for @mobileModifierAlt.
  ///
  /// In en, this message translates to:
  /// **'Alt'**
  String get mobileModifierAlt;

  /// No description provided for @mobileModifierCommand.
  ///
  /// In en, this message translates to:
  /// **'Command'**
  String get mobileModifierCommand;

  /// No description provided for @mobileKeyEscape.
  ///
  /// In en, this message translates to:
  /// **'Esc'**
  String get mobileKeyEscape;

  /// No description provided for @mobileKeyTab.
  ///
  /// In en, this message translates to:
  /// **'Tab'**
  String get mobileKeyTab;

  /// No description provided for @mobileKeyArrowLeft.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get mobileKeyArrowLeft;

  /// No description provided for @mobileKeyArrowUp.
  ///
  /// In en, this message translates to:
  /// **'Up'**
  String get mobileKeyArrowUp;

  /// No description provided for @mobileKeyArrowRight.
  ///
  /// In en, this message translates to:
  /// **'Right'**
  String get mobileKeyArrowRight;

  /// No description provided for @mobileKeyArrowDown.
  ///
  /// In en, this message translates to:
  /// **'Down'**
  String get mobileKeyArrowDown;

  /// No description provided for @remoteControlTab.
  ///
  /// In en, this message translates to:
  /// **'Remote control'**
  String get remoteControlTab;

  /// No description provided for @thisComputerTab.
  ///
  /// In en, this message translates to:
  /// **'This computer'**
  String get thisComputerTab;

  /// No description provided for @languageMenuTooltip.
  ///
  /// In en, this message translates to:
  /// **'Change language'**
  String get languageMenuTooltip;

  /// No description provided for @languageSystemOption.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get languageSystemOption;

  /// No description provided for @languageEnglishOption.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglishOption;

  /// No description provided for @languageSimplifiedChineseOption.
  ///
  /// In en, this message translates to:
  /// **'简体中文'**
  String get languageSimplifiedChineseOption;

  /// No description provided for @settingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTooltip;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsGeneralSection.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get settingsGeneralSection;

  /// No description provided for @settingsConnectionSection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get settingsConnectionSection;

  /// No description provided for @settingsAdvancedSection.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get settingsAdvancedSection;

  /// No description provided for @settingsHelpSection.
  ///
  /// In en, this message translates to:
  /// **'About & help'**
  String get settingsHelpSection;

  /// No description provided for @aboutSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'About Roammand'**
  String get aboutSettingsTitle;

  /// No description provided for @aboutSettingsBody.
  ///
  /// In en, this message translates to:
  /// **'Mac setup, user guide, open-source project, and app version.'**
  String get aboutSettingsBody;

  /// No description provided for @desktopAboutSettingsBody.
  ///
  /// In en, this message translates to:
  /// **'Set up this Mac, build the iPhone or iPad app, read the user guide, and view the open-source project.'**
  String get desktopAboutSettingsBody;

  /// No description provided for @aboutPageTitle.
  ///
  /// In en, this message translates to:
  /// **'About Roammand'**
  String get aboutPageTitle;

  /// No description provided for @aboutHeroTitle.
  ///
  /// In en, this message translates to:
  /// **'Your Mac, within reach'**
  String get aboutHeroTitle;

  /// No description provided for @aboutHeroBody.
  ///
  /// In en, this message translates to:
  /// **'Roammand turns this device into a trusted controller for your own Mac. The mobile app works together with Roammand installed on the Mac.'**
  String get aboutHeroBody;

  /// No description provided for @desktopAboutHeroTitle.
  ///
  /// In en, this message translates to:
  /// **'Make this Mac reachable'**
  String get desktopAboutHeroTitle;

  /// No description provided for @desktopAboutHeroBody.
  ///
  /// In en, this message translates to:
  /// **'Roammand lets devices you approve securely view and control this Mac. From Remote control, this Mac can also connect to another paired computer.'**
  String get desktopAboutHeroBody;

  /// No description provided for @aboutGettingStartedTitle.
  ///
  /// In en, this message translates to:
  /// **'How to get started'**
  String get aboutGettingStartedTitle;

  /// No description provided for @aboutGettingStartedBody.
  ///
  /// In en, this message translates to:
  /// **'Pair the two devices once, then reconnect from My computers whenever you need your Mac.'**
  String get aboutGettingStartedBody;

  /// No description provided for @desktopAboutGettingStartedBody.
  ///
  /// In en, this message translates to:
  /// **'Finish the one-time Mac setup, then pair your phone. Future connections use the permission you approve here.'**
  String get desktopAboutGettingStartedBody;

  /// No description provided for @desktopSetupStepPermissions.
  ///
  /// In en, this message translates to:
  /// **'Allow Screen Recording and Accessibility for Roammand in macOS System Settings.'**
  String get desktopSetupStepPermissions;

  /// No description provided for @desktopSetupStepCreateQr.
  ///
  /// In en, this message translates to:
  /// **'Open This computer and choose Show mobile QR code.'**
  String get desktopSetupStepCreateQr;

  /// No description provided for @desktopSetupStepScanApprove.
  ///
  /// In en, this message translates to:
  /// **'Scan the code with Roammand on your iPhone or iPad, confirm the device details, then approve it on this Mac.'**
  String get desktopSetupStepScanApprove;

  /// No description provided for @aboutMacAppTitle.
  ///
  /// In en, this message translates to:
  /// **'Roammand for Mac'**
  String get aboutMacAppTitle;

  /// No description provided for @aboutMacAppBody.
  ///
  /// In en, this message translates to:
  /// **'Install the Developer ID-signed Mac app on macOS 14.4 or later. Version 1.1.0 has not been notarized by Apple; Gatekeeper may block opening it. The Mac app provides the screen and accepts remote input only from devices you approve.'**
  String get aboutMacAppBody;

  /// No description provided for @aboutMacDownloadNote.
  ///
  /// In en, this message translates to:
  /// **'Open the download page on your Mac, or share the link from this device.'**
  String get aboutMacDownloadNote;

  /// No description provided for @aboutIosAppTitle.
  ///
  /// In en, this message translates to:
  /// **'Roammand for iPhone and iPad'**
  String get aboutIosAppTitle;

  /// No description provided for @aboutIosAppBody.
  ///
  /// In en, this message translates to:
  /// **'The mobile controller is available from source. Build it for the iPhone or iPad you want to use, then pair it with this Mac by scanning a QR code.'**
  String get aboutIosAppBody;

  /// No description provided for @aboutIosBuildAction.
  ///
  /// In en, this message translates to:
  /// **'Open the iOS build guide'**
  String get aboutIosBuildAction;

  /// No description provided for @aboutIosAvailabilityNote.
  ///
  /// In en, this message translates to:
  /// **'A public App Store download is not currently available.'**
  String get aboutIosAvailabilityNote;

  /// No description provided for @aboutHelpTitle.
  ///
  /// In en, this message translates to:
  /// **'User guide'**
  String get aboutHelpTitle;

  /// No description provided for @aboutHelpBody.
  ///
  /// In en, this message translates to:
  /// **'Read the complete instructions for installation, permissions, pairing, connecting, and troubleshooting.'**
  String get aboutHelpBody;

  /// No description provided for @aboutOpenGuideAction.
  ///
  /// In en, this message translates to:
  /// **'Read the user guide'**
  String get aboutOpenGuideAction;

  /// No description provided for @aboutOpenSourceTitle.
  ///
  /// In en, this message translates to:
  /// **'Open source on GitHub'**
  String get aboutOpenSourceTitle;

  /// No description provided for @aboutOpenSourceBody.
  ///
  /// In en, this message translates to:
  /// **'Review the source code, releases, security design, and project documentation on GitHub.'**
  String get aboutOpenSourceBody;

  /// No description provided for @aboutOpenGitHubAction.
  ///
  /// In en, this message translates to:
  /// **'View GitHub project'**
  String get aboutOpenGitHubAction;

  /// No description provided for @aboutPrivacyTitle.
  ///
  /// In en, this message translates to:
  /// **'Private by design'**
  String get aboutPrivacyTitle;

  /// No description provided for @aboutPrivacyBody.
  ///
  /// In en, this message translates to:
  /// **'No account is required. Device identity and pairing permissions are stored locally, and the Mac must approve this device before it can connect.'**
  String get aboutPrivacyBody;

  /// No description provided for @aboutOpenPrivacyPolicyAction.
  ///
  /// In en, this message translates to:
  /// **'Read the privacy policy'**
  String get aboutOpenPrivacyPolicyAction;

  /// No description provided for @desktopAboutPrivacyBody.
  ///
  /// In en, this message translates to:
  /// **'No account is required. Device identity and pairing permissions stay on this Mac. Only devices you approve can connect, and you can revoke access or stop an active session at any time.'**
  String get desktopAboutPrivacyBody;

  /// No description provided for @aboutVersionLabel.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String aboutVersionLabel(String version);

  /// No description provided for @externalLinkFailed.
  ///
  /// In en, this message translates to:
  /// **'The link could not be opened. Please try again.'**
  String get externalLinkFailed;

  /// No description provided for @settingsLanguageTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguageTitle;

  /// No description provided for @settingsLanguageBody.
  ///
  /// In en, this message translates to:
  /// **'Choose the language used by Roammand.'**
  String get settingsLanguageBody;

  /// No description provided for @uninstallSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Uninstall Roammand'**
  String get uninstallSettingsTitle;

  /// No description provided for @uninstallSettingsBody.
  ///
  /// In en, this message translates to:
  /// **'Completely remove the app, background components, local data, and system permissions from this Mac.'**
  String get uninstallSettingsBody;

  /// No description provided for @uninstallDevelopmentBuildBody.
  ///
  /// In en, this message translates to:
  /// **'Uninstall is available from the installed macOS app, not a development build.'**
  String get uninstallDevelopmentBuildBody;

  /// No description provided for @uninstallUnavailableBody.
  ///
  /// In en, this message translates to:
  /// **'Uninstall is unavailable. Reinstall Roammand before trying again.'**
  String get uninstallUnavailableBody;

  /// No description provided for @uninstallCheckingBody.
  ///
  /// In en, this message translates to:
  /// **'Preparing to uninstall…'**
  String get uninstallCheckingBody;

  /// No description provided for @uninstallConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Uninstall Roammand?'**
  String get uninstallConfirmTitle;

  /// No description provided for @uninstallConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Remote connections will stop. Roammand and all of its background services will be removed from this Mac.'**
  String get uninstallConfirmBody;

  /// No description provided for @uninstallDeleteDataNotice.
  ///
  /// In en, this message translates to:
  /// **'Device identity, pairing records, preferences, caches, and Roammand’s Screen Recording and Accessibility permissions will also be deleted. This cannot be undone.'**
  String get uninstallDeleteDataNotice;

  /// No description provided for @uninstallConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Uninstall'**
  String get uninstallConfirmAction;

  /// No description provided for @uninstallFailed.
  ///
  /// In en, this message translates to:
  /// **'Roammand could not be uninstalled. No personal data was removed.'**
  String get uninstallFailed;

  /// No description provided for @desktopControlTitle.
  ///
  /// In en, this message translates to:
  /// **'Control a computer'**
  String get desktopControlTitle;

  /// No description provided for @desktopControlBody.
  ///
  /// In en, this message translates to:
  /// **'Paste the connection information shown on the other computer to start controlling it.'**
  String get desktopControlBody;

  /// No description provided for @hostConnectionDescriptorLabel.
  ///
  /// In en, this message translates to:
  /// **'Computer connection information'**
  String get hostConnectionDescriptorLabel;

  /// No description provided for @hostConnectionDescriptorHint.
  ///
  /// In en, this message translates to:
  /// **'Paste the other computer\'s connection information here'**
  String get hostConnectionDescriptorHint;

  /// No description provided for @hostConnectionDescriptorPrivacy.
  ///
  /// In en, this message translates to:
  /// **'This contains only public information needed to connect. It does not contain passwords or other secrets.'**
  String get hostConnectionDescriptorPrivacy;

  /// No description provided for @invalidHostDescriptor.
  ///
  /// In en, this message translates to:
  /// **'Connection information is invalid.'**
  String get invalidHostDescriptor;

  /// No description provided for @connectAction.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connectAction;

  /// No description provided for @connectingAction.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get connectingAction;

  /// No description provided for @remoteDesktopTitle.
  ///
  /// In en, this message translates to:
  /// **'Remote desktop — {hostName}'**
  String remoteDesktopTitle(String hostName);

  /// No description provided for @closeSessionAction.
  ///
  /// In en, this message translates to:
  /// **'Close connection'**
  String get closeSessionAction;

  /// No description provided for @remoteInputHint.
  ///
  /// In en, this message translates to:
  /// **'Click the desktop to send mouse and keyboard input.'**
  String get remoteInputHint;

  /// No description provided for @localExitShortcutHint.
  ///
  /// In en, this message translates to:
  /// **'Local exit: Ctrl+Alt+Shift+Esc'**
  String get localExitShortcutHint;

  /// No description provided for @remoteIdle.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get remoteIdle;

  /// No description provided for @remoteConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to the other computer…'**
  String get remoteConnecting;

  /// No description provided for @remoteReconnectingPending.
  ///
  /// In en, this message translates to:
  /// **'Connection interrupted. Preparing a secure retry…'**
  String get remoteReconnectingPending;

  /// No description provided for @remoteReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting… attempt {attempt} of {maximum}. {seconds} seconds remaining.'**
  String remoteReconnecting(int attempt, int maximum, int seconds);

  /// No description provided for @remoteAuthenticating.
  ///
  /// In en, this message translates to:
  /// **'Checking both devices…'**
  String get remoteAuthenticating;

  /// No description provided for @remoteNegotiating.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the other computer to respond…'**
  String get remoteNegotiating;

  /// No description provided for @remoteConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get remoteConnected;

  /// No description provided for @remoteClosing.
  ///
  /// In en, this message translates to:
  /// **'Closing and releasing input…'**
  String get remoteClosing;

  /// No description provided for @remoteAuthenticationFailed.
  ///
  /// In en, this message translates to:
  /// **'Roammand could not safely confirm this is your paired computer.'**
  String get remoteAuthenticationFailed;

  /// No description provided for @remoteHostAgentFailed.
  ///
  /// In en, this message translates to:
  /// **'The other computer\'s remote-control service is unavailable.'**
  String get remoteHostAgentFailed;

  /// No description provided for @remoteLocalIdentityFailed.
  ///
  /// In en, this message translates to:
  /// **'Roammand could not read this device\'s secure pairing information.'**
  String get remoteLocalIdentityFailed;

  /// No description provided for @remoteSignalingFailed.
  ///
  /// In en, this message translates to:
  /// **'Roammand could not reach the connection service.'**
  String get remoteSignalingFailed;

  /// No description provided for @remoteConfigurationFailed.
  ///
  /// In en, this message translates to:
  /// **'Remote connection settings are invalid.'**
  String get remoteConfigurationFailed;

  /// No description provided for @remoteConnectionFailed.
  ///
  /// In en, this message translates to:
  /// **'The remote connection failed.'**
  String get remoteConnectionFailed;

  /// No description provided for @retryRemoteAction.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get retryRemoteAction;

  /// No description provided for @diagnosticsAction.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get diagnosticsAction;

  /// No description provided for @diagnosticsTitle.
  ///
  /// In en, this message translates to:
  /// **'Privacy-protected diagnostics'**
  String get diagnosticsTitle;

  /// No description provided for @diagnosticsPreviewBody.
  ///
  /// In en, this message translates to:
  /// **'If a connection fails, save this local report to review connection steps, timing, and overall network quality. You can see what is included before saving. Nothing is uploaded or copied to the clipboard.'**
  String get diagnosticsPreviewBody;

  /// No description provided for @diagnosticsIncludedTitle.
  ///
  /// In en, this message translates to:
  /// **'Included'**
  String get diagnosticsIncludedTitle;

  /// No description provided for @diagnosticsExcludedTitle.
  ///
  /// In en, this message translates to:
  /// **'Excluded'**
  String get diagnosticsExcludedTitle;

  /// No description provided for @diagnosticsIncludedVersions.
  ///
  /// In en, this message translates to:
  /// **'Roammand and operating system versions'**
  String get diagnosticsIncludedVersions;

  /// No description provided for @diagnosticsIncludedSession.
  ///
  /// In en, this message translates to:
  /// **'Connection steps and safe error codes'**
  String get diagnosticsIncludedSession;

  /// No description provided for @diagnosticsIncludedReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect attempts and timing'**
  String get diagnosticsIncludedReconnect;

  /// No description provided for @diagnosticsIncludedWebRtc.
  ///
  /// In en, this message translates to:
  /// **'Overall connection-quality measurements'**
  String get diagnosticsIncludedWebRtc;

  /// No description provided for @diagnosticsExcludedDeviceIdentifiers.
  ///
  /// In en, this message translates to:
  /// **'Information that can identify a device'**
  String get diagnosticsExcludedDeviceIdentifiers;

  /// No description provided for @diagnosticsExcludedDeviceNames.
  ///
  /// In en, this message translates to:
  /// **'Device names'**
  String get diagnosticsExcludedDeviceNames;

  /// No description provided for @diagnosticsExcludedKeys.
  ///
  /// In en, this message translates to:
  /// **'Keys and signatures'**
  String get diagnosticsExcludedKeys;

  /// No description provided for @diagnosticsExcludedTokens.
  ///
  /// In en, this message translates to:
  /// **'Login details, passwords, and other secrets'**
  String get diagnosticsExcludedTokens;

  /// No description provided for @diagnosticsExcludedSdpIce.
  ///
  /// In en, this message translates to:
  /// **'Detailed networking information'**
  String get diagnosticsExcludedSdpIce;

  /// No description provided for @diagnosticsExcludedNetworkAddresses.
  ///
  /// In en, this message translates to:
  /// **'IP addresses and ports'**
  String get diagnosticsExcludedNetworkAddresses;

  /// No description provided for @diagnosticsExcludedInput.
  ///
  /// In en, this message translates to:
  /// **'Input content and coordinates'**
  String get diagnosticsExcludedInput;

  /// No description provided for @diagnosticsExcludedScreen.
  ///
  /// In en, this message translates to:
  /// **'Screen content'**
  String get diagnosticsExcludedScreen;

  /// No description provided for @diagnosticsExcludedRawPayloads.
  ///
  /// In en, this message translates to:
  /// **'Unprocessed communication content'**
  String get diagnosticsExcludedRawPayloads;

  /// No description provided for @diagnosticsExcludedRawStats.
  ///
  /// In en, this message translates to:
  /// **'Unprocessed connection data'**
  String get diagnosticsExcludedRawStats;

  /// No description provided for @diagnosticsEventSummary.
  ///
  /// In en, this message translates to:
  /// **'Captured events: {count}. Truncated: {truncated}.'**
  String diagnosticsEventSummary(int count, String truncated);

  /// No description provided for @diagnosticsTruncatedYes.
  ///
  /// In en, this message translates to:
  /// **'yes'**
  String get diagnosticsTruncatedYes;

  /// No description provided for @diagnosticsTruncatedNo.
  ///
  /// In en, this message translates to:
  /// **'no'**
  String get diagnosticsTruncatedNo;

  /// No description provided for @diagnosticsSaveAction.
  ///
  /// In en, this message translates to:
  /// **'Save report'**
  String get diagnosticsSaveAction;

  /// No description provided for @diagnosticsSavingAction.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get diagnosticsSavingAction;

  /// No description provided for @diagnosticsSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved locally to {path}'**
  String diagnosticsSaved(String path);

  /// No description provided for @diagnosticsSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to save the diagnostics report.'**
  String get diagnosticsSaveFailed;

  /// No description provided for @networkSettingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Connection settings'**
  String get networkSettingsTooltip;

  /// No description provided for @networkSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection service'**
  String get networkSettingsTitle;

  /// No description provided for @networkSettingsBody.
  ///
  /// In en, this message translates to:
  /// **'Roammand\'s official service is recommended. Custom addresses are intended for advanced users and self-hosted setups.'**
  String get networkSettingsBody;

  /// No description provided for @networkProfileLabel.
  ///
  /// In en, this message translates to:
  /// **'Choose a service'**
  String get networkProfileLabel;

  /// No description provided for @networkOfficialProfile.
  ///
  /// In en, this message translates to:
  /// **'Official service'**
  String get networkOfficialProfile;

  /// No description provided for @networkOfficialProfileBody.
  ///
  /// In en, this message translates to:
  /// **'Recommended. Roammand configures the required addresses for you.'**
  String get networkOfficialProfileBody;

  /// No description provided for @networkCustomProfile.
  ///
  /// In en, this message translates to:
  /// **'Custom service'**
  String get networkCustomProfile;

  /// No description provided for @networkCustomProfileBody.
  ///
  /// In en, this message translates to:
  /// **'For advanced users who run their own signaling and STUN services.'**
  String get networkCustomProfileBody;

  /// No description provided for @networkSignalingEndpointLabel.
  ///
  /// In en, this message translates to:
  /// **'Signaling WebSocket address'**
  String get networkSignalingEndpointLabel;

  /// No description provided for @networkSignalingEndpointHint.
  ///
  /// In en, this message translates to:
  /// **'wss://signal.example.com/v1/connect'**
  String get networkSignalingEndpointHint;

  /// No description provided for @networkStunUrlsLabel.
  ///
  /// In en, this message translates to:
  /// **'STUN addresses'**
  String get networkStunUrlsLabel;

  /// No description provided for @networkStunUrlsHint.
  ///
  /// In en, this message translates to:
  /// **'One stun: or stuns: address per line'**
  String get networkStunUrlsHint;

  /// No description provided for @networkStunOptionalNotice.
  ///
  /// In en, this message translates to:
  /// **'STUN is optional for local testing. This release has no TURN fallback, so some restrictive networks cannot connect.'**
  String get networkStunOptionalNotice;

  /// No description provided for @networkMobileHostBindingNotice.
  ///
  /// In en, this message translates to:
  /// **'This device continues using the service address from its pairing QR code. These settings apply to computer-to-computer connections and become the default for future pairing.'**
  String get networkMobileHostBindingNotice;

  /// No description provided for @networkSaveAction.
  ///
  /// In en, this message translates to:
  /// **'Save settings'**
  String get networkSaveAction;

  /// No description provided for @networkSavingAction.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get networkSavingAction;

  /// No description provided for @networkRestoreAction.
  ///
  /// In en, this message translates to:
  /// **'Restore official settings'**
  String get networkRestoreAction;

  /// No description provided for @networkInvalidSignaling.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid secure signaling WebSocket address. Private ws:// addresses are allowed only in an explicitly enabled debug build.'**
  String get networkInvalidSignaling;

  /// No description provided for @networkInvalidStun.
  ///
  /// In en, this message translates to:
  /// **'Enter only valid stun: or stuns: addresses, one per line.'**
  String get networkInvalidStun;

  /// No description provided for @networkInvalidConfiguration.
  ///
  /// In en, this message translates to:
  /// **'The signaling or STUN configuration is invalid.'**
  String get networkInvalidConfiguration;

  /// No description provided for @networkSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'The connection settings could not be saved.'**
  String get networkSaveFailed;

  /// No description provided for @networkChangeHostTitle.
  ///
  /// In en, this message translates to:
  /// **'Change this computer\'s network service?'**
  String get networkChangeHostTitle;

  /// No description provided for @networkChangeHostBody.
  ///
  /// In en, this message translates to:
  /// **'Roammand\'s background service will restart and current remote connections will close. If the service address changes, previously paired devices must pair again.'**
  String get networkChangeHostBody;

  /// No description provided for @networkConfirmChangeAction.
  ///
  /// In en, this message translates to:
  /// **'Save and restart'**
  String get networkConfirmChangeAction;

  /// No description provided for @networkConfigurationSaved.
  ///
  /// In en, this message translates to:
  /// **'Connection settings saved.'**
  String get networkConfigurationSaved;

  /// No description provided for @networkHostMigrationSaved.
  ///
  /// In en, this message translates to:
  /// **'Server changed. Show a new QR code to previously paired devices.'**
  String get networkHostMigrationSaved;

  /// No description provided for @networkExternalHostRestartRequired.
  ///
  /// In en, this message translates to:
  /// **'Settings saved. A separately started developer service is running; restart it manually with the same settings.'**
  String get networkExternalHostRestartRequired;

  /// No description provided for @networkHostRestartFailed.
  ///
  /// In en, this message translates to:
  /// **'Settings saved, but Roammand\'s background service could not restart. Exit and reopen Roammand, then check Connection settings.'**
  String get networkHostRestartFailed;

  /// No description provided for @mobileUnfamiliarServerTitle.
  ///
  /// In en, this message translates to:
  /// **'Use a different connection service?'**
  String get mobileUnfamiliarServerTitle;

  /// No description provided for @mobileUnfamiliarServerBody.
  ///
  /// In en, this message translates to:
  /// **'This QR code uses {endpoint}. The service may see basic connection information or interrupt connections. Continue only if you trust the computer and the service provider.'**
  String mobileUnfamiliarServerBody(String endpoint);

  /// No description provided for @mobileTrustServerAction.
  ///
  /// In en, this message translates to:
  /// **'Trust and continue'**
  String get mobileTrustServerAction;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
