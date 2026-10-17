import 'package:flutter/material.dart';

/// The `position` argument for [showMenu], built from an anchor given in
/// GLOBAL (screen) coordinates.
///
/// ## Why this exists
///
/// `showMenu`'s `position` is a [RelativeRect] whose insets are measured
/// against the enclosing **Navigator's overlay**, not against the screen. In
/// this app those two origins are not the same: every routed screen lives in
/// the nested `Navigator` that go_router's `ShellRoute` hands `AppShell`, and
/// that Navigator's overlay begins at the content edge — below the title bar
/// and to the right of the side navigation rail.
///
/// So a call site that passes a global coordinate straight through adds the
/// overlay's own origin a second time, and the menu opens roughly
/// `(rail width, title-bar height)` away from the thing that was clicked. It
/// is a silent failure: the menu appears, it works, it is simply in the wrong
/// place, and it looks correct in any test that mounts the widget at the window
/// origin. Measured live on the profile list at 1920x1080, collapsing the nav
/// rail by 156 px moved the menu 312 px — twice — because both terms carried
/// the rail width.
///
/// Four separate call sites had this bug and five had hand-rolled the
/// conversion correctly, so the conversion lives here once. Callers supply the
/// anchor geometry they want (over the control, below it, at the cursor); this
/// owns only the coordinate space.
///
/// [context] must be a context inside the route whose Navigator will host the
/// menu — normally the same `context` handed to `showMenu`.
RelativeRect menuPositionFromRect(BuildContext context, Rect globalAnchor) {
  // Navigator.overlay, not Overlay.of: this has to be the overlay `showMenu`
  // will actually push the popup route into, which is the one belonging to the
  // Navigator it resolves. Flutter's own PopupMenuButton looks it up the same
  // way.
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;

  // globalToLocal rather than subtracting the overlay's origin: it also
  // accounts for any transform between the overlay and the screen, so a scaled
  // or offset shell stays correct.
  final anchor = Rect.fromPoints(
    overlay.globalToLocal(globalAnchor.topLeft),
    overlay.globalToLocal(globalAnchor.bottomRight),
  );
  return RelativeRect.fromRect(anchor, Offset.zero & overlay.size);
}

/// [menuPositionFromRect] for a menu opened at a pointer, such as a
/// right-click or a long-press. [globalPoint] is `details.globalPosition`.
RelativeRect menuPositionFromPoint(BuildContext context, Offset globalPoint) =>
    menuPositionFromRect(context, globalPoint & Size.zero);

/// [menuPositionFromRect] anchored on the bounds of the widget that owns
/// [anchorContext] — the control that opened the menu.
///
/// Pass the control's OWN context (a `Builder` or a `GlobalKey` if the control
/// is built inline), not the enclosing widget's: anchoring on an ancestor's box
/// puts the menu against a corner of the whole row.
///
/// Not null-guarded. A control that has just been activated is laid out, and a
/// fallback position here is how a menu ships in the wrong place instead of
/// failing.
RelativeRect menuPositionFromWidget(BuildContext anchorContext) {
  final box = anchorContext.findRenderObject()! as RenderBox;
  return menuPositionFromRect(
    anchorContext,
    box.localToGlobal(Offset.zero) & box.size,
  );
}

/// [menuPositionFromRect] anchored on the BOTTOM edge of the widget that owns
/// [anchorContext], so the menu drops below the control instead of covering
/// it. The usual choice for an overflow or dropdown button in a header or a
/// row, where the control stays visible while its menu is open.
///
/// See [menuPositionFromWidget] for the note on passing the control's own
/// context and on why this does not null-guard.
RelativeRect menuPositionBelowWidget(BuildContext anchorContext) {
  final box = anchorContext.findRenderObject()! as RenderBox;
  return menuPositionFromRect(
    anchorContext,
    Rect.fromPoints(
      box.localToGlobal(Offset(0, box.size.height)),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    ),
  );
}
