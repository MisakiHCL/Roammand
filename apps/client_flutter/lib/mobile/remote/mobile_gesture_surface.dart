// SPDX-License-Identifier: MPL-2.0

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:roammand/desktop/remote/input_sender.dart';
import 'package:roammand/mobile/remote/mobile_gesture_machine.dart';
import 'package:roammand/mobile/remote/mobile_viewport.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

const _leftButtonBits = 1;

typedef MobileInputFailureCallback = void Function(Object error);

final class MobileGestureSurfaceController {
  void Function(bool releaseInput)? _cancel;

  void cancel({bool releaseInput = true}) => _cancel?.call(releaseInput);

  void _attach(void Function(bool releaseInput) cancel) => _cancel = cancel;

  void _detach(void Function(bool releaseInput) cancel) {
    if (_cancel == cancel) {
      _cancel = null;
    }
  }
}

final class MobileGestureSurface extends StatefulWidget {
  const MobileGestureSurface({
    required this.video,
    required this.videoAspectRatio,
    this.sender,
    this.controller,
    this.releaseInput,
    this.initialScale = mobileViewportDefaultScale,
    this.initialObscuredInsets,
    this.scheduler = const TimerMobileGestureScheduler(),
    this.onInputFailure,
    super.key,
  });

  final Widget video;
  final double videoAspectRatio;
  final RemoteInputSender? sender;
  final MobileGestureSurfaceController? controller;
  final Future<void> Function()? releaseInput;
  final double initialScale;
  final EdgeInsets? initialObscuredInsets;
  final MobileGestureScheduler scheduler;
  final MobileInputFailureCallback? onInputFailure;

  @override
  State<MobileGestureSurface> createState() => _MobileGestureSurfaceState();
}

final class _MobileGestureSurfaceState extends State<MobileGestureSurface> {
  late final MobileGestureMachine _gestureMachine;
  MobileViewport? _viewport;
  MobileRemotePosition? _lastDragPosition;
  MobileRemotePosition? _zoomAnchor;
  double _zoomStartScale = mobileViewportMinimumScale;
  bool _dragActive = false;
  bool _viewportAdjusted = false;
  bool _suppressInputRelease = false;

  @override
  void initState() {
    super.initState();
    _gestureMachine = MobileGestureMachine(
      scheduler: widget.scheduler,
      onAction: _handleAction,
    );
    widget.controller?._attach(_cancel);
  }

  @override
  void didUpdateWidget(MobileGestureSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(_cancel);
      widget.controller?._attach(_cancel);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(_cancel);
    _gestureMachine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      if (size.width <= 0 || size.height <= 0) {
        return const ColoredBox(color: Colors.black);
      }
      final viewport = _viewport;
      final layoutChanged =
          viewport == null ||
          viewport.viewportSize != size ||
          viewport.videoAspectRatio != widget.videoAspectRatio;
      _viewport = viewport == null || (!_viewportAdjusted && layoutChanged)
          ? MobileViewport.initial(
              viewportSize: size,
              videoAspectRatio: widget.videoAspectRatio,
              initialScale: _resolvedInitialScale(size),
            )
          : viewport.withLayout(
              viewportSize: size,
              videoAspectRatio: widget.videoAspectRatio,
            );
      final videoRect = _viewport!.videoRect;
      return ColoredBox(
        color: Colors.black,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: <Widget>[
            Positioned.fromRect(
              rect: videoRect,
              child: IgnorePointer(child: widget.video),
            ),
            Positioned.fill(
              child: Listener(
                key: const Key('mobile-remote-gesture-surface'),
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) => _gestureMachine.pointerDown(
                  pointer: event.pointer,
                  position: event.localPosition,
                  timeStamp: event.timeStamp,
                ),
                onPointerMove: (event) => _gestureMachine.pointerMove(
                  pointer: event.pointer,
                  position: event.localPosition,
                  timeStamp: event.timeStamp,
                ),
                onPointerUp: (event) => _gestureMachine.pointerUp(
                  pointer: event.pointer,
                  position: event.localPosition,
                  timeStamp: event.timeStamp,
                ),
                onPointerCancel: (event) =>
                    _gestureMachine.pointerCancel(event.pointer),
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      );
    },
  );

  void _handleAction(MobileGestureAction action) {
    switch (action) {
      case MobileClickAction():
        _click(action);
      case MobileDragAction():
        _drag(action);
      case MobileScrollAction():
        _scroll(action);
      case MobileZoomAction():
        _zoom(action);
      case MobileReleaseAction():
        _releaseRemoteInput();
    }
  }

  void _click(MobileClickAction action) {
    final sender = widget.sender;
    final position = _viewport?.mapLocalToRemote(action.position);
    if (sender == null || position == null) {
      return;
    }
    final (button, buttonAction) = switch (action.kind) {
      MobileClickKind.leftClick => (
        PointerButton.POINTER_BUTTON_LEFT,
        ButtonAction.BUTTON_ACTION_CLICK,
      ),
      MobileClickKind.leftDoubleClick => (
        PointerButton.POINTER_BUTTON_LEFT,
        ButtonAction.BUTTON_ACTION_DOUBLE_CLICK,
      ),
      MobileClickKind.rightClick => (
        PointerButton.POINTER_BUTTON_RIGHT,
        ButtonAction.BUTTON_ACTION_CLICK,
      ),
    };
    _guard(
      () => sender.sendPointerClick(
        button: button,
        action: buttonAction,
        x: position.x,
        y: position.y,
      ),
    );
  }

  void _drag(MobileDragAction action) {
    final sender = widget.sender;
    final mapped = _viewport?.mapLocalToRemote(action.position);
    if (sender == null) {
      return;
    }
    switch (action.phase) {
      case MobileDragPhase.down:
        if (mapped == null) return;
        _dragActive = true;
        _lastDragPosition = mapped;
        _guard(
          () => sender.sendPointerButton(
            button: PointerButton.POINTER_BUTTON_LEFT,
            action: ButtonAction.BUTTON_ACTION_DOWN,
            x: mapped.x,
            y: mapped.y,
          ),
        );
      case MobileDragPhase.move:
        if (!_dragActive || mapped == null) return;
        _lastDragPosition = mapped;
        _guardVoid(
          () => sender.queuePointerMove(
            x: mapped.x,
            y: mapped.y,
            pressedButtonBits: _leftButtonBits,
          ),
        );
      case MobileDragPhase.up:
        final position = mapped ?? _lastDragPosition;
        if (!_dragActive || position == null) return;
        _dragActive = false;
        _lastDragPosition = null;
        _guard(
          () => sender.sendPointerButton(
            button: PointerButton.POINTER_BUTTON_LEFT,
            action: ButtonAction.BUTTON_ACTION_UP,
            x: position.x,
            y: position.y,
          ),
        );
    }
  }

  void _scroll(MobileScrollAction action) {
    final sender = widget.sender;
    if (sender == null) return;
    final deltaX = (-action.delta.dx).round().clamp(
      -maxRemoteScrollDelta,
      maxRemoteScrollDelta,
    );
    final deltaY = (-action.delta.dy).round().clamp(
      -maxRemoteScrollDelta,
      maxRemoteScrollDelta,
    );
    if (deltaX == 0 && deltaY == 0) return;
    _guard(() => sender.sendScroll(deltaX: deltaX, deltaY: deltaY));
  }

  void _zoom(MobileZoomAction action) {
    final viewport = _viewport;
    if (viewport == null) return;
    switch (action.phase) {
      case MobileZoomPhase.start:
        _zoomStartScale = viewport.scale;
        _zoomAnchor = viewport.mapLocalToRemote(action.focalPoint);
      case MobileZoomPhase.update:
        final anchor = _zoomAnchor;
        if (anchor == null) return;
        setState(() {
          _viewportAdjusted = true;
          _viewport = viewport.zoomFromAnchor(
            scale: _zoomStartScale * action.scale,
            focalPoint: action.focalPoint,
            anchor: anchor,
          );
        });
      case MobileZoomPhase.end:
        _zoomAnchor = null;
    }
  }

  double _resolvedInitialScale(Size viewportSize) {
    final obscuredInsets = widget.initialObscuredInsets;
    if (obscuredInsets == null) {
      return widget.initialScale;
    }
    return mobileViewportSafeFitScale(
      viewportSize: viewportSize,
      videoAspectRatio: widget.videoAspectRatio,
      obscuredInsets: obscuredInsets,
    );
  }

  void _cancel(bool releaseInput) {
    _suppressInputRelease = !releaseInput;
    try {
      _gestureMachine.cancel();
    } finally {
      _suppressInputRelease = false;
    }
  }

  void _releaseRemoteInput() {
    _dragActive = false;
    _lastDragPosition = null;
    if (_suppressInputRelease) return;
    final release = widget.releaseInput ?? widget.sender?.releaseAll;
    if (release != null) {
      _guard(release);
    }
  }

  void _guard(Future<void> Function() operation) {
    try {
      unawaited(operation().catchError(_reportInputFailure));
    } catch (error) {
      _reportInputFailure(error);
    }
  }

  void _guardVoid(void Function() operation) {
    try {
      operation();
    } catch (error) {
      _reportInputFailure(error);
    }
  }

  void _reportInputFailure(Object error) => widget.onInputFailure?.call(error);
}
