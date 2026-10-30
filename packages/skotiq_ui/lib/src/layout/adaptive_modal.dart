import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../utils/adaptive_dialog_constraints.dart';
import '../utils/responsive_utils.dart';

/// How a phone-tier [showAdaptiveModal] presents itself.
enum PhoneModalMode {
  /// A draggable bottom sheet anchored to the bottom edge (default).
  bottomSheet,

  /// A full-screen route — use for content-heavy / multi-step modals.
  fullScreen,
}

/// Shows a modal that is a centered, viewport-capped **dialog** on tablet and
/// desktop but becomes a **bottom sheet or full-screen route** on a phone.
///
/// The adaptive replacement for `showDialog` for any modal that would otherwise
/// be a fixed desktop-sized dialog on a phone. On tablet/desktop it reuses
/// [AdaptiveDialogConstraints] so the dialog never overflows a narrow window.
///
/// [phoneMode] picks the phone presentation. [isDismissible] / [barrierLabel]
/// behave as in `showDialog` / `showModalBottomSheet`.
Future<T?> showAdaptiveModal<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double designWidth = 640,
  double? designHeight,
  PhoneModalMode phoneMode = PhoneModalMode.bottomSheet,
  bool isDismissible = true,
  bool useRootNavigator = true,
  String? barrierLabel,
}) {
  // Device-class, not width: a phone in landscape (wide viewport) must still
  // present as a sheet / full-screen route, never a centered desktop dialog.
  if (Responsive.isPhone(context)) {
    switch (phoneMode) {
      case PhoneModalMode.fullScreen:
        return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
          MaterialPageRoute<T>(fullscreenDialog: true, builder: builder),
        );
      case PhoneModalMode.bottomSheet:
        final colors = context.skotiqColors;
        return showModalBottomSheet<T>(
          context: context,
          isScrollControlled: true,
          isDismissible: isDismissible,
          enableDrag: isDismissible,
          useRootNavigator: useRootNavigator,
          backgroundColor: colors.surface,
          barrierColor: colors.background.withValues(alpha: 0.55),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(SkotiqTokens.radiusXl),
            ),
          ),
          builder: (sheetContext) {
            final maxHeight = MediaQuery.sizeOf(sheetContext).height * 0.92;
            return SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: SkotiqTokens.spaceSm,
                      ),
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: sheetContext.skotiqColors.border,
                          borderRadius: BorderRadius.circular(
                            SkotiqTokens.radiusXs,
                          ),
                        ),
                      ),
                    ),
                    Flexible(child: builder(sheetContext)),
                  ],
                ),
              ),
            );
          },
        );
    }
  }

  // Tablet / desktop: a centered, viewport-capped dialog.
  return showDialog<T>(
    context: context,
    barrierDismissible: isDismissible,
    barrierLabel: barrierLabel,
    useRootNavigator: useRootNavigator,
    builder: (dialogContext) {
      final size = AdaptiveDialogConstraints.dialogSize(
        dialogContext,
        designWidth: designWidth,
        designHeight: designHeight,
      );
      final colors = dialogContext.skotiqColors;
      return Dialog(
        backgroundColor: colors.surface,
        insetPadding: const EdgeInsets.all(SkotiqTokens.space2xl),
        shape: RoundedRectangleBorder(
          borderRadius: SkotiqTokens.borderRadiusXl,
          side: BorderSide(color: colors.border),
        ),
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: builder(dialogContext),
        ),
      );
    },
  );
}
