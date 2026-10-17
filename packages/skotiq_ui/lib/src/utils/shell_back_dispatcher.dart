/// Screen-level interceptors for the Android system back gesture.
///
/// The app shell owns a single `PopScope` (see skotiq_app's
/// `app_shell.dart`) so the back gesture follows one policy: screen
/// interceptor → pop pushed route → return to Dashboard → leave the app.
/// Widgets that keep an internal master/detail or sheet stack (Settings'
/// mobile detail pane, [AdaptivePanelLayout]'s phone bottom sheet) register
/// an interceptor here so back closes their pane instead of leaving the
/// screen.
///
/// Lives in skotiq_ui (framework-free, no Flutter imports) so shared
/// layout widgets can register without depending on the app package.
///
/// Interceptors are consulted LIFO; the first one to return true consumes
/// the event. Registration is idempotent and must be balanced with
/// [ShellBackDispatcher.unregister] (typically initState/dispose).
library;

typedef ShellBackInterceptor = bool Function();

abstract final class ShellBackDispatcher {
  ShellBackDispatcher._();

  static final List<ShellBackInterceptor> _interceptors = [];

  static void register(ShellBackInterceptor interceptor) {
    if (!_interceptors.contains(interceptor)) _interceptors.add(interceptor);
  }

  static void unregister(ShellBackInterceptor interceptor) {
    _interceptors.remove(interceptor);
  }

  /// Returns true if a registered screen consumed the back event.
  static bool dispatch() {
    for (var i = _interceptors.length - 1; i >= 0; i--) {
      if (_interceptors[i]()) return true;
    }
    return false;
  }
}
