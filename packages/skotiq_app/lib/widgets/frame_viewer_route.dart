import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Opens a full-window frame viewer over the whole app (the root navigator),
/// faded in, as an opaque page.
///
/// The page's focus is cleared first: coming back restores the focus the page
/// had, and a field still focused from an earlier edit would then reopen a
/// phone's keyboard over the screen the operator returned to.
Future<void> pushFrameViewer(
  BuildContext context, {
  required WidgetBuilder builder,
  required Duration transitionDuration,
  Color? barrierColor,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque: true,
      barrierColor: barrierColor,
      transitionDuration: transitionDuration,
      pageBuilder: (context, _, __) => builder(context),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// The keys every frame viewer answers: Escape closes it (an opaque
/// full-window page has no barrier to click away), plus the viewer's own.
class FrameViewerKeys extends StatelessWidget {
  const FrameViewerKeys({
    super.key,
    required this.child,
    this.bindings = const {},
  });

  final Widget child;
  final Map<ShortcutActivator, VoidCallback> bindings;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).maybePop(),
          ...bindings,
        },
        child: Focus(autofocus: true, child: child),
      );
}
