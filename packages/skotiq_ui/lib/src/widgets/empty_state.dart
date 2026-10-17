import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

/// The ONE empty-state pattern: a 28px muted glyph, a title, one sentence and
/// one button, centred in whatever container it was given.
///
/// Padding is internal and fixed — 24 all round, 16 in [EmptyState.compact] —
/// because an empty state that each screen pads differently stops being one
/// pattern. No panel is drawn around it either: the surrounding layout already
/// is one.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;
  final EdgeInsets _padding;
  final double _iconTitleGap;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.action,
  }) : _padding = const EdgeInsets.all(SkotiqTokens.space2xl),
       _iconTitleGap = iconTitleGap;

  /// Tighter variant for side panels and embedded slots.
  const EmptyState.compact({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.action,
  }) : _padding = const EdgeInsets.all(SkotiqTokens.spaceLg),
       _iconTitleGap = iconTitleGap;

  /// The glyph size in logical pixels.
  static const double iconSize = 28;

  /// Gap between the icon and the title.
  static const double iconTitleGap = 6;

  /// Gap between the title and the body.
  static const double titleBodyGap = SkotiqTokens.spaceXs;

  /// Gap between the body and the button.
  static const double actionGap = 10;

  /// The widest an empty state gets, so its sentence never runs past two lines.
  static const double maxWidth = 360;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Padding(
      padding: _padding,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: iconSize, color: colors.textMuted),
              SizedBox(height: _iconTitleGap),
              Text(
                title,
                style: SkotiqTypography.sectionTitle.copyWith(
                  color: colors.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              if (body != null) ...<Widget>[
                const SizedBox(height: titleBodyGap),
                Text(
                  body!,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              if (action != null) ...<Widget>[
                const SizedBox(height: actionGap),
                // The action is a node of its own.
                //
                // A screen with a keyboard shortcut has a focusable ancestor
                // over everything on it — `CallbackShortcuts` builds a `Focus`,
                // and a `Focus` publishes `focusable` unless told not to — and
                // that one annotated node absorbs every descendant fragment
                // that is not bounded. An empty state is several paragraphs
                // around ONE interactive descendant, so the tap and the role of
                // that one control merged into the same node as all the words:
                // the Darkroom's "Nothing to open" state reached AT-SPI as a
                // single ~300-character button whose name was the screen title,
                // the reason, and this label twice over. There was no node
                // named for the action, so an exact-name lookup failed, and an
                // activation landed on a node whose extents were the whole
                // screen. States with two or more actions escaped it only
                // because two taps cannot merge into one node.
                //
                // The boundary stops the merge here: the words stay text and
                // the control keeps its own name and its own box.
                Semantics(container: true, child: action!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
