import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../utils/adaptive_dialog_constraints.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_decorations.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

/// Size of the optional glyph beside a dialog title, in logical pixels.
///
/// A plain icon, NOT the tinted square the pre-overhaul dialog drew: an icon
/// square beside a 15px title is a badge for a heading that needed no badge.
const double _dialogTitleIconSize = 16;

/// Standard dialog scaffold matching the Skotiq design system.
///
/// Replaces the hand-rolled `Dialog + Container + custom header + close
/// button` pattern duplicated across screens (equipment settings, cooling
/// temperature picker, centering dialog, etc.). Provides consistent corner
/// radius, border, header styling, and a scrollable body.
///
/// The dialog body scrolls vertically when content exceeds available
/// height, so callers can pass arbitrarily tall content without overflow.
///
/// Usage:
/// ```dart
/// showDialog(
///   context: context,
///   builder: (_) => SkotiqDialog(
///     title: 'Equipment Settings',
///     icon: LucideIcons.settings,
///     width: 700,
///     height: 500,
///     child: const EquipmentSettingsTab(),
///     actions: [SkotiqButton(label: 'Save', onPressed: ...)],
///   ),
/// );
/// ```
class SkotiqDialog extends StatelessWidget {
  /// Header title text. Required for accessibility.
  final String title;

  /// Optional leading icon shown before the title.
  final IconData? icon;

  /// Dialog body. Wrapped in a scroll view automatically.
  final Widget child;

  /// Optional footer actions (typically a row of buttons). Rendered with a
  /// top border separator. Layout is right-aligned to match platform
  /// conventions; pass a `Row` if you need custom alignment.
  final List<Widget>? actions;

  /// Optional callback fired when the user closes the dialog via the close
  /// button. If null, the close button just pops the route.
  final VoidCallback? onClose;

  /// Show the close button in the header. Defaults to true.
  final bool showCloseButton;

  /// Whether the dialog may currently be dismissed by the user.
  ///
  /// Set this to false while committing an asynchronous action. It disables
  /// the header close button and blocks modal-barrier and system-back pops, so
  /// a successful write cannot be reported to the caller as a cancellation.
  /// An explicit [NavigatorState.pop] by the dialog's successful action is
  /// still allowed, matching Flutter's [PopScope] contract.
  final bool closeEnabled;

  /// Accessible label for the close button. Defaults to "Close dialog".
  final String closeButtonSemanticsLabel;

  /// Fixed dialog width. Defaults to [widthForm].
  ///
  /// There are three dialog widths and no others: [widthConfirm] for a
  /// question, [widthForm] for a form, [widthWizard] for a multi-step flow.
  final double width;

  /// A confirm or a question — one sentence and two buttons.
  static const double widthConfirm = 480;

  /// A form.
  static const double widthForm = 640;

  /// A wizard or anything with its own internal layout.
  static const double widthWizard = 960;

  /// Fixed dialog height. If null, the dialog sizes to content (capped by
  /// the parent constraints).
  final double? height;

  /// Padding applied around the body content. Defaults to 20px all sides
  /// to match the design doc's dialog scale.
  final EdgeInsets bodyPadding;

  /// When false, suppresses the body's internal scroll view (useful for
  /// content that already provides its own scrolling).
  final bool scrollableBody;

  const SkotiqDialog({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.actions,
    this.onClose,
    this.showCloseButton = true,
    this.closeEnabled = true,
    this.closeButtonSemanticsLabel = 'Close dialog',
    this.width = widthForm,
    this.height,
    this.bodyPadding = const EdgeInsets.symmetric(
      horizontal: SkotiqTokens.space2xl,
    ),
    this.scrollableBody = true,
  });

  @override
  Widget build(BuildContext context) {
    final dialogSize = AdaptiveDialogConstraints.dialogSize(
      context,
      designWidth: width,
      designHeight: height,
    );

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: SkotiqDialogSurface(
        framed: true,
        title: title,
        icon: icon,
        actions: actions,
        onClose: onClose,
        showCloseButton: showCloseButton,
        closeEnabled: closeEnabled,
        closeButtonSemanticsLabel: closeButtonSemanticsLabel,
        width: dialogSize.width,
        height: dialogSize.height,
        bodyPadding: bodyPadding,
        scrollableBody: scrollableBody,
        child: child,
      ),
    );
  }
}

/// [SkotiqDialog]'s chrome — header, scrollable body, footer — WITHOUT the
/// surrounding [Dialog] frame.
///
/// Use this as the body of a modal that already supplies its own frame, above
/// all `showAdaptiveModal`, which wraps its builder in a [Dialog] on
/// tablet/desktop and in a bottom sheet on a phone. Returning a whole
/// [SkotiqDialog] from such a builder nests one dialog inside another: the
/// inner `Dialog`'s `Align` expands to the full viewport height, so the outer
/// dialog's painted surface stretched into a full-height slab with the real
/// card floating in the middle of it.
///
/// Sizing is deliberately caller-owned: leave [width]/[height] null (the
/// default) and the surface wraps its content, letting the enclosing frame
/// decide the width. Pass [framed] `true` only when nothing else is painting
/// the card (this is what [SkotiqDialog] does).
class SkotiqDialogSurface extends StatelessWidget {
  /// Header title text. Required for accessibility.
  final String title;

  /// Optional leading icon shown before the title.
  final IconData? icon;

  /// Body content. Wrapped in a scroll view unless [scrollableBody] is false.
  final Widget child;

  /// Optional footer actions, rendered right-aligned above a top border.
  final List<Widget>? actions;

  /// Fired when the user closes via the header button. Pops the route if null.
  final VoidCallback? onClose;

  /// Show the close button in the header. Defaults to true.
  final bool showCloseButton;

  /// Whether the modal may currently be dismissed. False disables the header
  /// close button and blocks barrier / system-back pops.
  final bool closeEnabled;

  /// Accessible label for the close button.
  final String closeButtonSemanticsLabel;

  /// Explicit width, or null to size to the enclosing frame.
  final double? width;

  /// Explicit height, or null to size to content.
  final double? height;

  /// Padding around the body content.
  final EdgeInsets bodyPadding;

  /// When false, suppresses the body's internal scroll view.
  final bool scrollableBody;

  /// Paint the card background, border, shadow and rounded corners. False (the
  /// default) when an enclosing modal frame already paints them.
  final bool framed;

  const SkotiqDialogSurface({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.actions,
    this.onClose,
    this.showCloseButton = true,
    this.closeEnabled = true,
    this.closeButtonSemanticsLabel = 'Close dialog',
    this.width,
    this.height,
    this.bodyPadding = const EdgeInsets.symmetric(
      horizontal: SkotiqTokens.space2xl,
    ),
    this.scrollableBody = true,
    this.framed = false,
  });

  void _handleClose(BuildContext context) {
    // Caller-provided onClose runs *before* popping so it can decide to
    // keep the dialog open by re-pushing if needed; in practice callers
    // either tear down state and let it pop, or pop themselves and pass a
    // no-op here.
    if (onClose != null) {
      onClose!();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final body = Padding(padding: bodyPadding, child: child);

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Header(
          title: title,
          icon: icon,
          colors: colors,
          showCloseButton: showCloseButton,
          closeEnabled: closeEnabled,
          closeButtonSemanticsLabel: closeButtonSemanticsLabel,
          onClose: () => _handleClose(context),
        ),
        Flexible(
          child: scrollableBody ? SingleChildScrollView(child: body) : body,
        ),
        if (actions != null && actions!.isNotEmpty)
          _Footer(colors: colors, actions: actions!),
      ],
    );

    return PopScope(
      canPop: closeEnabled,
      child: Container(
        width: width,
        height: height,
        decoration: framed ? SkotiqDecorations.dialog(colors) : null,
        child: ClipRRect(
          borderRadius: SkotiqTokens.borderRadiusXl,
          child: column,
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final IconData? icon;
  final SkotiqColors colors;
  final bool showCloseButton;
  final bool closeEnabled;
  final String closeButtonSemanticsLabel;
  final VoidCallback onClose;

  const _Header({
    required this.title,
    required this.icon,
    required this.colors,
    required this.showCloseButton,
    required this.closeEnabled,
    required this.closeButtonSemanticsLabel,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    // No tinted band and no rule under the title: the dialog is ONE surface at
    // 24px padding, and a header stripe would be a second tone inside a
    // container that is already the top of the stack.
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.space2xl,
        SkotiqTokens.space2xl,
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceMd,
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: colors.textMuted, size: _dialogTitleIconSize),
            const SizedBox(width: SkotiqTokens.spaceSm),
          ],
          Expanded(
            // A node of its own, because the title is the one thing in this
            // header that is not a control: with nothing to hold it apart it
            // merges into whichever node is nearest — the close button, or the
            // footer's — and the dialog's name is then readable only as part of
            // a control's name, as one button called "<title> Close dialog".
            child: Semantics(
              container: true,
              child: Text(
                title,
                style: SkotiqTypography.sectionTitle.copyWith(
                  color: colors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (showCloseButton)
            // ONE node for one control. The annotation named the close control
            // and the [IconButton] under it published a second, nameless button
            // as its child, so every dialog in the app — the export sheet, the
            // branch-delete confirm, all of them, since this is the shared
            // chrome — offered assistive tech an anonymous button nested inside
            // "Close dialog". The annotation takes the tap and the state, the
            // button's own node is excluded, and the container keeps the node
            // from swallowing anything beside it.
            Semantics(
              container: true,
              button: true,
              enabled: closeEnabled,
              label: closeButtonSemanticsLabel,
              excludeSemantics: true,
              onTap: closeEnabled ? onClose : null,
              child: IconButton(
                tooltip: closeButtonSemanticsLabel,
                onPressed: closeEnabled ? onClose : null,
                icon: Icon(LucideIcons.x, color: colors.textMuted),
                splashRadius: 18,
              ),
            ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final SkotiqColors colors;
  final List<Widget> actions;

  const _Footer({required this.colors, required this.actions});

  @override
  Widget build(BuildContext context) {
    // Right-aligned with an 8px gap, on the dialog's own surface: the reading
    // order is [ghost Cancel] [secondary alternative] [primary confirm], and
    // the caller supplies them in that order.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.space2xl,
        SkotiqTokens.spaceXl,
        SkotiqTokens.space2xl,
        SkotiqTokens.space2xl,
      ),
      // The footer is a region of its own for the same reason the title is:
      // whatever the header leaves unclaimed lands on the surface node, and
      // with the close button no longer publishing a spare node of its own the
      // first footer action was landing there — the whole dialog then read as
      // one button named after it.
      child: Semantics(
        container: true,
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: SkotiqTokens.spaceSm,
          runSpacing: SkotiqTokens.spaceSm,
          children: actions,
        ),
      ),
    );
  }
}
