// SPDX-License-Identifier: MPL-2.0

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:roammand/diagnostics/diagnostics_collector.dart';
import 'package:roammand/diagnostics/diagnostics_model.dart';
import 'package:roammand/desktop/remote/input_sender.dart';
import 'package:roammand/desktop/remote/remote_desktop_controller.dart';
import 'package:roammand/l10n/generated/app_localizations.dart';
import 'package:roammand/mobile/remote/mobile_input_tray.dart';
import 'package:roammand/mobile/remote/mobile_keyboard_controller.dart';
import 'package:roammand/mobile/remote/mobile_remote_desktop_page.dart';
import 'package:roammand/mobile/widgets/mobile_page_header.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

void main() {
  testWidgets('locks the remote page to landscape and restores app rotation', (
    tester,
  ) async {
    final orientationArguments = <List<Object?>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientationArguments.add(List<Object?>.from(call.arguments as List));
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final fixture = _PageFixture();

    await tester.pumpWidget(_app(fixture.page()));
    await tester.pump();
    expect(orientationArguments.first, <String>[
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(orientationArguments.last, isEmpty);
  });

  testWidgets('keeps the iOS app landscape after leaving a remote session', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final orientationArguments = <List<Object?>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          orientationArguments.add(List<Object?>.from(call.arguments as List));
        }
        return null;
      },
    );
    try {
      await tester.pumpWidget(_app(_PageFixture().page()));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(orientationArguments, hasLength(2));
      expect(orientationArguments.last, <String>[
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    }
  });

  testWidgets('connects once and maps a delayed tap after rotation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = _PageFixture();
    await tester.pumpWidget(_app(fixture.page()));
    await tester.pump();

    expect(fixture.controller.connectCount, 1);
    expect(find.byType(SafeArea), findsNothing);
    expect(find.text('Connected'), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(720, 360));
    await tester.pump();
    final surface = find.byKey(const Key('mobile-remote-gesture-surface'));
    await tester.tapAt(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 301));

    final clicks = fixture.reliable.decoded
        .where((event) => event.hasPointerButton())
        .toList(growable: false);
    expect(clicks, hasLength(1));
    expect(
      clicks.single.pointerButton.action,
      ButtonAction.BUTTON_ACTION_CLICK,
    );
    expect(clicks.single.pointerButton.x, 5000);
    expect(clicks.single.pointerButton.y, 5000);
  });

  testWidgets('keeps status above the video with one session exit action', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_PageFixture().page()));
    await tester.pump();

    final status = find.byKey(const Key('mobile-remote-status'));
    final surface = find.byKey(const Key('mobile-remote-gesture-surface'));
    expect(status, findsOneWidget);
    expect(surface, findsOneWidget);
    expect(find.ancestor(of: status, matching: surface), findsNothing);
    expect(find.byKey(const Key('mobile-remote-back-action')), findsOneWidget);
    expect(find.byType(MobilePageBackButton), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets(
    'ignores the bottom safe area while respecting horizontal safe areas',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(844, 390));
      tester.view.padding = const FakeViewPadding(
        left: 132,
        right: 72,
        bottom: 60,
      );
      addTearDown(() {
        tester.view.padding = FakeViewPadding.zero;
        return tester.binding.setSurfaceSize(null);
      });
      final fixture = _PageFixture(
        state: RemoteDesktopState.failed,
        errorCode: RemoteDesktopErrorCode.signaling,
      );
      fixture.controller.retryAvailable = true;
      await tester.pumpWidget(_app(fixture.page(), locale: const Locale('zh')));
      await tester.pump();

      final header = find.byKey(const Key('mobile-remote-header'));
      final surface = find.byKey(const Key('mobile-remote-gesture-surface'));
      final video = find.byKey(const Key('mobile-test-video'));
      final controlBar = find.byKey(const Key('mobile-remote-control-bar'));
      expect(tester.getRect(header).left, 0);
      expect(tester.getRect(header).right, 844);
      expect(tester.getRect(surface).left, 0);
      expect(tester.getRect(surface).right, 844);
      expect(tester.getRect(surface).top, 0);
      expect(tester.getRect(surface).bottom, 390);
      expect(tester.getRect(video).top, 0);
      expect(tester.getRect(video).bottom, 390);
      expect(tester.getRect(controlBar).left, 0);
      expect(tester.getRect(controlBar).right, 844);
      expect(tester.getRect(controlBar).bottom, 390);
      expect(tester.getSize(controlBar).height, 40);
      expect(
        tester.getRect(find.byKey(const Key('mobile-keyboard-toggle'))).bottom,
        390,
      );
      expect(
        tester.getRect(find.byKey(const Key('mobile-remote-back-action'))).left,
        greaterThanOrEqualTo(44),
      );
      expect(
        tester
            .getRect(find.byKey(const Key('mobile-remote-diagnostics-action')))
            .right,
        tester.getRect(find.byKey(const Key('mobile-keyboard-toggle'))).right,
      );
      expect(
        tester.getSize(find.byKey(const Key('mobile-remote-status'))).height,
        32,
      );
      expect(tester.widget<Material>(header).color, Colors.transparent);
      expect(tester.widget<Material>(controlBar).color, Colors.transparent);

      await tester.tap(find.byKey(const Key('mobile-keyboard-toggle')));
      await tester.pump();
      final inputTray = find.byKey(const Key('mobile-input-tray'));
      expect(tester.getRect(inputTray).bottom, 390);
      expect(
        tester.widget<MobileInputTray>(inputTray).padding,
        const EdgeInsets.fromLTRB(52, 8, 32, 8),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('starts with edge-to-edge video behind the control overlays', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 390));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(_PageFixture().page()));
    await tester.pump();

    final surface = find.byKey(const Key('mobile-remote-gesture-surface'));
    final video = find.byKey(const Key('mobile-test-video'));
    expect(tester.getRect(surface), const Rect.fromLTWH(0, 0, 844, 390));
    expect(tester.getRect(video).top, 0);
    expect(tester.getRect(video).bottom, 390);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lock mode leaves only unlock and restores immersive chrome', (
    tester,
  ) async {
    final systemUiModes = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          systemUiModes.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final fixture = _PageFixture();
    await tester.pumpWidget(_app(fixture.page(), locale: const Locale('zh')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('mobile-keyboard-toggle')));
    await tester.pump();
    expect(find.byKey(const Key('mobile-input-tray')), findsOneWidget);
    final lockRect = tester.getRect(
      find.byKey(const Key('mobile-control-lock')),
    );
    await tester.tap(find.byKey(const Key('mobile-control-lock')));
    await tester.pump();

    expect(find.byKey(const Key('mobile-remote-header')), findsNothing);
    expect(find.byKey(const Key('mobile-remote-control-bar')), findsNothing);
    expect(find.byKey(const Key('mobile-input-tray')), findsNothing);
    expect(find.byKey(const Key('mobile-control-lock')), findsNothing);
    expect(find.byKey(const Key('mobile-control-unlock')), findsOneWidget);
    expect(find.byType(IconButton), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('mobile-control-unlock'))),
      lockRect,
    );
    expect(systemUiModes, contains('SystemUiMode.immersiveSticky'));

    await tester.tap(find.byKey(const Key('mobile-control-unlock')));
    await tester.pump();
    expect(find.byKey(const Key('mobile-control-unlock')), findsNothing);
    expect(find.byKey(const Key('mobile-remote-header')), findsOneWidget);
    expect(find.byKey(const Key('mobile-remote-control-bar')), findsOneWidget);
    expect(find.byKey(const Key('mobile-input-tray')), findsNothing);
    expect(systemUiModes.last, 'SystemUiMode.edgeToEdge');
  });

  testWidgets('reconnecting forces immersive controls to unlock', (
    tester,
  ) async {
    final systemUiModes = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          systemUiModes.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final fixture = _PageFixture();
    await tester.pumpWidget(_app(fixture.page()));
    await tester.pump();

    await tester.tap(find.byKey(const Key('mobile-control-lock')));
    await tester.pump();
    fixture.controller
      ..state = RemoteDesktopState.reconnecting
      ..notifyListeners();
    await tester.pump();

    expect(find.byKey(const Key('mobile-control-unlock')), findsNothing);
    expect(find.byKey(const Key('mobile-remote-header')), findsOneWidget);
    expect(find.byKey(const Key('mobile-remote-control-bar')), findsOneWidget);
    expect(find.byKey(const Key('mobile-control-lock')), findsNothing);
    expect(systemUiModes.last, 'SystemUiMode.edgeToEdge');
  });

  testWidgets('avoids overflow when the iOS keyboard reduces landscape space', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 390));
    addTearDown(() {
      tester.view.viewInsets = FakeViewPadding.zero;
      return tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_app(_PageFixture().page()));
    await tester.pump();

    await tester.tap(find.byKey(const Key('mobile-keyboard-toggle')));
    await tester.pump();
    final viewportBeforeKeyboard = tester.getRect(
      find.byKey(const Key('mobile-remote-gesture-surface')),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 120);
    await tester.pump();
    final viewportDuringKeyboardAnimation = tester.getRect(
      find.byKey(const Key('mobile-remote-gesture-surface')),
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pump();

    expect(find.byKey(const Key('mobile-text-input')), findsOneWidget);
    final textInput = tester.widget<TextField>(
      find.byKey(const Key('mobile-text-input')),
    );
    expect(textInput.cursorOpacityAnimates, isFalse);
    expect(textInput.enableIMEPersonalizedLearning, isFalse);
    expect(find.byKey(const Key('mobile-remote-header')), findsOneWidget);
    expect(
      find.byKey(const Key('mobile-remote-gesture-surface')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('mobile-remote-control-bar')), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('mobile-input-tray'))).height,
      56,
    );
    expect(viewportDuringKeyboardAnimation, viewportBeforeKeyboard);
    expect(
      tester.getRect(find.byKey(const Key('mobile-remote-gesture-surface'))),
      viewportBeforeKeyboard,
    );
    expect(
      tester.getRect(find.byKey(const Key('mobile-input-tray'))).bottom,
      390 - (240 / tester.view.devicePixelRatio),
    );
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).resizeToAvoidBottomInset,
      isFalse,
    );
    expect(find.byKey(const Key('mobile-modifier-control')), findsNothing);
    expect(
      find.byKey(const Key('mobile-dismiss-keyboard-action')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'keeps the text field focused while the software keyboard opens',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(844, 390));
      addTearDown(() {
        tester.view.viewInsets = FakeViewPadding.zero;
        return tester.binding.setSurfaceSize(null);
      });
      final fixture = _PageFixture();
      await tester.pumpWidget(_app(fixture.page()));
      await tester.pump();

      await tester.tap(find.byKey(const Key('mobile-keyboard-toggle')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('mobile-text-input')));
      await tester.pump();
      final editableBefore = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );

      tester.view.viewInsets = const FakeViewPadding(bottom: 720);
      await tester.pump();

      final editableAfter = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      expect(identical(editableAfter, editableBefore), isTrue);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(
        tester.getSize(find.byKey(const Key('mobile-input-tray'))).height,
        56,
      );
      expect(find.byKey(const Key('mobile-remote-header')), findsOneWidget);
      expect(
        find.byKey(const Key('mobile-remote-gesture-surface')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('mobile-modifier-control')), findsNothing);

      await tester.enterText(
        find.byKey(const Key('mobile-text-input')),
        'still focused',
      );
      await tester.tap(find.byKey(const Key('mobile-text-send')));
      await tester.pump();
      expect(
        fixture.reliable.decoded
            .where((event) => event.hasText())
            .single
            .text
            .text,
        'still focused',
      );

      final dismissOverlay = find.byKey(
        const Key('mobile-dismiss-keyboard-overlay'),
      );
      expect(dismissOverlay, findsOneWidget);
      await tester.tap(dismissOverlay);
      await tester.pump(const Duration(milliseconds: 301));
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isFalse,
      );
      expect(
        fixture.reliable.decoded.where((event) => event.hasPointerButton()),
        isEmpty,
      );

      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      expect(dismissOverlay, findsNothing);
      expect(
        find.byKey(const Key('mobile-remote-control-bar')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('mobile-modifier-control')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dismisses the iOS keyboard from an outside tap', (tester) async {
    await tester.binding.setSurfaceSize(const Size(844, 390));
    addTearDown(() {
      tester.view.viewInsets = FakeViewPadding.zero;
      return tester.binding.setSurfaceSize(null);
    });
    final fixture = _PageFixture();
    await tester.pumpWidget(_app(fixture.page()));
    await tester.pump();

    await tester.tap(find.byKey(const Key('mobile-keyboard-toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('mobile-text-input')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pump();

    EditableText editable() =>
        tester.widget<EditableText>(find.byType(EditableText));

    expect(editable().focusNode.hasFocus, isTrue);
    expect(
      find.byKey(const Key('mobile-dismiss-keyboard-action')),
      findsNothing,
    );
    final textField = tester.widget<TextField>(
      find.byKey(const Key('mobile-text-input')),
    );
    expect(textField.onTapOutside, isNotNull);
    textField.onTapOutside!(const PointerDownEvent());
    await tester.pump();
    expect(editable().focusNode.hasFocus, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sends text, modifiers and special keys from the mobile tray', (
    tester,
  ) async {
    final fixture = _PageFixture();
    await tester.pumpWidget(_app(fixture.page()));
    await tester.pump();

    await tester.tap(find.byKey(const Key('mobile-keyboard-toggle')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('mobile-text-input')),
      'hello 世界',
    );
    await tester.tap(find.byKey(const Key('mobile-text-send')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('mobile-modifier-control')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('mobile-special-tab')));
    await tester.pump();

    final events = fixture.reliable.decoded;
    expect(
      events.where((event) => event.hasText()).single.text.text,
      'hello 世界',
    );
    final keyboard = events
        .where((event) => event.hasKeyboard())
        .map((event) => event.keyboard)
        .toList(growable: false);
    expect(keyboard.first.usbHidUsage, 0xe0);
    expect(keyboard.first.modifierBits, 0x01);
    expect(keyboard.where((event) => event.usbHidUsage == 0x2b), hasLength(2));
    expect(keyboard.last.modifierBits, 0x01);
  });

  for (final threeFingers in <bool>[false, true]) {
    testWidgets(
      '${threeFingers ? 'three-finger cancellation' : 'pointer cancellation'} releases idle modifiers and repaints the tray',
      (tester) async {
        final fixture = _PageFixture();
        await tester.pumpWidget(_app(fixture.page()));
        await tester.pump();
        await tester.tap(find.byKey(const Key('mobile-keyboard-toggle')));
        await tester.pump();
        final keyboard = tester
            .widget<MobileInputTray>(find.byType(MobileInputTray))
            .controller!;
        final control = find.byKey(const Key('mobile-modifier-control'));
        await keyboard.setModifier(MobileModifierKey.control, true);
        await tester.pump();
        expect(tester.widget<FilterChip>(control).selected, isTrue);

        final surface = find.byKey(const Key('mobile-remote-gesture-surface'));
        final center = tester.getCenter(surface);
        final first = await tester.startGesture(center, pointer: 1);
        if (threeFingers) {
          final second = await tester.startGesture(
            center + const Offset(20, 0),
            pointer: 2,
          );
          final third = await tester.startGesture(
            center - const Offset(20, 0),
            pointer: 3,
          );
          await first.up();
          await second.up();
          await third.up();
        } else {
          await first.cancel();
        }
        await tester.pump();

        expect(
          fixture.reliable.decoded.where((event) => event.hasReleaseAllInput()),
          hasLength(1),
        );
        expect(keyboard.activeModifiers, isEmpty);
        expect(tester.widget<FilterChip>(control).selected, isFalse);
        await tester.tap(find.byKey(const Key('mobile-special-tab')));
        await tester.pump();
        final tabs = fixture.reliable.decoded
            .where(
              (event) =>
                  event.hasKeyboard() && event.keyboard.usbHidUsage == 0x2b,
            )
            .map((event) => event.keyboard);
        expect(tabs, hasLength(2));
        expect(tabs.map((event) => event.modifierBits), everyElement(0));

        await tester.tap(control);
        await tester.pump();
        final controlDowns = fixture.reliable.decoded.where(
          (event) =>
              event.hasKeyboard() &&
              event.keyboard.usbHidUsage == 0xe0 &&
              event.keyboard.action == KeyboardAction.KEYBOARD_ACTION_DOWN,
        );
        expect(controlDowns, hasLength(2));
        expect(tester.widget<FilterChip>(control).selected, isTrue);
        expect(fixture.controller.closeCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'gesture and repeated background releases cancel queued keyboard input',
    (tester) async {
      final fixture = _PageFixture();
      await tester.pumpWidget(_app(fixture.page()));
      await tester.pump();
      await tester.tap(find.byKey(const Key('mobile-keyboard-toggle')));
      await tester.pump();
      final keyboard = tester
          .widget<MobileInputTray>(find.byType(MobileInputTray))
          .controller!;
      await keyboard.setModifier(MobileModifierKey.control, true);
      await tester.pump();

      final gate = Completer<void>();
      fixture.reliable.nextSendGate = gate;
      addTearDown(() {
        fixture.controller.sender?.abort();
        if (!gate.isCompleted) gate.complete();
      });
      final finger = await tester.startGesture(
        tester.getCenter(
          find.byKey(const Key('mobile-remote-gesture-surface')),
        ),
        pointer: 1,
      );
      await tester.pump(const Duration(milliseconds: 501));
      final text = _inputError(keyboard.sendText('cancelled text'));
      final special = _inputError(keyboard.sendSpecial(MobileSpecialKey.tab));
      await finger.cancel();
      await tester.pump();
      expect(await text, InputSenderErrorCode.cancelled);
      expect(await special, InputSenderErrorCode.cancelled);
      expect(keyboard.activeModifiers, isEmpty);
      expect(
        tester
            .widget<FilterChip>(
              find.byKey(const Key('mobile-modifier-control')),
            )
            .selected,
        isFalse,
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      final newModifier = _inputError(
        keyboard.setModifier(MobileModifierKey.control, true),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(await newModifier, InputSenderErrorCode.cancelled);
      expect(keyboard.activeModifiers, isEmpty);

      gate.complete();
      await tester.pump();
      final events = fixture.reliable.decoded;
      expect(events.where((event) => event.hasReleaseAllInput()), hasLength(1));
      expect(events.where((event) => event.hasText()), isEmpty);
      expect(
        events
            .where((event) => event.hasKeyboard())
            .map((event) => event.keyboard.usbHidUsage),
        <int>[0xe0],
      );
      expect(fixture.controller.closeCount, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fixture.controller.closeCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'replacing the sender and surface keeps old release in its session',
    (tester) async {
      final fixture = _PageFixture();
      await tester.pumpWidget(_app(fixture.page(videoAspectRatio: null)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('mobile-keyboard-toggle')));
      await tester.pump();
      final previous = tester
          .widget<MobileInputTray>(find.byType(MobileInputTray))
          .controller!;
      await previous.setModifier(MobileModifierKey.control, true);
      await tester.pump();

      final reliable = _CaptureChannel();
      final renderer = RTCVideoRenderer();
      addTearDown(() => unawaited(renderer.dispose()));
      fixture.controller
        ..sender = RemoteInputSender(
          sessionId: List<int>.filled(16, 0x52),
          reliable: reliable,
          fast: _CaptureChannel(),
        )
        ..renderer = renderer
        ..notifyListeners();
      await tester.pump();
      await tester.pump();

      expect(previous.activeModifiers, isEmpty);
      expect(
        fixture.reliable.decoded.where((event) => event.hasReleaseAllInput()),
        hasLength(1),
      );
      expect(reliable.sent, isEmpty);
      final current = tester
          .widget<MobileInputTray>(find.byType(MobileInputTray))
          .controller!;
      expect(current, isNot(same(previous)));
      await current.setModifier(MobileModifierKey.control, true);
      final finger = await tester.startGesture(
        tester.getCenter(
          find.byKey(const Key('mobile-remote-gesture-surface')),
        ),
      );
      await finger.cancel();
      await tester.pump();
      expect(current.activeModifiers, isEmpty);
      expect(
        tester
            .widget<FilterChip>(
              find.byKey(const Key('mobile-modifier-control')),
            )
            .selected,
        isFalse,
      );
      expect(
        reliable.decoded.where((event) => event.hasReleaseAllInput()),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('background closes and leaves the remote page after resume', (
    tester,
  ) async {
    final fixture = _PageFixture();
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: Text('home')),
      ),
    );
    unawaited(
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(builder: (_) => fixture.page()),
      ),
    );
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(
      find.byKey(const Key('mobile-remote-privacy-shield')),
      findsOneWidget,
    );
    expect(
      fixture.reliable.decoded.where((event) => event.hasReleaseAllInput()),
      hasLength(1),
    );
    expect(fixture.controller.closeCount, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(find.byType(MobileRemoteDesktopPage), findsOneWidget);
    expect(fixture.controller.state, RemoteDesktopState.idle);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(fixture.controller.closeCount, 1);
    expect(fixture.controller.connectCount, 1);
    expect(find.text('home'), findsOneWidget);
    expect(find.byType(MobileRemoteDesktopPage), findsNothing);
  });

  testWidgets('covers remote content while inactive and restores on resume', (
    tester,
  ) async {
    final fixture = _PageFixture();
    await tester.pumpWidget(_app(fixture.page()));
    await tester.pump();

    final privacyShield = find.byKey(const Key('mobile-remote-privacy-shield'));
    expect(privacyShield, findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    expect(privacyShield, findsOneWidget);
    expect(tester.widget<ModalBarrier>(privacyShield).color, Colors.black);
    expect(fixture.controller.closeCount, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(privacyShield, findsNothing);
    expect(fixture.controller.closeCount, 0);
  });

  testWidgets('privacy shield covers a root diagnostics dialog', (
    tester,
  ) async {
    final fixture = _PageFixture();
    await tester.pumpWidget(_app(fixture.page()));
    await tester.pump();
    await tester.tap(find.byKey(const Key('mobile-remote-diagnostics-action')));
    await tester.pumpAndSettle();
    expect(find.text('Privacy-protected diagnostics'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(
      find.byKey(const Key('mobile-remote-privacy-shield')),
      findsOneWidget,
    );

    await tester.tap(find.text('Close'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Privacy-protected diagnostics'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Privacy-protected diagnostics'), findsNothing);
  });

  testWidgets('renders localized failure and remains usable when narrow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = _PageFixture(
      state: RemoteDesktopState.failed,
      errorCode: RemoteDesktopErrorCode.authentication,
    );
    await tester.pumpWidget(_app(fixture.page(), locale: const Locale('zh')));
    await tester.pump();

    expect(find.text('无法安全确认这是你配对的电脑。'), findsOneWidget);
    expect(find.byKey(const Key('mobile-keyboard-toggle')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('localizes reconnect progress and offers retry after failure', (
    tester,
  ) async {
    final fixture = _PageFixture(state: RemoteDesktopState.reconnecting);
    fixture.controller.progress = const RemoteReconnectProgress(
      attempt: 3,
      maximumAttempts: 5,
      elapsed: Duration(seconds: 7),
      recoveryWindow: Duration(seconds: 30),
    );
    await tester.pumpWidget(_app(fixture.page(), locale: const Locale('zh')));
    await tester.pump();

    expect(find.text('正在重连…第 3/5 次尝试，剩余 23 秒。'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(fixture.controller.inputSender, isNotNull);

    fixture.controller
      ..retryAvailable = true
      ..state = RemoteDesktopState.failed
      ..notifyListeners();
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const Key('mobile-remote-status'))).height,
      32,
    );
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(fixture.controller.retryCount, 1);
    expect(find.byType(MobileRemoteDesktopPage), findsOneWidget);
  });

  testWidgets(
    'system back unlocks and waits for session close before popping',
    (tester) async {
      final fixture = _PageFixture();
      final closeGate = Completer<void>();
      fixture.controller.closeGate = closeGate;
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: Text('home')),
        ),
      );
      unawaited(
        navigatorKey.currentState!.push<void>(
          MaterialPageRoute<void>(builder: (_) => fixture.page()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MobileRemoteDesktopPage), findsOneWidget);

      await tester.tap(find.byKey(const Key('mobile-control-lock')));
      await tester.pump();
      expect(find.byKey(const Key('mobile-control-unlock')), findsOneWidget);

      await navigatorKey.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(fixture.controller.closeCount, 1);
      expect(find.byType(MobileRemoteDesktopPage), findsOneWidget);
      expect(find.byKey(const Key('mobile-control-unlock')), findsNothing);
      expect(find.byKey(const Key('mobile-remote-header')), findsOneWidget);

      closeGate.complete();
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      expect(fixture.controller.closeCount, 1);
    },
  );

  testWidgets('Host stop closes the mobile page without retrying', (
    tester,
  ) async {
    final fixture = _PageFixture();
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: Text('home')),
      ),
    );
    unawaited(
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(builder: (_) => fixture.page()),
      ),
    );
    await tester.pumpAndSettle();

    fixture.controller
      ..state = RemoteDesktopState.idle
      ..notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('home'), findsOneWidget);
    expect(find.byType(MobileRemoteDesktopPage), findsNothing);
    expect(fixture.controller.closeCount, 1);
    expect(fixture.controller.retryCount, 0);
  });

  testWidgets('opens the localized diagnostics preview', (tester) async {
    final fixture = _PageFixture();
    await tester.pumpWidget(_app(fixture.page(), locale: const Locale('zh')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('mobile-remote-diagnostics-action')));
    await tester.pumpAndSettle();

    expect(find.text('隐私保护的诊断报告'), findsOneWidget);
    expect(find.text('包含'), findsOneWidget);
    expect(find.text('排除'), findsOneWidget);
  });
}

final class _PageFixture {
  _PageFixture({
    RemoteDesktopState state = RemoteDesktopState.connected,
    RemoteDesktopErrorCode? errorCode,
  }) : reliable = _CaptureChannel(),
       fast = _CaptureChannel(),
       controller = _FakeMobileViewModel(state, errorCode) {
    controller.sender = RemoteInputSender(
      sessionId: List<int>.filled(16, 0x51),
      reliable: reliable,
      fast: fast,
    );
  }

  final _CaptureChannel reliable;
  final _CaptureChannel fast;
  final _FakeMobileViewModel controller;

  MobileRemoteDesktopPage page({double? videoAspectRatio = 16 / 9}) =>
      MobileRemoteDesktopPage(
        target: _target(),
        controller: controller,
        videoAspectRatio: videoAspectRatio,
        videoBuilder: (context, renderer) => const ColoredBox(
          key: Key('mobile-test-video'),
          color: Colors.blue,
          child: SizedBox.expand(),
        ),
      );
}

final class _CaptureChannel implements InputDataChannel {
  final List<Uint8List> sent = <Uint8List>[];
  Completer<void>? nextSendGate;

  @override
  int get bufferedAmount => 0;

  List<ReliableInputEnvelope> get decoded =>
      sent.map(decodeAndValidateReliableInputEnvelope).toList(growable: false);

  @override
  Future<void> send(Uint8List bytes) {
    sent.add(Uint8List.fromList(bytes));
    final gate = nextSendGate;
    nextSendGate = null;
    return gate?.future ?? Future<void>.value();
  }
}

final class _FakeMobileViewModel extends ChangeNotifier
    implements RemoteDesktopViewModel {
  _FakeMobileViewModel(this.state, this.errorCode);

  @override
  RemoteDesktopState state;

  @override
  RemoteDesktopErrorCode? errorCode;

  RemoteReconnectProgress? progress;
  bool retryAvailable = false;

  RemoteInputSender? sender;
  Object? renderer;
  int connectCount = 0;
  int closeCount = 0;
  int retryCount = 0;
  bool _closed = false;
  Completer<void>? closeGate;

  @override
  bool get canRetry => retryAvailable;

  @override
  DiagnosticsReport get diagnosticsReport => _diagnosticsReport();

  @override
  RemoteInputSender? get inputSender => sender;

  @override
  RemoteReconnectProgress? get reconnectProgress => progress;

  @override
  Object get videoRenderer => renderer ?? this;

  @override
  Future<void> connect(RemoteDesktopTarget target) async {
    connectCount += 1;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    closeCount += 1;
    await closeGate?.future;
    await sender?.close();
    state = RemoteDesktopState.idle;
    notifyListeners();
  }

  @override
  Future<void> retry() async {
    retryCount += 1;
  }
}

Future<InputSenderErrorCode?> _inputError(Future<void> operation) =>
    operation.then<InputSenderErrorCode?>(
      (_) => null,
      onError: (Object error) => (error as InputSenderException).code,
    );

RemoteDesktopTarget _target() {
  final publicKey = List<int>.generate(32, (index) => index + 1);
  return RemoteDesktopTarget(
    hostIdentity: DeviceIdentity(
      deviceId: deriveDeviceIdV1(publicKey),
      publicKeyAlgorithm: PublicKeyAlgorithm.PUBLIC_KEY_ALGORITHM_ED25519,
      publicKey: publicKey,
      displayName: 'Office Mac',
      platform: DevicePlatform.DEVICE_PLATFORM_MACOS,
    ),
    signalingEndpoint: Uri.parse('wss://signal.example.test/v1/ws'),
  );
}

Widget _app(Widget home, {Locale? locale}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

DiagnosticsReport _diagnosticsReport() => DiagnosticsCollector(
  metadata: const DiagnosticsMetadata(
    appVersion: 'test',
    protocolMajor: 1,
    protocolMinor: 0,
    osFamily: DiagnosticsOsFamily.android,
  ),
  nowUnixMs: () => 1,
).snapshot();
