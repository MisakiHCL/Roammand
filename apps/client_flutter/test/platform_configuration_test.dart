// SPDX-License-Identifier: MPL-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'macOS desktop Runner can reach the separate current-user Host Agent',
    () {
      for (final fileName in <String>[
        'macos/Runner/DebugProfile.entitlements',
        'macos/Runner/Release.entitlements',
      ]) {
        final contents = File(fileName).readAsStringSync();
        expect(
          RegExp(
            r'<key>com\.apple\.security\.app-sandbox</key>\s*<false/>',
          ).hasMatch(contents),
          isTrue,
          reason: fileName,
        );
      }
    },
  );

  test('macOS release entitlements exclude development-only capabilities', () {
    final release = File(
      'macos/Runner/Release.entitlements',
    ).readAsStringSync();

    expect(release, isNot(contains('com.apple.security.cs.allow-jit')));
    expect(release, isNot(contains('com.apple.security.network.server')));
  });

  test('macOS title bar blends native window controls into Flutter', () {
    final window = File(
      'macos/Runner/MainFlutterWindow.swift',
    ).readAsStringSync();

    expect(window, contains('titleVisibility = .hidden'));
    expect(window, contains('titlebarAppearsTransparent = true'));
    expect(window, contains('styleMask.insert(.fullSizeContentView)'));
    expect(window, contains('self.minSize = minimumWindowSize'));
    expect(window, contains('_ = script.executeAndReturnError(&errorInfo)'));
    expect(window, contains('guard errorInfo == nil else'));
    expect(window, isNot(contains('executeAndReturnError(&errorInfo) != nil')));
  });

  test('mobile identity and camera platform policy is explicit', () {
    final androidManifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(androidManifest, contains('android.permission.CAMERA'));
    expect(androidManifest, contains('android.hardware.camera.any'));
    expect(androidManifest, contains('android:required="false"'));
    expect(androidManifest, contains('android:allowBackup="false"'));
    expect(
      androidManifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
    expect(
      androidManifest,
      contains('android:fullBackupContent="@xml/backup_rules"'),
    );
    final legacyBackupRules = File(
      'android/app/src/main/res/xml/backup_rules.xml',
    ).readAsStringSync();
    final dataExtractionRules = File(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    ).readAsStringSync();
    expect(dataExtractionRules, contains('<cloud-backup>'));
    expect(dataExtractionRules, contains('<device-transfer>'));
    for (final domain in <String>[
      'root',
      'file',
      'database',
      'sharedpref',
      'external',
      'device_root',
      'device_file',
      'device_database',
      'device_sharedpref',
    ]) {
      final exclusion = '<exclude domain="$domain" path="." />';
      expect(legacyBackupRules, contains(exclusion), reason: domain);
      expect(
        exclusion.allMatches(dataExtractionRules),
        hasLength(2),
        reason: domain,
      );
    }
    final identityStore = File(
      'lib/mobile/identity/mobile_identity_store.dart',
    ).readAsStringSync();
    expect(identityStore, contains('migrateWithBackup: true'));
    expect(identityStore, contains('device-to-device transfer exclude'));

    final androidBuild = File(
      'android/app/build.gradle.kts',
    ).readAsStringSync();
    expect(androidBuild, contains('minSdk = 24'));

    final iosInfo = File('ios/Runner/Info.plist').readAsStringSync();
    expect(iosInfo, contains('<key>NSCameraUsageDescription</key>'));
    expect(
      RegExp(
        r'<key>ITSAppUsesNonExemptEncryption</key>\s*<false/>',
      ).hasMatch(iosInfo),
      isTrue,
    );
    expect(iosInfo, contains('<key>NSAppTransportSecurity</key>'));
    expect(
      RegExp(r'<key>NSAllowsLocalNetworking</key>\s*<true/>').hasMatch(iosInfo),
      isTrue,
    );
    expect(iosInfo, isNot(contains('<key>NSAllowsArbitraryLoads</key>')));
    expect(iosInfo, contains('<key>NSLocalNetworkUsageDescription</key>'));
    expect(iosInfo, isNot(contains('<key>UIBackgroundModes</key>')));
    final iosSceneDelegate = File(
      'ios/Runner/SceneDelegate.swift',
    ).readAsStringSync();
    expect(iosSceneDelegate, contains('sceneWillResignActive'));
    expect(iosSceneDelegate, contains('sceneDidEnterBackground'));
    expect(iosSceneDelegate, contains('sceneDidBecomeActive'));
    expect(iosSceneDelegate, contains('installPrivacyShield(in: scene)'));
    expect(iosSceneDelegate, contains('shield.backgroundColor = .black'));
    expect(iosSceneDelegate, contains('shield.isOpaque = true'));
    for (final fileName in <String>[
      'ios/Runner/en.lproj/InfoPlist.strings',
      'ios/Runner/zh-Hans.lproj/InfoPlist.strings',
    ]) {
      final localizedInfo = File(fileName).readAsStringSync();
      expect(
        localizedInfo,
        contains('"NSCameraUsageDescription"'),
        reason: fileName,
      );
      expect(
        localizedInfo,
        contains('"NSLocalNetworkUsageDescription"'),
        reason: fileName,
      );
    }
    expect(
      RegExp(r'<key>UIFileSharingEnabled</key>\s*<true/>').hasMatch(iosInfo),
      isTrue,
    );
    expect(
      RegExp(
        r'<key>LSSupportsOpeningDocumentsInPlace</key>\s*<true/>',
      ).hasMatch(iosInfo),
      isTrue,
    );
    final iosEntitlements = File(
      'ios/Runner/Runner.entitlements',
    ).readAsStringSync();
    expect(
      RegExp(
        r'<key>keychain-access-groups</key>\s*<array>\s*'
        r'<string>\$\(AppIdentifierPrefix\)\$\(PRODUCT_BUNDLE_IDENTIFIER\)'
        r'</string>\s*</array>',
      ).hasMatch(iosEntitlements),
      isTrue,
    );
    final iosProject = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    const iosMinimumVersion = '15.0';
    final iosPodfile = File('ios/Podfile').readAsStringSync();
    final iosPodPlatforms = RegExp(
      r"^platform :ios, '([^']+)'$",
      multiLine: true,
    ).allMatches(iosPodfile).map((match) => match.group(1)).toList();
    final iosDeploymentTargets = RegExp(
      r'IPHONEOS_DEPLOYMENT_TARGET = ([^;]+);',
    ).allMatches(iosProject).map((match) => match.group(1)).toList();
    expect(iosPodPlatforms, <String?>[iosMinimumVersion]);
    expect(iosDeploymentTargets, hasLength(3));
    expect(iosDeploymentTargets, everyElement(iosMinimumVersion));
    expect(
      RegExp(
        r'CODE_SIGN_ENTITLEMENTS = Runner/Runner\.entitlements;',
      ).allMatches(iosProject),
      hasLength(3),
    );
    expect(iosProject, contains('isa = PBXVariantGroup;'));
    expect(iosProject, contains('InfoPlist.strings in Resources'));
    expect(iosProject, contains('path = en.lproj/InfoPlist.strings;'));
    expect(iosProject, contains('path = "zh-Hans.lproj/InfoPlist.strings";'));

    final androidDebugManifest = File(
      'android/app/src/debug/AndroidManifest.xml',
    ).readAsStringSync();
    expect(
      androidDebugManifest,
      contains('android:usesCleartextTraffic="true"'),
    );
    expect(
      androidManifest,
      isNot(contains('android:usesCleartextTraffic="true"')),
    );
  });

  test('Apple signing identity is loaded only from an ignored local file', () {
    final rootIgnore = File('../../.gitignore').readAsStringSync();
    for (final pattern in <String>[
      '*.local.xcconfig',
      '*.certSigningRequest',
      '*.cer',
      '*.p8',
      '*.p12',
      '*.mobileprovision',
      '*.provisionprofile',
      '*.xcarchive',
      '*.ipa',
      '*.pkg',
      'notarization*.json',
    ]) {
      expect(rootIgnore, contains(pattern), reason: pattern);
    }
    final appIgnore = File('.gitignore').readAsStringSync();
    expect(appIgnore, contains('/apple/Signing.local.xcconfig'));
    expect(appIgnore, contains('/apple/ExportOptions.local.plist'));

    final signing = File('apple/Signing.xcconfig').readAsStringSync();
    expect(signing, contains('#include? "Signing.local.xcconfig"'));
    expect(
      signing,
      contains('PRODUCT_BUNDLE_IDENTIFIER = \$(ROAMMAND_APPLE_BUNDLE_ID)'),
    );
    expect(signing, contains('DEVELOPMENT_TEAM = \$(ROAMMAND_APPLE_TEAM_ID)'));

    for (final fileName in <String>[
      'ios/Flutter/Debug.xcconfig',
      'ios/Flutter/Release.xcconfig',
    ]) {
      expect(
        File(fileName).readAsStringSync(),
        contains('#include "../../apple/Signing.xcconfig"'),
        reason: fileName,
      );
    }
    expect(
      File('macos/Runner/Configs/AppInfo.xcconfig').readAsStringSync(),
      contains('#include "../../../apple/Signing.xcconfig"'),
    );

    final iosProject = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(
      RegExp(r'DEVELOPMENT_TEAM = [A-Z0-9]{10};').hasMatch(iosProject),
      isFalse,
    );
    expect(
      iosProject,
      isNot(contains('PRODUCT_BUNDLE_IDENTIFIER = dev.roammand.app;')),
    );
  });

  test(
    'Apple signing configurator validates and writes a private override',
    () {
      final temporary = Directory.systemTemp.createTempSync(
        'roammand-apple-signing-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));
      final output = '${temporary.path}/Signing.local.xcconfig';
      final script = File(
        '../../scripts/configure_apple_signing.sh',
      ).absolute.path.replaceAll(r'\', '/');
      final shellOutput = output.replaceAll(r'\', '/');

      final configured = Process.runSync('bash', <String>[
        script,
        '--team-id',
        'A1B2C3D4E5',
        '--bundle-id',
        'com.example.remote',
        '--output',
        shellOutput,
      ]);
      expect(configured.exitCode, 0, reason: configured.stderr as String);
      expect(
        File(output).readAsStringSync(),
        contains('ROAMMAND_APPLE_TEAM_ID = A1B2C3D4E5'),
      );
      expect(
        File(output).readAsStringSync(),
        contains('ROAMMAND_APPLE_BUNDLE_ID = com.example.remote'),
      );

      final checked = Process.runSync('bash', <String>[
        script,
        '--check',
        '--output',
        shellOutput,
      ]);
      expect(checked.exitCode, 0, reason: checked.stderr as String);

      final invalid = Process.runSync('bash', <String>[
        script,
        '--team-id',
        'not-a-team',
        '--bundle-id',
        'not-a-bundle-id',
        '--output',
        shellOutput,
      ]);
      expect(invalid.exitCode, isNonZero);
    },
    skip: Platform.isWindows
        ? 'Apple signing is validated on the macOS CI runner.'
        : false,
  );
}
