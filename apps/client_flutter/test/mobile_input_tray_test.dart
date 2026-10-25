// SPDX-License-Identifier: MPL-2.0

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roammand/desktop/remote/input_sender.dart';
import 'package:roammand/l10n/generated/app_localizations.dart';
import 'package:roammand/mobile/remote/mobile_input_tray.dart';
import 'package:roammand/mobile/remote/mobile_keyboard_controller.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

void main() {
  testWidgets('gesture cancellation clears the chip and lets it press again', (
    tester,
  ) async {
    final fixture = _TrayFixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app());
    await tester.tap(_controlChip);
    await tester.pump();
    expect(tester.widget<FilterChip>(_controlChip).selected, isTrue);

    final gate = Completer<void>();
    fixture.reliable.nextSendGate = gate;
    final pointer = fixture.sender.sendPointerButton(
      button: PointerButton.POINTER_BUTTON_LEFT,
      action: ButtonAction.BUTTON_ACTION_DOWN,
      x: 100,
      y: 100,
    );
    final text = fixture.controller.sendText('queued').catchError((_) {});
    final release = fixture.sender.releaseAll();
    await tester.pump();
    expect(fixture.controller.activeModifiers, isEmpty);

    gate.complete();
    await tester.pump();
    await Future.wait(<Future<void>>[pointer, text, release]);
    expect(tester.widget<FilterChip>(_controlChip).selected, isFalse);

    final before = fixture.reliable.modifierDownCount;
    await tester.tap(_controlChip);
    await tester.pump();
    expect(fixture.reliable.modifierDownCount, before + 1);
    expect(tester.widget<FilterChip>(_controlChip).selected, isTrue);
  });

  testWidgets('external release and close repaint selected modifiers', (
    tester,
  ) async {
    final fixture = _TrayFixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app());

    await fixture.controller.setModifier(MobileModifierKey.control, true);
    await tester.pump();
    expect(tester.widget<FilterChip>(_controlChip).selected, isTrue);
    await fixture.controller.releaseAll();
    await tester.pump();
    expect(tester.widget<FilterChip>(_controlChip).selected, isFalse);

    await fixture.controller.setModifier(MobileModifierKey.control, true);
    await tester.pump();
    expect(tester.widget<FilterChip>(_controlChip).selected, isTrue);
    await fixture.controller.close();
    await tester.pump();
    expect(tester.widget<FilterChip>(_controlChip).selected, isFalse);
  });

  testWidgets('a failed keyboard operation clears the modifier chip', (
    tester,
  ) async {
    final fixture = _TrayFixture();
    addTearDown(fixture.dispose);
    final notificationsDone = fixture.controller.modifierChanges.drain<void>();
    await tester.pumpWidget(fixture.app());
    await tester.tap(_controlChip);
    await tester.pump();
    expect(tester.widget<FilterChip>(_controlChip).selected, isTrue);

    fixture.reliable.nextSendError = StateError('channel failed');
    await expectLater(
      fixture.controller.sendText('fails'),
      throwsA(isA<InputSenderException>()),
    );
    await notificationsDone;
    await tester.pump();
    expect(tester.widget<FilterChip>(_controlChip).selected, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacement and unmount detach pending controller changes', (
    tester,
  ) async {
    final previous = _TrayFixture();
    final current = _TrayFixture();
    addTearDown(previous.dispose);
    addTearDown(current.dispose);
    await tester.pumpWidget(previous.app());
    await tester.tap(_controlChip);
    await tester.pump();
    expect(tester.widget<FilterChip>(_controlChip).selected, isTrue);

    final oldRelease = previous.controller.releaseAll();
    await tester.pumpWidget(previous.app(controller: current.controller));
    await oldRelease;
    expect(tester.widget<FilterChip>(_controlChip).selected, isFalse);
    await previous.controller.close();
    await current.controller.setModifier(MobileModifierKey.control, true);
    await tester.pump();
    expect(tester.widget<FilterChip>(_controlChip).selected, isTrue);

    final release = current.controller.releaseAll();
    await tester.pumpWidget(const SizedBox.shrink());
    await release;
    await current.controller.close();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing during layout defers the modifier repaint safely', (
    tester,
  ) async {
    final fixture = _TrayFixture();
    addTearDown(fixture.dispose);
    await fixture.controller.setModifier(MobileModifierKey.control, true);
    await tester.pumpWidget(
      fixture.app(layoutCallback: () => unawaited(fixture.controller.close())),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.widget<FilterChip>(_controlChip).selected, isFalse);
  });
}

final _controlChip = find.byKey(const Key('mobile-modifier-control'));

final class _TrayFixture {
  _TrayFixture() {
    sender = RemoteInputSender(
      sessionId: List<int>.filled(16, 0x63),
      reliable: reliable,
      fast: _RecordingInputChannel(),
    );
    controller = MobileKeyboardController(sender);
  }

  final reliable = _RecordingInputChannel();
  final focus = FocusNode();
  late final RemoteInputSender sender;
  late final MobileKeyboardController controller;

  Widget app({
    MobileKeyboardController? controller,
    VoidCallback? layoutCallback,
  }) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Column(
        children: <Widget>[
          MobileInputTray(
            controller: controller ?? this.controller,
            enabled: true,
            textFocusNode: focus,
            onDismissKeyboard: () {},
          ),
          if (layoutCallback != null)
            LayoutBuilder(
              builder: (_, _) {
                layoutCallback();
                return const SizedBox.shrink();
              },
            ),
        ],
      ),
    ),
  );

  void dispose() {
    focus.dispose();
    unawaited(controller.close());
    sender.abort();
  }
}

final class _RecordingInputChannel implements InputDataChannel {
  final sent = <Uint8List>[];
  Completer<void>? nextSendGate;
  Object? nextSendError;

  int get modifierDownCount => sent
      .map(decodeAndValidateReliableInputEnvelope)
      .where(
        (event) =>
            event.hasKeyboard() &&
            event.keyboard.usbHidUsage == 0xe0 &&
            event.keyboard.action == KeyboardAction.KEYBOARD_ACTION_DOWN,
      )
      .length;

  @override
  int get bufferedAmount => 0;

  @override
  Future<void> send(Uint8List bytes) {
    sent.add(Uint8List.fromList(bytes));
    final gate = nextSendGate;
    nextSendGate = null;
    final error = nextSendError;
    nextSendError = null;
    if (error != null) return Future<void>.error(error);
    return gate?.future ?? Future<void>.value();
  }
}
