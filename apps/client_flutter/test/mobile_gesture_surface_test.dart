// SPDX-License-Identifier: MPL-2.0

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roammand/desktop/remote/input_sender.dart';
import 'package:roammand/mobile/remote/mobile_gesture_surface.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

void main() {
  testWidgets('pointer cancellation falls back to releasing the sender', (
    tester,
  ) async {
    final fixture = _SurfaceFixture();
    await tester.pumpWidget(fixture.app());
    await fixture.sender.sendKeyboard(
      action: KeyboardAction.KEYBOARD_ACTION_DOWN,
      usbHidUsage: 0xe0,
      modifierBits: 1,
    );
    final finger = await tester.startGesture(tester.getCenter(fixture.surface));
    await finger.cancel();
    await tester.pump();

    expect(
      fixture.reliableEvents.where((event) => event.hasReleaseAllInput()),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('owner cancellation suppresses its release callback', (
    tester,
  ) async {
    final fixture = _SurfaceFixture();
    final controller = MobileGestureSurfaceController();
    var releases = 0;
    await tester.pumpWidget(
      fixture.app(
        controller: controller,
        releaseInput: () async {
          releases++;
        },
      ),
    );
    final first = await tester.startGesture(tester.getCenter(fixture.surface));
    controller.cancel(releaseInput: false);
    await first.up();
    await tester.pump();
    expect(releases, 0);

    final second = await tester.startGesture(tester.getCenter(fixture.surface));
    controller.cancel();
    await second.up();
    await tester.pump();
    expect(releases, 1);
    expect(fixture.reliableEvents, isEmpty);
  });

  testWidgets('maps double tap to one reliable double-click', (tester) async {
    final fixture = _SurfaceFixture();
    await tester.pumpWidget(fixture.app());
    final center = tester.getCenter(fixture.surface);

    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(center + const Offset(4, 4));
    await tester.pump(const Duration(milliseconds: 301));

    final buttons = fixture.reliableEvents
        .where((event) => event.hasPointerButton())
        .toList(growable: false);
    expect(buttons, hasLength(1));
    expect(
      buttons.single.pointerButton.action,
      ButtonAction.BUTTON_ACTION_DOUBLE_CLICK,
    );
  });

  testWidgets('maps long press movement to down move and up', (tester) async {
    final fixture = _SurfaceFixture();
    await tester.pumpWidget(fixture.app());
    final center = tester.getCenter(fixture.surface);
    final finger = await tester.startGesture(center, pointer: 1);

    await tester.pump(const Duration(milliseconds: 501));
    await finger.moveBy(const Offset(24, 12));
    await tester.pump(pointerFrameInterval);
    await finger.up();
    await tester.pump();

    final buttons = fixture.reliableEvents
        .where((event) => event.hasPointerButton())
        .map((event) => event.pointerButton.action)
        .toList(growable: false);
    expect(buttons, <ButtonAction>[
      ButtonAction.BUTTON_ACTION_DOWN,
      ButtonAction.BUTTON_ACTION_UP,
    ]);
    final moves = fixture.fastEvents
        .where((event) => event.hasMove())
        .toList(growable: false);
    expect(moves, hasLength(1));
    expect(moves.single.move.pressedButtonBits, 1);
  });

  testWidgets('maps a two-finger tap to one right-click', (tester) async {
    final fixture = _SurfaceFixture();
    await tester.pumpWidget(fixture.app());
    final center = tester.getCenter(fixture.surface);
    final first = await tester.startGesture(
      center - const Offset(20, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      center + const Offset(20, 0),
      pointer: 2,
    );

    await tester.pump(const Duration(milliseconds: 80));
    await first.up();
    await second.up();
    await tester.pump();

    final buttons = fixture.reliableEvents
        .where((event) => event.hasPointerButton())
        .toList(growable: false);
    expect(buttons, hasLength(1));
    expect(
      buttons.single.pointerButton.button,
      PointerButton.POINTER_BUTTON_RIGHT,
    );
    expect(
      buttons.single.pointerButton.action,
      ButtonAction.BUTTON_ACTION_CLICK,
    );
  });

  testWidgets('maps two-finger translation only to fast scroll', (
    tester,
  ) async {
    final fixture = _SurfaceFixture();
    await tester.pumpWidget(fixture.app());
    final center = tester.getCenter(fixture.surface);
    final first = await tester.startGesture(
      center - const Offset(20, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      center + const Offset(20, 0),
      pointer: 2,
    );

    await first.moveBy(const Offset(0, 24));
    await second.moveBy(const Offset(0, 24));
    await first.up();
    await second.up();
    await tester.pump();

    expect(fixture.reliableEvents, isEmpty);
    final scrolls = fixture.fastEvents
        .where((event) => event.hasScroll())
        .toList(growable: false);
    expect(scrolls, isNotEmpty);
    expect(scrolls.every((event) => event.scroll.deltaY < 0), isTrue);
  });

  testWidgets('pinch changes only the local video viewport', (tester) async {
    final fixture = _SurfaceFixture();
    await tester.pumpWidget(fixture.app());
    final initialWidth = tester.getSize(fixture.video).width;
    final center = tester.getCenter(fixture.surface);
    final first = await tester.startGesture(
      center - const Offset(20, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      center + const Offset(20, 0),
      pointer: 2,
    );

    await first.moveBy(const Offset(-30, 0));
    await second.moveBy(const Offset(30, 0));
    await tester.pump();
    final zoomedWidth = tester.getSize(fixture.video).width;
    await first.up();
    await second.up();
    await tester.pump();

    expect(zoomedWidth, greaterThan(initialWidth));
    expect(fixture.reliableEvents, isEmpty);
    expect(fixture.fastEvents, isEmpty);
  });

  testWidgets('closed sender reports failure without an uncaught exception', (
    tester,
  ) async {
    final fixture = _SurfaceFixture();
    final failures = <Object>[];
    await tester.pumpWidget(fixture.app(onInputFailure: failures.add));
    await fixture.sender.close();

    await tester.tapAt(tester.getCenter(fixture.surface));
    await tester.pump(const Duration(milliseconds: 301));

    expect(failures, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}

final class _SurfaceFixture {
  _SurfaceFixture() : reliable = _CaptureChannel(), fast = _CaptureChannel() {
    sender = RemoteInputSender(
      sessionId: List<int>.filled(16, 0x35),
      reliable: reliable,
      fast: fast,
    );
  }

  final _CaptureChannel reliable;
  final _CaptureChannel fast;
  late final RemoteInputSender sender;

  Finder get surface => find.byKey(const Key('mobile-remote-gesture-surface'));
  Finder get video => find.byKey(const Key('test-mobile-video'));

  List<ReliableInputEnvelope> get reliableEvents => reliable.sent
      .map(decodeAndValidateReliableInputEnvelope)
      .toList(growable: false);

  List<PointerFastEnvelope> get fastEvents => fast.sent
      .map(decodeAndValidatePointerFastEnvelope)
      .toList(growable: false);

  Widget app({
    void Function(Object error)? onInputFailure,
    MobileGestureSurfaceController? controller,
    Future<void> Function()? releaseInput,
  }) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox.square(
          dimension: 400,
          child: MobileGestureSurface(
            sender: sender,
            controller: controller,
            releaseInput: releaseInput,
            onInputFailure: onInputFailure,
            videoAspectRatio: 1,
            video: const ColoredBox(
              key: Key('test-mobile-video'),
              color: Colors.blue,
            ),
          ),
        ),
      ),
    ),
  );
}

final class _CaptureChannel implements InputDataChannel {
  final List<Uint8List> sent = <Uint8List>[];

  @override
  int get bufferedAmount => 0;

  @override
  Future<void> send(Uint8List bytes) async {
    sent.add(Uint8List.fromList(bytes));
  }
}
