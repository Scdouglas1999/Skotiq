import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../widgets/command_palette/command_palette.dart';
import '../../../widgets/remote_connection_indicator.dart';
import '../../../widgets/transient_alert_badge.dart';
import '../../../widgets/tutorial_overlay.dart' show TutorialKeys;
import '../shell_chrome.dart';
import 'shell_help_popover.dart';

// Conditional import for window_manager (desktop only)
import 'title_bar_stub.dart' if (dart.library.io) 'title_bar_desktop.dart'
    as window_impl;

/// Makes [child] behave as window chrome: drag to move the frameless window,
/// double-tap to toggle maximize.
///
/// Public because the shell renders a second, compact bar below the
/// side-nav breakpoint (`_MobileSettingsBar`). That bar is still the desktop
/// window's only title bar — `TitleBarStyle.hidden` means the OS draws no
/// decorations at any width — so it needs the same move/maximize affordances.
/// No-ops on mobile via the conditional `title_bar_stub` import.
class WindowDragArea extends StatelessWidget {
  final Widget child;

  const WindowDragArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: window_impl.onTitleBarPanStart,
      onDoubleTap: window_impl.onTitleBarDoubleTap,
      child: child,
    );
  }
}

/// The top bar (04-shell §2): brand, the global command field, four global
/// actions, and the window controls.
///
/// `background`-toned rather than `surface`: it and the rail are the window's
/// own edge, and the instrument bar is the one piece of chrome that lifts off
/// the canvas.
class TitleBar extends ConsumerWidget {
  const TitleBar({super.key});

  /// Width held clear on each side for the brand and the action cluster, so
  /// the centred field cannot land on top of either.
  ///
  /// The action cluster is the wider of the two: four 32 px buttons, three
  /// 46 px window controls and the gaps between them.
  static const double _sideReserve = 300.0;

  /// Below this the field is not worth showing; the search button in the
  /// action cluster takes over and opens the same palette.
  static const double _minFieldWidth = 220.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);

    return WindowDragArea(
      child: Container(
        height: ShellChromeMetrics.titleBarHeight,
        decoration: BoxDecoration(
          color: colors.background,
          border: Border(bottom: BorderSide(color: colors.border, width: 1)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fieldWidth = (constraints.maxWidth - _sideReserve * 2).clamp(
              0.0,
              _CommandField.maxWidth,
            );
            final showsField = fieldWidth >= _minFieldWidth;
            return Stack(
              children: [
                Row(
                  children: [
                    const SizedBox(width: SkotiqTokens.spaceLg),
                    const _Brand(),
                    const Spacer(),
                    _Actions(showSearchButton: !showsField),
                  ],
                ),
                // Centred on the WINDOW, not on the space between the brand
                // and the actions: the mockup's grid is 1fr / field / 1fr and
                // the field reads as the window's own, not as the brand's
                // trailing control.
                if (showsField)
                  Center(
                    child: SizedBox(
                      width: fieldWidth,
                      child: const _CommandField(),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  /// The rounded square that carries the mark.
  static const double _markSize = 22.0;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final onPrimary = Theme.of(context).colorScheme.onPrimary;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: _markSize,
          height: _markSize,
          decoration: BoxDecoration(
            color: colors.primary,
            borderRadius: SkotiqTokens.borderRadiusSm,
          ),
          child: Icon(
            LucideIcons.sparkles,
            size: SkotiqTokens.iconXs,
            color: onPrimary,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm + 2),
        Text(
          'SKOTIQ',
          style: _wordmark.copyWith(color: colors.textPrimary),
        ),
      ],
    );
  }

  static const TextStyle _wordmark = SkotiqTypography.wordmark;
}

/// The global command field. Click it, or press Ctrl/Cmd+K, to open the
/// palette (04 §7).
class _CommandField extends StatefulWidget {
  const _CommandField();

  static const double maxWidth = 520.0;
  static const double height = 30.0;

  @override
  State<_CommandField> createState() => _CommandFieldState();
}

class _CommandFieldState extends State<_CommandField> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    final placeholder = l10n.text('commandPalettePlaceholder');

    // Not a TextField: the field is a BUTTON that opens the palette, and the
    // palette owns the real input. Two live text fields for one search would
    // mean deciding which one the keystrokes belong to on every frame.
    return Semantics(
      button: true,
      enabled: true,
      label: placeholder,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: () => showCommandPalette(context),
          child: Container(
            height: _CommandField.height,
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceSm + 2,
            ),
            // The field decoration, but filled `surface` rather than `well`:
            // this one sits on the `background` bar, where a well-toned fill
            // reads as a hole rather than as an inset.
            decoration: SkotiqDecorations.field(colors).copyWith(
              color: _isHovered ? colors.surfaceHover : colors.surface,
            ),
            child: Row(
              children: [
                Icon(
                  LucideIcons.search,
                  size: _searchIconSize,
                  color: colors.textMuted,
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: Text(
                    placeholder,
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textMuted,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                _KbdChip(label: commandPaletteShortcutLabel),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static const double _searchIconSize = SkotiqTokens.iconField;
}

/// The "Ctrl K" hint inside the command field.
class _KbdChip extends StatelessWidget {
  final String label;

  const _KbdChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: SkotiqTokens.borderRadiusXs,
        border: Border.all(color: colors.border),
      ),
      child: Text(
        label,
        style: SkotiqTypography.monoCaption.copyWith(
          color: colors.textMuted,
        ),
      ),
    );
  }
}

/// The four global actions, then the window controls.
class _Actions extends StatelessWidget {
  /// Shown in place of the command field when the window is too narrow to
  /// hold one; it opens the same palette.
  final bool showSearchButton;

  const _Actions({required this.showSearchButton});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showSearchButton)
          SkotiqIconButton(
            icon: LucideIcons.search,
            tooltip: l10n.text('commandPalettePlaceholder'),
            tooltipPosition: SkotiqTooltipPosition.bottom,
            onPressed: () => showCommandPalette(context),
          ),

        // Remote connection. Tap opens the details sheet, which carries the
        // "Reconnect now" button and the share action the instrument bar used
        // to hold.
        const RemoteConnectionIndicator(compact: true),

        // Transient alerts.
        Builder(
          builder: (context) => TransientAlertBadge(
            showDropdown: true,
            onTap: () {
              try {
                context.go('/transients');
              } catch (e) {
                developer.log(
                  '[TitleBar] Could not navigate to transients: $e',
                  name: 'TitleBar',
                  level: 900,
                  error: e,
                );
              }
            },
          ),
        ),

        // Help for this screen: the tour, the shortcuts, the manual. Replaces
        // the per-screen tour nudges that used to appear unbidden in the
        // bottom-right corner of ten screens.
        const ShellHelpButton(),

        // Settings — keyed for the onboarding overlay so the first-launch
        // tour can spotlight where Plate Solving lives.
        Builder(
          builder: (context) => SkotiqIconButton(
            key: TutorialKeys.navSettings,
            icon: LucideIcons.settings,
            tooltip: l10n.text('settingsTitle'),
            tooltipPosition: SkotiqTooltipPosition.bottom,
            onPressed: () {
              try {
                context.go('/settings');
              } catch (e, stack) {
                developer.log(
                  '[TitleBar] Could not navigate to settings: $e',
                  name: 'TitleBar',
                  level: 900,
                  error: e,
                  stackTrace: stack,
                );
              }
            },
          ),
        ),

        if (ShellChrome.isDesktopWindow) ...[
          const SizedBox(width: SkotiqTokens.spaceSm),
          WindowControls(colors: colors),
        ] else
          const SizedBox(width: SkotiqTokens.spaceMd),
      ],
    );
  }
}

/// The label on the command field's keyboard hint.
///
/// macOS reads the Meta key as Cmd; every other desktop reads Control. The
/// binding itself accepts both (see `app_shell.dart`), so the hint names the
/// one the operator's keyboard actually has.
String get commandPaletteShortcutLabel =>
    !kIsWebLike && Platform.isMacOS ? 'Cmd K' : 'Ctrl K';

/// `Platform` throws on web; the desktop shell never runs there, but the
/// mobile app shares this file.
const bool kIsWebLike = bool.fromEnvironment('dart.library.js_util');

/// Minimize / maximize / close caption buttons for the frameless desktop
/// window. Public so every desktop shell layout can render them — see
/// [WindowDragArea].
class WindowControls extends StatelessWidget {
  final SkotiqColors colors;

  const WindowControls({super.key, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _WindowButton(
          icon: SkotiqIcons.remove,
          label: 'Minimize',
          onPressed: window_impl.minimizeWindow,
          hoverColor: colors.surfaceHover,
        ),
        _WindowButton(
          icon: SkotiqIcons.stop,
          label: 'Maximize',
          onPressed: window_impl.toggleMaximizeWindow,
          hoverColor: colors.surfaceHover,
        ),
        _WindowButton(
          icon: SkotiqIcons.close,
          label: 'Close window',
          onPressed: window_impl.closeWindow,
          hoverColor: colors.error,
          isClose: true,
        ),
      ],
    );
  }
}

class _WindowButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color hoverColor;
  final bool isClose;

  const _WindowButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.hoverColor,
    this.isClose = false,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final onError = Theme.of(context).colorScheme.onError;
    final isEnabled = widget.onPressed != null;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      // Minimize, maximize and close are the window's own controls and they
      // published no enabled state, so assistive tech announced all three as
      // unavailable — on the one bar an operator reaches for when the window is
      // in their way. See [SkotiqIconButton] for why the field is what
      // decides.
      child: Semantics(
        button: true,
        label: widget.label,
        enabled: isEnabled,
        focusable: isEnabled,
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: ShellChromeMetrics.windowControlWidth,
            height: ShellChromeMetrics.windowControlHeight,
            color: _isHovered ? widget.hoverColor : Colors.transparent,
            child: Icon(
              widget.icon,
              size: SkotiqTokens.iconXs,
              color: !isEnabled
                  ? colors.textMuted
                  : (_isHovered && widget.isClose ? onError : colors.textMuted),
            ),
          ),
        ),
      ),
    );
  }
}
