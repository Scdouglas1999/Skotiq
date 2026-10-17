import 'package:flutter/material.dart';
import '../components/focus_ring.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';

/// An accessible icon button with proper semantics and focus support.
///
/// This widget wraps IconButton with accessibility features including:
/// - Semantic labels for screen readers
/// - Keyboard focus support
/// - Proper enabled/disabled states
/// - Tooltip support
class AccessibleIconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;
  final bool autofocus;

  const AccessibleIconButton({
    super.key,
    required this.icon,
    required this.label,
    this.tooltip,
    this.onPressed,
    this.color,
    this.size = 24,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final effectiveColor = color ?? colors.textPrimary;
    final isEnabled = onPressed != null;

    // IconButton opens its own semantics container, which no wrapper can merge
    // into. Left alone this publishes two nodes — a named one that cannot be
    // activated and an anonymous one that can — so assistive tech never gets a
    // node that is both this button and operable. Excluding the inner tree and
    // carrying the action here makes it one node that says what it is, whether
    // it is live, and how to press it.
    return Semantics(
      button: true,
      label: label,
      enabled: isEnabled,
      focusable: isEnabled,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: Tooltip(
          message: tooltip ?? label,
          child: FocusRing(
            borderRadius: SkotiqTokens.borderRadiusSm,
            focusColor: colors.primary,
            child: IconButton(
              icon: Icon(icon),
              iconSize: size,
              color: isEnabled ? effectiveColor : colors.textMuted,
              onPressed: onPressed,
              autofocus: autofocus,
              splashRadius: size + 4,
            ),
          ),
        ),
      ),
    );
  }
}
