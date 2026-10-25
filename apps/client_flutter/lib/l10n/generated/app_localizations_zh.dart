// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'Roammand';

  @override
  String get brandTagline => '离开桌面，工作仍在继续。';

  @override
  String get brandPrivacyLabel => '隐私优先 · 无需账号';

  @override
  String get mobileHomeSubtitle => '使用这台设备，安全控制你自己的 Mac。';

  @override
  String get desktopHomeSubtitle => '选择一台已配对的电脑，安全地开始连接。';

  @override
  String get mobileIdentitySecurityNote => '无需注册账号；配对信息只保存在这台设备上。';

  @override
  String get computerReadyLabel => '可以连接';

  @override
  String get developmentStatus => '远程控制功能尚未开放。';

  @override
  String get desktopHostTitle => '这台 Mac';

  @override
  String get hostAgentConnectingTitle => '正在准备这台 Mac…';

  @override
  String get hostAgentConnectingBody => '正在检查这台 Mac 是否可以接收远程连接。';

  @override
  String get hostAgentOfflineTitle => 'Roammand 后台服务未运行';

  @override
  String get hostAgentOfflineBody => '请重试。如果仍然无法启动，请重新安装 Roammand。';

  @override
  String get hostAgentProtectedSessionUnavailableTitle => '锁屏控制暂不可用';

  @override
  String get hostAgentProtectedSessionUnavailableBody =>
      'Roammand 无法启动锁屏和登录界面所需的服务。请重试或重新安装 Roammand。';

  @override
  String get hostAgentPrivilegedBridgeUnavailableTitle => '远程控制暂不可用';

  @override
  String get hostAgentPrivilegedBridgeUnavailableBody =>
      'Roammand 无法连接必要的 macOS 后台功能。请重新安装 Roammand，然后重试。';

  @override
  String get hostAgentComponentMissingTitle => 'Roammand 安装不完整';

  @override
  String get hostAgentComponentMissingBody =>
      '缺少远程控制需要的文件。请重新安装 Roammand，然后重试。';

  @override
  String get hostAgentLaunchFailedTitle => 'Roammand 后台服务无法启动';

  @override
  String get hostAgentLaunchFailedBody =>
      'macOS 无法打开远程控制需要的后台功能。请重新安装 Roammand，然后重试。';

  @override
  String get hostAgentConfigurationInvalidTitle => '连接设置需要检查';

  @override
  String get hostAgentConfigurationInvalidBody => '请打开“连接”设置，检查服务地址后重试。';

  @override
  String get hostAgentUnexpectedExitTitle => 'Roammand 后台服务已停止';

  @override
  String get hostAgentUnexpectedExitBody => '请重试。如果后台服务反复停止，请重新安装 Roammand。';

  @override
  String get hostAgentErrorTitle => '暂时无法读取这台 Mac 的状态';

  @override
  String get hostAgentErrorBody => '请稍等片刻后重试。';

  @override
  String get retryAction => '重试';

  @override
  String get refreshAction => '刷新';

  @override
  String get privilegedBridgeSectionTitle => '远程控制状态';

  @override
  String get privilegedBridgeNotInstalledTitle => '安装尚未完成';

  @override
  String get privilegedBridgeNotInstalledBody =>
      '请重新安装 Roammand，以便在桌面、锁屏和登录界面使用远程控制。';

  @override
  String get privilegedBridgeApprovalRequiredTitle => '需要管理员确认';

  @override
  String get privilegedBridgeApprovalRequiredBody =>
      'macOS 弹出提示时，请允许 Roammand 运行后台服务。';

  @override
  String get privilegedBridgePermissionRequiredTitle => '需要开启 macOS 权限';

  @override
  String get privilegedBridgePermissionRequiredBody =>
      '请在“系统设置”中为 Roammand 开启“屏幕录制”和“辅助功能”。';

  @override
  String get macOsHostPermissionsTitle => '完成 Mac 权限设置';

  @override
  String get macOsHostPermissionsBody =>
      '开启“屏幕录制”和“辅助功能”之前，其他设备无法连接这台 Mac。请先在这里逐项完成授权。';

  @override
  String get macOsHostPermissionsUnavailable =>
      'Roammand 无法检查已安装 Host 的权限。请确认 Host Agent 已安装，然后重试。';

  @override
  String get macOsScreenRecordingPermission => '屏幕录制';

  @override
  String get macOsAccessibilityPermission => '辅助功能';

  @override
  String get macOsPermissionGranted => '已允许';

  @override
  String get macOsPermissionNotGranted => '未允许';

  @override
  String get macOsPermissionSetUpAction => '去设置';

  @override
  String get privilegedBridgeUserSessionOnlyTitle => '仅在这台 Mac 解锁后可用';

  @override
  String get privilegedBridgeUserSessionOnlyBody => '现在可以控制桌面，但无法控制锁屏和登录界面。';

  @override
  String get privilegedBridgeReadyNormalTitle => '这台 Mac 已准备好';

  @override
  String get privilegedBridgeReadyNormalBody => '已允许的设备现在可以连接这台 Mac。';

  @override
  String get privilegedBridgeReadyLockedTitle => '锁屏时也可以连接';

  @override
  String get privilegedBridgeReadyLockedBody => '这台 Mac 锁屏或显示登录界面时，已允许的设备仍可连接。';

  @override
  String get privilegedBridgeReadySecureTitle => '系统界面也可以控制';

  @override
  String get privilegedBridgeReadySecureBody =>
      '显示锁屏、登录界面等 macOS 系统画面时，远程控制仍可继续。';

  @override
  String get privilegedBridgeReadyUnavailableTitle => '正在等待桌面可用';

  @override
  String get privilegedBridgeReadyUnavailableBody =>
      '当前没有可以控制的桌面；macOS 准备好后会自动恢复。';

  @override
  String get privilegedBridgeTransitioningTitle => '正在切换界面…';

  @override
  String get privilegedBridgeTransitioningBody => 'macOS 切换界面时，远程输入会短暂停止。';

  @override
  String get privilegedBridgeReconnectingTitle => '正在恢复远程控制…';

  @override
  String get privilegedBridgeReconnectingBody => '重新确认连接安全之前，远程输入会保持暂停。';

  @override
  String privilegedBridgeControlledTitle(String controllerName) {
    return '“$controllerName”正在控制';
  }

  @override
  String get privilegedBridgeControlledUnknownTitle => '远程控制正在进行';

  @override
  String get privilegedBridgeControlledBody => '点击下方的“紧急停止”，可立即结束所有远程连接。';

  @override
  String get privilegedBridgeFailedTitle => '远程控制服务不可用';

  @override
  String get privilegedBridgeFailedBody =>
      '请检查 Roammand 的 macOS 权限；如果权限已经开启，请重新安装 Roammand。';

  @override
  String get privilegedBridgeUnknownTitle => '暂时无法确认远程控制状态';

  @override
  String get privilegedBridgeUnknownBody => '请刷新页面；如果状态仍未恢复，请重新打开 Roammand。';

  @override
  String get emergencyStopAction => '紧急停止';

  @override
  String get emergencyStoppingAction => '正在停止…';

  @override
  String get emergencyStopDialogTitle => '停止远程控制？';

  @override
  String get emergencyStopDialogBody =>
      '这会立即断开所有远程连接，并停止对方的鼠标和键盘操作；已允许的设备列表会保留。';

  @override
  String get confirmEmergencyStopAction => '立即停止';

  @override
  String get emergencyStopSucceeded => '远程控制已停止。';

  @override
  String get emergencyStopFailed => '无法停止远程控制。请从顶部菜单栏退出 Roammand，然后重新打开。';

  @override
  String get trayExitAction => '退出 Roammand';

  @override
  String get trayExitControlledTitle => '远程控制进行中，仍要退出？';

  @override
  String get trayExitControlledBody => '退出前会先断开所有远程连接，并停止对方的鼠标和键盘操作。';

  @override
  String get trayConfirmExitAction => '停止并退出';

  @override
  String get hostIdentitySectionTitle => '此电脑';

  @override
  String hostShortFingerprint(String fingerprint) {
    return '安全校验码：$fingerprint';
  }

  @override
  String get authorizedControllersSectionTitle => '已允许的设备';

  @override
  String authorizedControllerCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已允许 $count 台设备',
      zero: '没有已允许的设备',
    );
    return '$_temp0';
  }

  @override
  String get noAuthorizedControllers => '还没有设备可以控制这台 Mac。';

  @override
  String get unknownControllerName => '未知设备';

  @override
  String grantCreatedLabel(String date) {
    return '允许时间：$date';
  }

  @override
  String grantLastConnectedLabel(String date) {
    return '最近连接：$date';
  }

  @override
  String get neverConnected => '从未连接';

  @override
  String get unknownDate => '未知';

  @override
  String get revokeAction => '移除权限';

  @override
  String revokeDialogTitle(String controllerName) {
    return '不再允许“$controllerName”控制？';
  }

  @override
  String get revokeDialogBody => '此设备会立即失去对这台 Mac 的访问权限。以后如需连接，必须重新配对。';

  @override
  String get cancelAction => '取消';

  @override
  String get confirmRevokeAction => '移除权限';

  @override
  String get revokingAction => '正在移除…';

  @override
  String get hostPairingSectionTitle => '添加新设备';

  @override
  String get hostPairingSectionBody =>
      '手机使用二维码，另一台电脑使用一次性配对码。设备获得访问权限前，需要你在这里确认。';

  @override
  String get hostPairingEndpointMissing => '请先打开“连接”设置并选择连接服务，然后再配对。';

  @override
  String get hostPairingStartQrAction => '显示手机二维码';

  @override
  String get hostPairingStartCodeAction => '生成电脑配对码';

  @override
  String get hostPairingViewActiveAction => '查看当前配对';

  @override
  String get hostPairingQrTitle => '配对手机';

  @override
  String get hostPairingCodeTitle => '配对电脑';

  @override
  String get hostPairingQrInstructions => '请使用 Roammand 的相机扫码器扫描此二维码。';

  @override
  String get hostPairingCodeInstructions => '请在另一台电脑上输入此一次性配对码。';

  @override
  String get hostPairingQrSemantics => '手机配对二维码';

  @override
  String hostPairingExpiresIn(String remaining) {
    return '剩余 $remaining';
  }

  @override
  String get hostPairingCreating => '正在准备安全配对码…';

  @override
  String get hostPairingWaitingController => '正在等待另一台设备…';

  @override
  String get hostPairingVerifyingController => '正在检查另一台设备…';

  @override
  String get hostPairingPendingControllerTitle => '请求访问的设备';

  @override
  String deviceFingerprintLabel(String fingerprint) {
    return '设备指纹：$fingerprint';
  }

  @override
  String get hostPairingCompareSas => '核对这四个单词';

  @override
  String get hostPairingSasInstructions => '请确认两台电脑显示的四个单词完全相同；任一单词不同都应拒绝请求。';

  @override
  String get hostPairingOneWayGrant =>
      '允许后，这台设备以后无需再次确认，就能查看和操作这台 Mac；这不会让这台 Mac 反过来控制对方。';

  @override
  String get hostPairingAllowAction => '允许控制';

  @override
  String get hostPairingRejectAction => '拒绝';

  @override
  String get hostPairingCancelAction => '取消配对';

  @override
  String get hostPairingActionPending => '正在处理…';

  @override
  String get hostPairingAccepted => '已允许此设备';

  @override
  String get hostPairingRejected => '已拒绝此设备';

  @override
  String get hostPairingExpired => '配对已过期';

  @override
  String get hostPairingCancelled => '配对已取消';

  @override
  String get hostPairingFailed => '配对失败';

  @override
  String get closeAction => '关闭';

  @override
  String get devicePlatformIos => 'iPhone 或 iPad';

  @override
  String get devicePlatformAndroid => 'Android 设备';

  @override
  String get devicePlatformMacos => 'Mac';

  @override
  String get devicePlatformWindows => 'Windows 电脑';

  @override
  String get devicePlatformUnknown => '未知平台';

  @override
  String get trustedComputersTitle => '我的电脑';

  @override
  String get trustedComputersEmptyTitle => '尚未配对电脑';

  @override
  String get trustedComputersEmptyBody =>
      '在想要控制的电脑上打开 Roammand，然后在这里输入它的一次性配对码。';

  @override
  String get pairComputerAction => '配对电脑';

  @override
  String get trustedComputersLoadFailed => '无法读取已保存的电脑。';

  @override
  String get desktopPairingDialogTitle => '配对电脑';

  @override
  String get desktopPairingCodeLabel => '一次性配对码';

  @override
  String get desktopPairingCodeHint => 'ABCD-EFGH';

  @override
  String get invalidDesktopPairingCode => '配对码无效。';

  @override
  String get pairAction => '配对';

  @override
  String get desktopPairingConnecting => '正在连接这台电脑…';

  @override
  String get desktopPairingVerifying => '正在确认是否为正确的电脑…';

  @override
  String get desktopPairingWaitingApproval => '正在等待另一台电脑确认…';

  @override
  String get desktopPairingSuccess => '电脑已配对';

  @override
  String get desktopPairingRejected => '另一台电脑已拒绝配对';

  @override
  String get desktopPairingExpired => '配对已过期';

  @override
  String get desktopPairingFailed => '配对失败';

  @override
  String trustedHostPairedLabel(String date) {
    return '配对时间：$date';
  }

  @override
  String trustedHostLastConnectedLabel(String date) {
    return '最近连接：$date';
  }

  @override
  String get openRemoteAction => '连接';

  @override
  String get renameTrustedHostAction => '重命名';

  @override
  String get renameTrustedHostTitle => '重命名电脑';

  @override
  String get trustedHostNameLabel => '电脑名称';

  @override
  String get trustedHostNameInvalid => '请输入有效的电脑名称。';

  @override
  String get renameTrustedHostSaveAction => '保存名称';

  @override
  String get renameTrustedHostFailed => '无法保存电脑名称。';

  @override
  String get deleteTrustedHostAction => '删除';

  @override
  String deleteTrustedHostTitle(String hostName) {
    return '从本机删除“$hostName”？';
  }

  @override
  String get deleteTrustedHostBody =>
      '这会从当前设备的列表中移除该电脑。若要彻底取消访问权限，还需要在对方电脑上撤销当前设备。';

  @override
  String get confirmDeleteAction => '仅在本机删除';

  @override
  String get deleteTrustedHostFailed => '无法从当前设备删除这台电脑。';

  @override
  String get mobileDeviceFallbackName => '我的设备';

  @override
  String get mobileOnboardingTitle => '用这台设备控制你的 Mac';

  @override
  String get mobileOnboardingBody =>
      'Roammand 需要同时安装在两台设备上。请先在要控制的 Mac 上安装，然后为这台设备设置名称，以便批准配对时认出它。';

  @override
  String get mobileDeviceNameLabel => '设备名称';

  @override
  String get mobileConfirmIdentityAction => '继续';

  @override
  String get mobileIdentityLoading => '正在读取本机配对信息…';

  @override
  String get mobileIdentityFailed => '无法读取本机的安全配对信息。';

  @override
  String get mobileHomeTitle => '我的电脑';

  @override
  String get mobileHomeEmptyTitle => '请先在 Mac 上开始';

  @override
  String get mobileHomeEmptyBody =>
      '这台设备是控制端。请先在要控制的 Mac 上设置 Roammand，并从 Mac 端生成配对二维码。';

  @override
  String get mobileSetupStepInstall => '在要控制的 Mac 上安装并打开 Roammand。';

  @override
  String get mobileSetupStepCreateQr => '在 Mac 上打开“此电脑”，创建移动设备配对二维码。';

  @override
  String get mobileSetupStepScanApprove => '在这里扫码、核对验证词，然后在 Mac 上批准这台设备。';

  @override
  String get mobileMacDownloadAction => '获取 Roammand Mac 版';

  @override
  String get mobileAboutAction => '了解 Roammand 如何工作';

  @override
  String get mobileScanQrAction => '扫描电脑二维码';

  @override
  String get mobileScannerTitle => '扫描二维码';

  @override
  String get mobileScannerInstructions => '请将相机对准电脑上显示的配对二维码。';

  @override
  String get mobileScannerTorchAction => '开关手电筒';

  @override
  String get mobileScannerSwitchCameraAction => '切换摄像头';

  @override
  String get mobileScannerPermissionDenied => '相机权限已被拒绝。请在系统设置中允许相机权限后再扫码。';

  @override
  String get mobileScannerRestricted => '此设备上的相机访问受到限制。';

  @override
  String get mobileScannerNoCamera => '没有可用的相机。';

  @override
  String get mobileScannerInitializationFailed => '无法启动相机。';

  @override
  String get mobileInvalidQr => '此配对二维码无效或已过期，请扫描新二维码。';

  @override
  String get mobilePairingJoining => '正在连接这台电脑…';

  @override
  String get mobilePairingVerifying => '正在确认是否为正确的电脑…';

  @override
  String get mobilePairingWaitingApproval => '正在等待电脑批准…';

  @override
  String get mobilePairingSuccess => '电脑已配对';

  @override
  String get mobilePairingRejected => '电脑已拒绝配对';

  @override
  String get mobilePairingExpired => '配对已过期';

  @override
  String get mobilePairingCancelled => '配对已取消';

  @override
  String get mobilePairingFailed => '配对失败';

  @override
  String get mobilePairingSignalingFailed => '无法连接配对服务。请检查连接设置和本地网络权限。';

  @override
  String get mobilePairingAuthenticationFailed => '无法安全确认这台电脑。请重新生成二维码后再试。';

  @override
  String get mobilePairingPersistenceFailed => '配对已获批准，但无法安全保存这台电脑。';

  @override
  String get mobilePairingInternalFailed => '配对遇到内部错误，请重试。';

  @override
  String pairingSecondsRemaining(int seconds) {
    return '剩余 $seconds 秒';
  }

  @override
  String get mobileControlLaterNotice => '已配对，可以开始安全连接。';

  @override
  String get mobileGestureHint => '轻点、双击、拖动、滚动或双指缩放';

  @override
  String get mobileKeyboardAction => '键盘';

  @override
  String get mobileHideKeyboardAction => '隐藏键盘';

  @override
  String get mobileLockControlsAction => '锁定控制栏';

  @override
  String get mobileUnlockControlsAction => '解锁控制栏';

  @override
  String get mobileTextInputLabel => '发送文字到电脑';

  @override
  String get mobileSendTextAction => '发送文字';

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
  String get mobileKeyArrowLeft => '左';

  @override
  String get mobileKeyArrowUp => '上';

  @override
  String get mobileKeyArrowRight => '右';

  @override
  String get mobileKeyArrowDown => '下';

  @override
  String get remoteControlTab => '远程控制';

  @override
  String get thisComputerTab => '此电脑';

  @override
  String get languageMenuTooltip => '切换语言';

  @override
  String get languageSystemOption => '跟随系统';

  @override
  String get languageEnglishOption => 'English';

  @override
  String get languageSimplifiedChineseOption => '简体中文';

  @override
  String get settingsTooltip => '设置';

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsGeneralSection => '常规';

  @override
  String get settingsConnectionSection => '连接';

  @override
  String get settingsAdvancedSection => '高级';

  @override
  String get settingsHelpSection => '关于与帮助';

  @override
  String get aboutSettingsTitle => '关于 Roammand';

  @override
  String get aboutSettingsBody => '查看 Mac 设置、用户指南、开源项目和 App 版本。';

  @override
  String get desktopAboutSettingsBody =>
      '设置这台 Mac、构建 iPhone 或 iPad App，并查看用户指南和开源项目。';

  @override
  String get aboutPageTitle => '关于 Roammand';

  @override
  String get aboutHeroTitle => '随时连接你的 Mac';

  @override
  String get aboutHeroBody =>
      'Roammand 将这台设备变成控制你自己 Mac 的可信控制端。移动端 App 需要与安装在 Mac 上的 Roammand 配合使用。';

  @override
  String get desktopAboutHeroTitle => '让这台 Mac 随时可达';

  @override
  String get desktopAboutHeroBody =>
      'Roammand 让你批准的设备安全查看和控制这台 Mac；你也可以从“远程控制”连接另一台已配对的电脑。';

  @override
  String get aboutGettingStartedTitle => '如何开始';

  @override
  String get aboutGettingStartedBody => '两台设备只需完成一次配对，以后可以随时从“我的电脑”重新连接。';

  @override
  String get desktopAboutGettingStartedBody =>
      '先完成一次 Mac 设置，再与手机配对。以后的连接将使用你在这台 Mac 上批准的权限。';

  @override
  String get desktopSetupStepPermissions =>
      '在 macOS 系统设置中允许 Roammand 使用屏幕录制和辅助功能。';

  @override
  String get desktopSetupStepCreateQr => '打开“此电脑”，选择“显示手机二维码”。';

  @override
  String get desktopSetupStepScanApprove =>
      '用 iPhone 或 iPad 上的 Roammand 扫码，确认设备信息，然后在这台 Mac 上批准该设备。';

  @override
  String get aboutMacAppTitle => 'Roammand Mac 版';

  @override
  String get aboutMacAppBody =>
      '请在 macOS 14.4 或更高版本上安装经过 Developer ID 签名的 Mac App。1.1.0 未经 Apple 公证，Gatekeeper 可能会阻止打开。Mac 端负责提供画面，并且只接受你批准过的设备进行远程控制。';

  @override
  String get aboutMacDownloadNote => '请在 Mac 上打开下载页面，或从这台设备将链接分享给 Mac。';

  @override
  String get aboutIosAppTitle => 'Roammand iPhone 与 iPad 版';

  @override
  String get aboutIosAppBody =>
      '移动控制端目前以源码形式提供。请为要用作控制端的 iPhone 或 iPad 构建 App，再扫描二维码与这台 Mac 配对。';

  @override
  String get aboutIosBuildAction => '查看 iOS 构建指南';

  @override
  String get aboutIosAvailabilityNote => '当前尚未提供公开的 App Store 下载。';

  @override
  String get aboutHelpTitle => '用户指南';

  @override
  String get aboutHelpBody => '查看安装、系统权限、配对、连接和故障排查的完整说明。';

  @override
  String get aboutOpenGuideAction => '阅读用户指南';

  @override
  String get aboutOpenSourceTitle => 'GitHub 开源项目';

  @override
  String get aboutOpenSourceBody => '你可以在 GitHub 查看源代码、历史版本、安全设计和项目文档。';

  @override
  String get aboutOpenGitHubAction => '查看 GitHub 项目';

  @override
  String get aboutPrivacyTitle => '隐私优先';

  @override
  String get aboutPrivacyBody =>
      '无需注册账号。设备身份和配对权限保存在本机，并且必须先在 Mac 上批准这台设备，才能建立连接。';

  @override
  String get aboutOpenPrivacyPolicyAction => '阅读隐私政策';

  @override
  String get desktopAboutPrivacyBody =>
      '无需注册账号。设备身份和配对权限保存在这台 Mac 上；只有你批准的设备才能连接，并且你可以随时撤销权限或停止当前连接。';

  @override
  String aboutVersionLabel(String version) {
    return '版本 $version';
  }

  @override
  String get externalLinkFailed => '无法打开链接，请稍后重试。';

  @override
  String get settingsLanguageTitle => '语言';

  @override
  String get settingsLanguageBody => '选择 Roammand 使用的显示语言。';

  @override
  String get uninstallSettingsTitle => '卸载 Roammand';

  @override
  String get uninstallSettingsBody => '从这台 Mac 完整移除应用、后台组件、本地数据和系统授权。';

  @override
  String get uninstallDevelopmentBuildBody => '卸载仅可从已安装的 macOS 应用执行，开发构建不可使用。';

  @override
  String get uninstallUnavailableBody => '卸载功能不可用，请先重新安装 Roammand。';

  @override
  String get uninstallCheckingBody => '正在准备卸载…';

  @override
  String get uninstallConfirmTitle => '卸载 Roammand？';

  @override
  String get uninstallConfirmBody => '所有远程连接都会停止；Roammand 及其后台服务将从这台 Mac 移除。';

  @override
  String get uninstallDeleteDataNotice =>
      '设备身份、配对记录、偏好设置、缓存，以及 Roammand 的屏幕录制和辅助功能授权也会被删除，且无法恢复。';

  @override
  String get uninstallConfirmAction => '卸载';

  @override
  String get uninstallFailed => '无法卸载 Roammand；未删除任何个人数据。';

  @override
  String get desktopControlTitle => '控制一台电脑';

  @override
  String get desktopControlBody => '粘贴另一台电脑显示的连接信息，即可开始控制。';

  @override
  String get hostConnectionDescriptorLabel => '电脑连接信息';

  @override
  String get hostConnectionDescriptorHint => '在此粘贴另一台电脑的连接信息';

  @override
  String get hostConnectionDescriptorPrivacy =>
      '这里只包含建立连接需要的公开信息，不包含密码或其他秘密信息。';

  @override
  String get invalidHostDescriptor => '连接信息无效。';

  @override
  String get connectAction => '连接';

  @override
  String get connectingAction => '正在连接…';

  @override
  String remoteDesktopTitle(String hostName) {
    return '远程桌面 — $hostName';
  }

  @override
  String get closeSessionAction => '关闭连接';

  @override
  String get remoteInputHint => '点击桌面后可发送鼠标和键盘输入。';

  @override
  String get localExitShortcutHint => '本地退出：Ctrl+Alt+Shift+Esc';

  @override
  String get remoteIdle => '就绪';

  @override
  String get remoteConnecting => '正在连接另一台电脑…';

  @override
  String get remoteReconnectingPending => '连接已中断，正在准备安全重连…';

  @override
  String remoteReconnecting(int attempt, int maximum, int seconds) {
    return '正在重连…第 $attempt/$maximum 次尝试，剩余 $seconds 秒。';
  }

  @override
  String get remoteAuthenticating => '正在确认两台设备…';

  @override
  String get remoteNegotiating => '正在等待另一台电脑响应…';

  @override
  String get remoteConnected => '已连接';

  @override
  String get remoteClosing => '正在关闭并释放输入…';

  @override
  String get remoteAuthenticationFailed => '无法安全确认这是你配对的电脑。';

  @override
  String get remoteHostAgentFailed => '另一台电脑的远程控制服务不可用。';

  @override
  String get remoteLocalIdentityFailed => 'Roammand 无法读取这台设备的安全配对信息。';

  @override
  String get remoteSignalingFailed => 'Roammand 无法连接到连接服务。';

  @override
  String get remoteConfigurationFailed => '远程连接设置无效。';

  @override
  String get remoteConnectionFailed => '远程连接失败。';

  @override
  String get retryRemoteAction => '重试';

  @override
  String get diagnosticsAction => '诊断';

  @override
  String get diagnosticsTitle => '隐私保护的诊断报告';

  @override
  String get diagnosticsPreviewBody =>
      '连接失败时，可以保存这份本地报告，查看连接步骤、耗时和整体网络质量。保存前可以确认包含哪些内容；报告不会上传，也不会复制到剪贴板。';

  @override
  String get diagnosticsIncludedTitle => '包含';

  @override
  String get diagnosticsExcludedTitle => '排除';

  @override
  String get diagnosticsIncludedVersions => 'Roammand 和操作系统版本';

  @override
  String get diagnosticsIncludedSession => '连接步骤和安全错误代码';

  @override
  String get diagnosticsIncludedReconnect => '重连次数和时间信息';

  @override
  String get diagnosticsIncludedWebRtc => '整体连接质量数据';

  @override
  String get diagnosticsExcludedDeviceIdentifiers => '可识别设备的信息';

  @override
  String get diagnosticsExcludedDeviceNames => '设备名称';

  @override
  String get diagnosticsExcludedKeys => '密钥和签名';

  @override
  String get diagnosticsExcludedTokens => '登录信息、密码和其他秘密信息';

  @override
  String get diagnosticsExcludedSdpIce => '详细的联网信息';

  @override
  String get diagnosticsExcludedNetworkAddresses => 'IP 地址和端口';

  @override
  String get diagnosticsExcludedInput => '输入内容和坐标';

  @override
  String get diagnosticsExcludedScreen => '屏幕内容';

  @override
  String get diagnosticsExcludedRawPayloads => '未经处理的通信内容';

  @override
  String get diagnosticsExcludedRawStats => '未经处理的连接数据';

  @override
  String diagnosticsEventSummary(int count, String truncated) {
    return '已采集事件：$count。已截断：$truncated。';
  }

  @override
  String get diagnosticsTruncatedYes => '是';

  @override
  String get diagnosticsTruncatedNo => '否';

  @override
  String get diagnosticsSaveAction => '保存报告';

  @override
  String get diagnosticsSavingAction => '正在保存…';

  @override
  String diagnosticsSaved(String path) {
    return '已在本地保存到 $path';
  }

  @override
  String get diagnosticsSaveFailed => '无法保存诊断报告。';

  @override
  String get networkSettingsTooltip => '连接设置';

  @override
  String get networkSettingsTitle => '连接服务';

  @override
  String get networkSettingsBody => '推荐使用 Roammand 官方服务。自定义地址仅适合高级用户和自建服务。';

  @override
  String get networkProfileLabel => '选择服务';

  @override
  String get networkOfficialProfile => '官方服务';

  @override
  String get networkOfficialProfileBody => '推荐。Roammand 会自动配置所需地址。';

  @override
  String get networkCustomProfile => '自定义服务';

  @override
  String get networkCustomProfileBody => '适合运行自建信令和 STUN 服务的高级用户。';

  @override
  String get networkSignalingEndpointLabel => '信令 WebSocket 地址';

  @override
  String get networkSignalingEndpointHint =>
      'wss://signal.example.com/v1/connect';

  @override
  String get networkStunUrlsLabel => 'STUN 地址';

  @override
  String get networkStunUrlsHint => '每行填写一个 stun: 或 stuns: 地址';

  @override
  String get networkStunOptionalNotice =>
      '局域网测试可以不配置 STUN。当前版本没有 TURN 兜底，因此部分受限网络可能无法连接。';

  @override
  String get networkMobileHostBindingNotice =>
      '这台设备会继续使用配对二维码中的服务地址。这里的设置用于电脑之间的连接，也会作为以后新配对的默认值。';

  @override
  String get networkSaveAction => '保存设置';

  @override
  String get networkSavingAction => '正在保存…';

  @override
  String get networkRestoreAction => '恢复官方设置';

  @override
  String get networkInvalidSignaling =>
      '请输入有效且安全的信令 WebSocket 地址。私有网络 ws:// 地址仅在明确启用的 Debug 构建中允许。';

  @override
  String get networkInvalidStun => '请每行填写一个有效的 stun: 或 stuns: 地址。';

  @override
  String get networkInvalidConfiguration => '信令或 STUN 配置无效。';

  @override
  String get networkSaveFailed => '无法保存连接设置。';

  @override
  String get networkChangeHostTitle => '修改此电脑的网络服务？';

  @override
  String get networkChangeHostBody =>
      'Roammand 后台服务会重新启动，当前远程连接也会关闭。如果服务地址发生变化，之前配对的设备需要重新配对。';

  @override
  String get networkConfirmChangeAction => '保存并重启';

  @override
  String get networkConfigurationSaved => '连接设置已保存。';

  @override
  String get networkHostMigrationSaved => '服务器已更换，请向之前配对的设备显示新的二维码。';

  @override
  String get networkExternalHostRestartRequired =>
      '设置已保存。当前有开发者单独启动的后台服务，请使用相同设置手动重启它。';

  @override
  String get networkHostRestartFailed =>
      '设置已保存，但 Roammand 后台服务无法重启。请退出并重新打开 Roammand，然后检查“连接”设置。';

  @override
  String get mobileUnfamiliarServerTitle => '使用其他连接服务？';

  @override
  String mobileUnfamiliarServerBody(String endpoint) {
    return '此二维码会使用 $endpoint。该服务可能看到基本连接信息，或中断连接。请仅在信任这台电脑和服务提供者时继续。';
  }

  @override
  String get mobileTrustServerAction => '信任并继续';
}
