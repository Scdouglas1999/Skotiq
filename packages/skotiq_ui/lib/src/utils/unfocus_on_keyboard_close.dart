import 'package:flutter/widgets.dart';

import 'platform_shortcuts.dart' show platformExpectsKeyboard;

/// Ends text editing when the soft keyboard closes on its own (the Back
/// button, the keyboard's hide key). Flutter keeps the field focused with
/// its caret blinking, so the value stays mid-edit and the next tap
/// elsewhere reopens the keyboard.
class UnfocusOnKeyboardClose extends StatefulWidget {
  const UnfocusOnKeyboardClose({super.key, required this.child});

  final Widget child;

  @override
  State<UnfocusOnKeyboardClose> createState() => _UnfocusOnKeyboardCloseState();
}

class _UnfocusOnKeyboardCloseState extends State<UnfocusOnKeyboardClose>
    with WidgetsBindingObserver {
  double _lastInset = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final inset = views.first.viewInsets.bottom;
    final closed = _lastInset > 0 && inset == 0;
    _lastInset = inset;
    if (!closed) return;
    final focused = FocusManager.instance.primaryFocus;
    final editing =
        focused?.context?.findAncestorStateOfType<EditableTextState>() != null;
    if (editing) focused!.unfocus();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// On a phone or tablet, ends text editing when a dialog or sheet opens over
/// a focused field. Flutter gives focus back to the field when the dialog
/// closes, and with it the soft keyboard the operator had put away (mobile
/// rework P2-45). A desktop keeps the restore: a keyboard user expects to
/// land where they were.
class UnfocusTextOnPopupObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is! PopupRoute || platformExpectsKeyboard()) return;
    final focused = FocusManager.instance.primaryFocus;
    final editing =
        focused?.context?.findAncestorStateOfType<EditableTextState>() != null;
    if (editing) focused!.unfocus();
  }
}
