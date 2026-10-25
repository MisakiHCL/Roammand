// SPDX-License-Identifier: MPL-2.0

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:roammand/design_system/roammand_text_input.dart';
import 'package:roammand/desktop/remote/input_sender.dart';
import 'package:roammand/l10n/generated/app_localizations.dart';
import 'package:roammand/mobile/remote/mobile_keyboard_controller.dart';

const _trayPadding = 8.0;
const _controlSpacing = 4.0;
const _compactControlHeight = 36.0;

final class MobileInputTray extends StatefulWidget {
  const MobileInputTray({
    required this.controller,
    required this.enabled,
    required this.textFocusNode,
    required this.onDismissKeyboard,
    this.onInputFailure,
    this.padding = const EdgeInsets.all(_trayPadding),
    this.compact = false,
    super.key,
  });

  final MobileKeyboardController? controller;
  final bool enabled;
  final FocusNode textFocusNode;
  final VoidCallback onDismissKeyboard;
  final void Function(Object error)? onInputFailure;
  final EdgeInsetsGeometry padding;
  final bool compact;

  @override
  State<MobileInputTray> createState() => _MobileInputTrayState();
}

final class _MobileInputTrayState extends State<MobileInputTray> {
  final TextEditingController _textController = TextEditingController();
  StreamSubscription<void>? _modifierSubscription;

  @override
  void initState() {
    super.initState();
    _listenToModifiers();
  }

  @override
  void didUpdateWidget(covariant MobileInputTray oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      unawaited(_modifierSubscription?.cancel());
      _listenToModifiers();
    }
  }

  void _listenToModifiers() {
    final controller = widget.controller;
    _modifierSubscription = controller?.modifierChanges.listen((_) {
      if (mounted && identical(controller, widget.controller)) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    unawaited(_modifierSubscription?.cancel());
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SingleChildScrollView(
        padding: widget.padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('mobile-text-input'),
                    controller: _textController,
                    focusNode: widget.textFocusNode,
                    enabled: widget.enabled,
                    cursorOpacityAnimates:
                        RoammandTextInputPolicy.cursorOpacityAnimates,
                    enableIMEPersonalizedLearning:
                        RoammandTextInputPolicy.enableImePersonalizedLearning,
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      labelText: strings.mobileTextInputLabel,
                    ),
                    textInputAction: TextInputAction.send,
                    onTapOutside: (_) => widget.onDismissKeyboard(),
                    onSubmitted: (_) => _sendText(),
                  ),
                ),
                const SizedBox(width: _controlSpacing),
                IconButton.filled(
                  key: const Key('mobile-text-send'),
                  onPressed: widget.enabled ? _sendText : null,
                  tooltip: strings.mobileSendTextAction,
                  icon: const Icon(Icons.send, size: 20),
                ),
              ],
            ),
            if (!widget.compact) ...<Widget>[
              const SizedBox(height: _controlSpacing),
              Wrap(
                spacing: _controlSpacing,
                runSpacing: _controlSpacing,
                children: <Widget>[
                  _modifier(
                    keyName: 'control',
                    modifier: MobileModifierKey.control,
                    label: strings.mobileModifierControl,
                  ),
                  _modifier(
                    keyName: 'shift',
                    modifier: MobileModifierKey.shift,
                    label: strings.mobileModifierShift,
                  ),
                  _modifier(
                    keyName: 'alt',
                    modifier: MobileModifierKey.alt,
                    label: strings.mobileModifierAlt,
                  ),
                  _modifier(
                    keyName: 'command',
                    modifier: MobileModifierKey.command,
                    label: strings.mobileModifierCommand,
                  ),
                ],
              ),
              const SizedBox(height: _controlSpacing),
              Wrap(
                spacing: _controlSpacing,
                runSpacing: _controlSpacing,
                children: <Widget>[
                  _special(
                    keyName: 'escape',
                    special: MobileSpecialKey.escape,
                    label: strings.mobileKeyEscape,
                  ),
                  _special(
                    keyName: 'tab',
                    special: MobileSpecialKey.tab,
                    label: strings.mobileKeyTab,
                  ),
                  _special(
                    keyName: 'arrow-left',
                    special: MobileSpecialKey.arrowLeft,
                    label: strings.mobileKeyArrowLeft,
                    icon: Icons.arrow_back,
                  ),
                  _special(
                    keyName: 'arrow-up',
                    special: MobileSpecialKey.arrowUp,
                    label: strings.mobileKeyArrowUp,
                    icon: Icons.arrow_upward,
                  ),
                  _special(
                    keyName: 'arrow-right',
                    special: MobileSpecialKey.arrowRight,
                    label: strings.mobileKeyArrowRight,
                    icon: Icons.arrow_forward,
                  ),
                  _special(
                    keyName: 'arrow-down',
                    special: MobileSpecialKey.arrowDown,
                    label: strings.mobileKeyArrowDown,
                    icon: Icons.arrow_downward,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _modifier({
    required String keyName,
    required MobileModifierKey modifier,
    required String label,
  }) {
    final controller = widget.controller;
    final selected = controller?.isModifierActive(modifier) ?? false;
    return FilterChip(
      key: Key('mobile-modifier-$keyName'),
      label: Text(label),
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      selected: selected,
      onSelected: widget.enabled && controller != null
          ? (active) {
              final operation = controller.setModifier(modifier, active);
              _guard(operation);
            }
          : null,
    );
  }

  Widget _special({
    required String keyName,
    required MobileSpecialKey special,
    required String label,
    IconData? icon,
  }) => OutlinedButton.icon(
    key: Key('mobile-special-$keyName'),
    onPressed: widget.enabled && widget.controller != null
        ? () => _guard(widget.controller!.sendSpecial(special))
        : null,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(0, _compactControlHeight),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    ),
    icon: Icon(icon ?? Icons.keyboard, size: 16),
    label: Text(label),
  );

  void _sendText() {
    final controller = widget.controller;
    final text = _textController.text;
    if (!widget.enabled || controller == null || text.isEmpty) return;
    final operation = controller.sendText(text).then((_) {
      if (mounted && _textController.text == text) {
        _textController.clear();
      }
    });
    _guard(operation);
  }

  void _guard(Future<void> operation) {
    unawaited(
      operation.catchError((Object error) {
        if (error is InputSenderException &&
            error.code == InputSenderErrorCode.cancelled) {
          return;
        }
        widget.onInputFailure?.call(error);
      }),
    );
  }
}
