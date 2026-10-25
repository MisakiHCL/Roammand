// SPDX-License-Identifier: MPL-2.0

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:roammand/desktop/remote/input_sender.dart';
import 'package:roammand/mobile/remote/mobile_keyboard_controller.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

void main() {
  test(
    'publishes modifier changes asynchronously and closes after clearing',
    () async {
      final fixture = _KeyboardFixture();
      final states = <Set<MobileModifierKey>>[];
      final done = Completer<void>();
      final subscription = fixture.controller.modifierChanges.listen(
        (_) => states.add(
          Set<MobileModifierKey>.of(fixture.controller.activeModifiers),
        ),
        onDone: done.complete,
      );

      final first = fixture.controller.setModifier(
        MobileModifierKey.control,
        true,
      );
      expect(states, isEmpty);
      await first;
      await fixture.controller.setModifier(MobileModifierKey.control, true);
      expect(states, <Set<MobileModifierKey>>[
        <MobileModifierKey>{MobileModifierKey.control},
      ]);
      await fixture.controller.setModifier(MobileModifierKey.control, false);
      await fixture.controller.setModifier(MobileModifierKey.shift, true);
      await fixture.controller.releaseAll();
      await fixture.controller.setModifier(MobileModifierKey.alt, true);
      await fixture.controller.close();
      await done.future;

      expect(states, <Set<MobileModifierKey>>[
        <MobileModifierKey>{MobileModifierKey.control},
        <MobileModifierKey>{},
        <MobileModifierKey>{MobileModifierKey.shift},
        <MobileModifierKey>{},
        <MobileModifierKey>{MobileModifierKey.alt},
        <MobileModifierKey>{},
      ]);
      await subscription.cancel();
    },
  );

  test('a paused modifier listener does not delay input cleanup', () async {
    final fixture = _KeyboardFixture();
    final subscription = fixture.controller.modifierChanges.listen((_) {});
    subscription.pause();
    await fixture.controller.setModifier(MobileModifierKey.control, true);

    await fixture.controller.close();

    expect(fixture.controller.activeModifiers, isEmpty);
    expect(fixture.reliable.decoded.last.hasReleaseAllInput(), isTrue);
    await subscription.cancel();
  });

  test('toggles every supported modifier with exact HID bits', () async {
    final fixture = _KeyboardFixture();

    for (final entry in <(MobileModifierKey, int, int)>[
      (MobileModifierKey.control, 0xe0, 0x01),
      (MobileModifierKey.shift, 0xe1, 0x02),
      (MobileModifierKey.alt, 0xe2, 0x04),
      (MobileModifierKey.command, 0xe3, 0x08),
    ]) {
      await fixture.controller.setModifier(entry.$1, true);
      expect(fixture.controller.isModifierActive(entry.$1), isTrue);
      final down = fixture.reliable.decoded.last.keyboard;
      expect(down.action, KeyboardAction.KEYBOARD_ACTION_DOWN);
      expect(down.usbHidUsage, entry.$2);
      expect(down.modifierBits & entry.$3, entry.$3);
    }

    for (final entry in <(MobileModifierKey, int, int)>[
      (MobileModifierKey.command, 0xe3, 0x08),
      (MobileModifierKey.alt, 0xe2, 0x04),
      (MobileModifierKey.shift, 0xe1, 0x02),
      (MobileModifierKey.control, 0xe0, 0x01),
    ]) {
      await fixture.controller.setModifier(entry.$1, false);
      expect(fixture.controller.isModifierActive(entry.$1), isFalse);
      final up = fixture.reliable.decoded.last.keyboard;
      expect(up.action, KeyboardAction.KEYBOARD_ACTION_UP);
      expect(up.usbHidUsage, entry.$2);
      expect(up.modifierBits & entry.$3, 0);
    }
  });

  test('applies selected modifiers to every supported special key', () async {
    final fixture = _KeyboardFixture();
    await fixture.controller.setModifier(MobileModifierKey.control, true);
    await fixture.controller.setModifier(MobileModifierKey.shift, true);
    fixture.reliable.clear();

    const usages = <MobileSpecialKey, int>{
      MobileSpecialKey.escape: 0x29,
      MobileSpecialKey.tab: 0x2b,
      MobileSpecialKey.arrowRight: 0x4f,
      MobileSpecialKey.arrowLeft: 0x50,
      MobileSpecialKey.arrowDown: 0x51,
      MobileSpecialKey.arrowUp: 0x52,
    };
    for (final entry in usages.entries) {
      await fixture.controller.sendSpecial(entry.key);
    }

    final events = fixture.reliable.decoded;
    expect(events, hasLength(usages.length * 2));
    for (var index = 0; index < usages.length; index += 1) {
      final expectedUsage = usages.values.elementAt(index);
      final down = events[index * 2].keyboard;
      final up = events[index * 2 + 1].keyboard;
      expect(down.action, KeyboardAction.KEYBOARD_ACTION_DOWN);
      expect(up.action, KeyboardAction.KEYBOARD_ACTION_UP);
      expect(down.usbHidUsage, expectedUsage);
      expect(up.usbHidUsage, expectedUsage);
      expect(down.modifierBits, 0x03);
      expect(up.modifierBits, 0x03);
    }
  });

  test('serializes text and key operations in invocation order', () async {
    final reliable = _BlockingInputChannel();
    final controller = _KeyboardFixture(reliable: reliable).controller;

    final first = controller.sendText('first');
    final second = controller.sendSpecial(MobileSpecialKey.tab);
    await Future<void>.delayed(Duration.zero);
    expect(reliable.pendingCount, 1);
    reliable.completeNext();
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(reliable.pendingCount, 1);
    reliable.completeNext();
    await Future<void>.delayed(Duration.zero);
    expect(reliable.pendingCount, 1);
    reliable.completeNext();
    await second;

    final events = reliable.decoded;
    expect(events[0].text.text, 'first');
    expect(events[1].keyboard.action, KeyboardAction.KEYBOARD_ACTION_DOWN);
    expect(events[2].keyboard.action, KeyboardAction.KEYBOARD_ACTION_UP);
  });

  test('close cancels queued input and special-key continuation', () async {
    final reliable = _BlockingInputChannel();
    final controller = _KeyboardFixture(reliable: reliable).controller;
    final special = _keyboardResult(
      controller.sendSpecial(MobileSpecialKey.tab),
    );
    final queued = _keyboardResult(controller.sendText('cancelled'));
    final close = controller.close();
    expect(await special, InputSenderErrorCode.cancelled);
    expect(await queued, InputSenderErrorCode.cancelled);
    expect(reliable.sent, hasLength(1));
    reliable.completeNext();
    await Future<void>.delayed(Duration.zero);
    expect(reliable.sent, hasLength(2));
    expect(reliable.decoded.last.hasReleaseAllInput(), isTrue);
    reliable.completeNext();
    await close;
    expect(reliable.sent, hasLength(2));
  });

  test('release cancels stale input but allows new input afterwards', () async {
    final reliable = _BlockingInputChannel();
    final controller = _KeyboardFixture(reliable: reliable).controller;
    final special = _keyboardResult(
      controller.sendSpecial(MobileSpecialKey.tab),
    );
    final queued = _keyboardResult(controller.sendText('cancelled'));
    final release = controller.releaseAll();
    final fresh = controller.sendText('fresh');
    expect(await special, InputSenderErrorCode.cancelled);
    expect(await queued, InputSenderErrorCode.cancelled);
    reliable.completeNext();
    await Future<void>.delayed(Duration.zero);
    expect(reliable.decoded.last.hasReleaseAllInput(), isTrue);
    reliable.completeNext();
    await release;
    await Future<void>.delayed(Duration.zero);
    expect(reliable.decoded.last.text.text, 'fresh');
    expect(reliable.decoded.map((event) => event.sequence.toInt()), <int>[
      1,
      2,
      3,
    ]);
    reliable.completeNext();
    await fresh;
    final close = controller.close();
    await Future<void>.delayed(Duration.zero);
    reliable.completeNext();
    await close;
  });

  test(
    'gesture release cancels queued keyboard input without ending the session',
    () async {
      final reliable = _BlockingInputChannel();
      var failures = 0;
      final sender = RemoteInputSender(
        sessionId: List.filled(16, 0x63),
        reliable: reliable,
        fast: _RecordingInputChannel(),
        onReliableFailure: () => failures++,
      );
      final controller = MobileKeyboardController(sender);
      final states = <Set<MobileModifierKey>>[];
      final subscription = controller.modifierChanges.listen(
        (_) =>
            states.add(Set<MobileModifierKey>.of(controller.activeModifiers)),
      );
      final modifier = controller.setModifier(MobileModifierKey.control, true);
      reliable.completeNext();
      await modifier;
      final pointer = _keyboardResult(
        sender.sendPointerButton(
          button: PointerButton.POINTER_BUTTON_LEFT,
          action: ButtonAction.BUTTON_ACTION_DOWN,
          x: 100,
          y: 100,
        ),
      );
      final text = _keyboardResult(controller.sendText('cancelled text'));
      final special = _keyboardResult(
        controller.sendSpecial(MobileSpecialKey.tab),
      );
      // Gesture cancellation releases through the shared sender directly.
      final release = _keyboardResult(sender.releaseAll());
      expect(await text, InputSenderErrorCode.cancelled);
      expect(await special, InputSenderErrorCode.cancelled);
      expect(failures, 0);
      expect(controller.activeModifiers, isEmpty);
      expect(states, <Set<MobileModifierKey>>[
        <MobileModifierKey>{MobileModifierKey.control},
        <MobileModifierKey>{},
      ]);
      reliable.completeNext();
      expect(await pointer, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(reliable.decoded.last.hasReleaseAllInput(), isTrue);
      reliable.completeNext();
      expect(await release, isNull);
      final fresh = controller.sendText('fresh input');
      reliable.completeNext();
      await fresh;
      expect(reliable.decoded.map((event) => event.sequence.toInt()), <int>[
        1,
        2,
        3,
        4,
      ]);
      final close = controller.close();
      reliable.completeNext();
      await close;
      await subscription.cancel();
    },
  );

  test(
    'mobile operation budget rejects a flood and ends sender input',
    () async {
      final reliable = _BlockingInputChannel();
      var failures = 0;
      final sender = RemoteInputSender(
        sessionId: List.filled(16, 0x63),
        reliable: reliable,
        fast: _RecordingInputChannel(),
        onReliableFailure: () => failures++,
      );
      final controller = MobileKeyboardController(sender);
      final pending = <Future<InputSenderErrorCode?>>[];
      for (
        var index = 0;
        index <= maxPendingMobileKeyboardOperations;
        index++
      ) {
        pending.add(_keyboardResult(controller.sendText('queued-$index')));
      }
      expect(
        await Future.wait(pending),
        everyElement(InputSenderErrorCode.channel),
      );
      expect(failures, 1);
      expect(reliable.sent, hasLength(1));
      reliable.completeNext();
      await Future<void>.delayed(Duration.zero);
      expect(reliable.sent, hasLength(1));
      await controller.close();
      await sender.close();
    },
  );

  testWidgets('mobile deadline cancels queued work without late key-up', (
    tester,
  ) async {
    final reliable = _BlockingInputChannel();
    var failures = 0;
    final sender = RemoteInputSender(
      sessionId: List.filled(16, 0x63),
      reliable: reliable,
      fast: _RecordingInputChannel(),
      onReliableFailure: () => failures++,
    );
    final controller = MobileKeyboardController(
      sender,
      operationTimeout: const Duration(milliseconds: 30),
    );
    final special = _keyboardResult(
      controller.sendSpecial(MobileSpecialKey.tab),
    );
    final queued = _keyboardResult(controller.sendText('stale'));
    await tester.pump(const Duration(milliseconds: 30));
    expect(await special, InputSenderErrorCode.channel);
    expect(await queued, InputSenderErrorCode.channel);
    expect(failures, 1);
    reliable.completeNext();
    await tester.pump();
    expect(reliable.sent, hasLength(1));
    await controller.close();
    await sender.close();
  });

  test('release clears modifiers and close rejects later input', () async {
    final fixture = _KeyboardFixture();
    await fixture.controller.setModifier(MobileModifierKey.alt, true);
    await fixture.controller.releaseAll();
    await fixture.controller.releaseAll();

    expect(fixture.controller.activeModifiers, isEmpty);
    expect(
      fixture.reliable.decoded.where((event) => event.hasReleaseAllInput()),
      hasLength(1),
    );

    await fixture.controller.close();
    await expectLater(
      fixture.controller.sendText('after-close'),
      throwsA(isA<StateError>()),
    );
  });
}

final class _KeyboardFixture {
  _KeyboardFixture({_RecordingInputChannel? reliable})
    : reliable = reliable ?? _RecordingInputChannel() {
    final sender = RemoteInputSender(
      sessionId: Uint8List.fromList(List<int>.filled(16, 0x63)),
      reliable: this.reliable,
      fast: _RecordingInputChannel(),
      frameScheduler: _NoopFrameScheduler(),
    );
    controller = MobileKeyboardController(sender);
  }

  final _RecordingInputChannel reliable;
  late final MobileKeyboardController controller;
}

class _RecordingInputChannel implements InputDataChannel {
  @override
  int get bufferedAmount => 0;

  final List<Uint8List> sent = <Uint8List>[];

  List<ReliableInputEnvelope> get decoded =>
      sent.map(decodeAndValidateReliableInputEnvelope).toList(growable: false);

  void clear() => sent.clear();

  @override
  Future<void> send(Uint8List bytes) async {
    sent.add(Uint8List.fromList(bytes));
  }
}

final class _BlockingInputChannel extends _RecordingInputChannel {
  final List<Completer<void>> _completions = <Completer<void>>[];

  int get pendingCount => _completions.length;

  @override
  Future<void> send(Uint8List bytes) {
    sent.add(Uint8List.fromList(bytes));
    final completer = Completer<void>();
    _completions.add(completer);
    return completer.future;
  }

  void completeNext() {
    _completions.removeAt(0).complete();
  }
}

final class _NoopFrameScheduler implements InputFrameScheduler {
  @override
  void cancel() {}

  @override
  void schedule(Duration delay, Future<void> Function() callback) {}
}

Future<InputSenderErrorCode?> _keyboardResult(Future<void> operation) =>
    operation.then<InputSenderErrorCode?>(
      (_) => null,
      onError: (Object error) => (error as InputSenderException).code,
    );
