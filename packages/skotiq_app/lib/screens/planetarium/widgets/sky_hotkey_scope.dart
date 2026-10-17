import 'package:flutter/widgets.dart';

/// Whether the caret currently sits in a text field.
///
/// The primary focus node of a `TextField` belongs to the `Focus` that
/// [EditableText] builds *inside* itself, so the node's own context widget is
/// that `Focus` — not the [EditableText]. Walking up to [EditableTextState] is
/// what actually identifies a text input, and it covers every widget built on
/// [EditableText] (TextField, TextFormField, CupertinoTextField, the search
/// fields in the plan panel).
bool textInputHasPrimaryFocus() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.findAncestorStateOfType<EditableTextState>() != null;
}

/// Hosts the planetarium's view hotkeys and refuses to consume a key while a
/// text field owns the caret.
///
/// The sky's shortcuts are BARE letters (c/e/f/g/h/m/n/r) and this scope sits
/// above the whole screen — including the plan panel's "Search objects" field.
/// A [KeyEvent] that an ancestor reports as [KeyEventResult.handled] never
/// reaches the platform text-input path, so typing "Vega" into search left
/// "Va" behind while switching on the ecliptic ('e') and the RA/Dec grid ('g'),
/// and the whole alphabet came out as "abd". Naming a target is the primary way
/// into this screen, so ordinary characters belong to whoever owns the caret —
/// unconditionally, for every key, since a focused field also owns the arrows,
/// Home/End and the +/- keys the sky binds to zoom.
class SkyHotkeyScope extends StatefulWidget {
  const SkyHotkeyScope({
    super.key,
    required this.onHotkey,
    required this.child,
  });

  /// Invoked only when no text field holds focus.
  final KeyEventResult Function(FocusNode node, KeyEvent event) onHotkey;

  final Widget child;

  @override
  State<SkyHotkeyScope> createState() => _SkyHotkeyScopeState();
}

class _SkyHotkeyScopeState extends State<SkyHotkeyScope> {
  final _node = FocusNode(debugLabel: 'SkyHotkeyScope');

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  /// Take the keyboard back once a text field has let go of it.
  ///
  /// A field that loses focus to a tap on the sky hands the keyboard to its
  /// enclosing scope, not back to us — which would leave the screen deaf to
  /// every shortcut until something else focused. Only claim when nothing owns
  /// the caret (primary focus is a bare scope): a tap that lands ON a field
  /// focuses it after this fires, so the field still wins.
  void _reclaimIfUnowned(PointerUpEvent _) {
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary is! FocusScopeNode) return;
    _node.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (textInputHasPrimaryFocus()) return KeyEventResult.ignored;
        return widget.onHotkey(node, event);
      },
      child: Listener(
        onPointerUp: _reclaimIfUnowned,
        child: widget.child,
      ),
    );
  }
}
