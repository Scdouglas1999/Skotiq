// The window's own chrome, drawn inside the single slate of glass: the drag
// surface, the minimize / maximize / close controls, the main area's top
// band, the sidebar's header (lockup + command field), and the invisible
// resize edges an undecorated Linux window needs.
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../widgets/command_palette/command_palette.dart';
import '../../../widgets/remote_connection_indicator.dart';
import '../../../widgets/transient_alert_badge.dart';
import '../../../widgets/tutorial_overlay.dart' show TutorialKeys;
import '../shell_chrome.dart';
import 'shell_clock.dart';
import 'shell_help_popover.dart';

// Conditional import for window_manager (desktop only)
import 'window_chrome_stub.dart'
    if (dart.library.io) 'window_chrome_desktop.dart' as window_impl;

/// The host window's maximize and full-screen flags, as the shell last heard
/// them. The resize edges and the app-drawn hairline gate on this: an
/// undecorated maximized window must neither resize from its edges nor draw
/// a frame edge the compositor already clipped.
@immutable
class WindowChromeState {
  final bool maximized;
  final bool fullscreen;

  const WindowChromeState({this.maximized = false, this.fullscreen = false});

  /// True while the window fills its work area or the screen: no free edges.
  bool get fillsScreen => maximized || fullscreen;

  WindowChromeState copyWith({bool? maximized, bool? fullscreen}) {
    return WindowChromeState(
      maximized: maximized ?? this.maximized,
      fullscreen: fullscreen ?? this.fullscreen,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WindowChromeState &&
      other.maximized == maximized &&
      other.fullscreen == fullscreen;

  @override
  int get hashCode => Object.hash(maximized, fullscreen);
}

/// What the desktop's own title bars do on a double click, read per-platform:
/// `gtk-titlebar-double-click` on Linux, `AppleActionOnDoubleClick` on macOS,
/// toggle-maximize everywhere else.
enum WindowDoubleClickAction { toggleMaximize, minimize, nothing }

/// One of the eight resize grips on an undecorated window. Kept independent
/// of window_manager's enum so the mobile/web stub never names a type the
/// plugin does not export there.
enum WindowResizeEdge {
  left,
  right,
  top,
  bottom,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

/// Makes [child] behave as window chrome: drag to move the frameless window,
/// double-tap to do what the desktop's own title bars do.
///
/// The desktop runners set `TitleBarStyle.hidden`, so the OS draws no
/// decorations at any width — every drag strip in the shell (the top band, the
/// sidebar's header strip, the compact bar below the breakpoint) is one of
/// these. No-ops on mobile via the conditional `window_chrome_stub` import.
class WindowDragArea extends StatelessWidget {
  final Widget child;

  const WindowDragArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: window_impl.onWindowDragPanStart,
      onDoubleTap: window_impl.onWindowDragDoubleTap,
      child: child,
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

/// Minimize / maximize-restore / close caption buttons for the frameless
/// desktop window, in the approved sizes: 30x30, radius 9, 16 px glyph, 2 px
/// apart. Public so every desktop shell layout can render them — the compact
/// bar below the side-nav breakpoint is still the window's only chrome.
///
/// Never rendered on macOS: the runner keeps the native traffic lights, and a
/// second set of window controls beside them is clutter, not redundancy.
class WindowControls extends StatelessWidget {
  final SkotiqColors colors;

  const WindowControls({super.key, required this.colors});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<WindowChromeState>(
      valueListenable: window_impl.windowChromeState,
      builder: (context, chrome, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _WindowButton(
              icon: SkotiqIcons.remove,
              label: 'Minimize window',
              onPressed: window_impl.minimizeWindow,
            ),
            const SizedBox(width: ShellChromeMetrics.windowButtonGap),
            _WindowButton(
              // Two overlapping squares are the platform's restore glyph; a
              // bare square is the maximize one.
              icon: chrome.maximized ? LucideIcons.copy : SkotiqIcons.stop,
              label: chrome.maximized ? 'Restore window' : 'Maximize window',
              onPressed: window_impl.toggleMaximizeWindow,
            ),
            const SizedBox(width: ShellChromeMetrics.windowButtonGap),
            const _WindowButton(
              icon: SkotiqIcons.close,
              label: 'Close window',
              onPressed: window_impl.closeWindow,
              isClose: true,
            ),
          ],
        );
      },
    );
  }
}

/// One caption button. A real control — button semantics, focus ring, keyboard
/// activation — because the window controls are the one chrome assistive tech
/// must always reach, and the old Semantics+GestureDetector pair published no
/// enabled state and no focus highlight at all.
class _WindowButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool isClose;

  const _WindowButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isClose = false,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final isEnabled = widget.onPressed != null;
    // Close keeps the platform convention — a red hover — while the other two
    // buttons stay on the neutral fills; both are token colors.
    final hoverInk = widget.isClose
        ? Theme.of(context).colorScheme.onError
        : colors.textPrimary;
    final fill = !isEnabled
        ? Colors.transparent
        : _pressed
            ? (widget.isClose ? colors.error : colors.surfaceElevated)
            : _hovered
                ? (widget.isClose ? colors.error : colors.surfaceHover)
                : Colors.transparent;
    final ink = widget.isClose && (_hovered || _pressed) && isEnabled
        ? hoverInk
        : colors.textMuted;

    return Semantics(
      container: true,
      button: true,
      enabled: isEnabled,
      focusable: isEnabled,
      label: widget.label,
      // A LABEL Tooltip inside the Semantics — see SkotiqIconButton for why
      // this pairing exists: `find.byTooltip` matches it, while
      // `excludeFromSemantics` + `TooltipVisibility` keep it from building a
      // second overlay or a second semantic node.
      child: TooltipVisibility(
        visible: false,
        child: Tooltip(
          message: widget.label,
          excludeFromSemantics: true,
          child: SkotiqTooltip(
            message: widget.label,
            position: SkotiqTooltipPosition.bottom,
            child: MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() {
                _hovered = false;
                _pressed = false;
              }),
              cursor: isEnabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              child: FocusableActionDetector(
                enabled: isEnabled,
                onShowFocusHighlight: (value) =>
                    setState(() => _focused = value),
                actions: <Type, Action<Intent>>{
                  ActivateIntent: CallbackAction<ActivateIntent>(
                    onInvoke: (_) {
                      widget.onPressed?.call();
                      return null;
                    },
                  ),
                  ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
                    onInvoke: (_) {
                      widget.onPressed?.call();
                      return null;
                    },
                  ),
                },
                child: GestureDetector(
                  onTap: isEnabled ? widget.onPressed : null,
                  onTapDown:
                      isEnabled ? (_) => setState(() => _pressed = true) : null,
                  onTapUp: isEnabled
                      ? (_) => setState(() => _pressed = false)
                      : null,
                  onTapCancel:
                      isEnabled ? () => setState(() => _pressed = false) : null,
                  child: ExcludeSemantics(
                    child: Opacity(
                      opacity: isEnabled ? 1.0 : SkotiqTokens.opacityDisabled,
                      child: SizedBox(
                        width: ShellChromeMetrics.windowButtonSize,
                        height: ShellChromeMetrics.windowButtonSize,
                        child: AnimatedContainer(
                          duration: animationDuration(
                            context,
                            SkotiqTokens.durationFast,
                          ),
                          curve: SkotiqTokens.curveStandard,
                          decoration: BoxDecoration(
                            color: fill,
                            borderRadius: BorderRadius.circular(
                              ShellChromeMetrics.windowButtonRadius,
                            ),
                            border: Border.all(
                              color: _focused && isEnabled
                                  ? colors.primary
                                  : Colors.transparent,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            widget.icon,
                            size: ShellChromeMetrics.windowButtonIconSize,
                            color: ink,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The main area's top band (the window's upper edge, ~58 px): the LST clock
/// at the left, the global actions at the right, then a 1x18 separator and
/// the window controls. The empty space in between is the drag surface.
///
/// `background`-toned like the page beneath it — the slate is one pane, and a
/// tonal step here would read as a title bar sneaking back in.
class ShellTopBand extends StatelessWidget {
  const ShellTopBand({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    // macOS keeps the native traffic lights; drawing a second set of window
    // controls beside them is duplication the platform conventions reject.
    final showWindowControls = ShellChrome.isDesktopWindow && !Platform.isMacOS;

    return WindowDragArea(
      child: Container(
        height: ShellChromeMetrics.topBandHeight,
        color: colors.background,
        padding: const EdgeInsets.only(
          left: SkotiqTokens.spaceXl,
          right: ShellChromeMetrics.topBandRightInset,
        ),
        child: Row(
          children: [
            const ShellClock(),
            const Spacer(),
            // Remote connection. Tap opens the details sheet, which carries
            // the "Reconnect now" button and the share action.
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
                      '[ShellTopBand] Could not navigate to transients: $e',
                      name: 'ShellTopBand',
                      level: 900,
                      error: e,
                    );
                  }
                },
              ),
            ),
            // Help for this screen: the tour, the shortcuts, the manual.
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
                      '[ShellTopBand] Could not navigate to settings: $e',
                      name: 'ShellTopBand',
                      level: 900,
                      error: e,
                      stackTrace: stack,
                    );
                  }
                },
              ),
            ),
            if (showWindowControls) ...[
              const SizedBox(width: SkotiqTokens.spaceSm),
              Container(
                width: 1,
                height: ShellChromeMetrics.topBandSeparatorHeight,
                color: colors.border,
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              // Last in the shell's keyboard order — sidebar, then main, then
              // the window's own controls (see the FocusTraversalGroup in
              // `app_shell.dart`).
              FocusTraversalOrder(
                order: const NumericFocusOrder(2),
                child: WindowControls(colors: colors),
              ),
            ] else
              const SizedBox(width: SkotiqTokens.spaceSm),
          ],
        ),
      ),
    );
  }
}

/// The sidebar's own header: the drag strip the traffic lights need on macOS,
/// the brand lockup, and the command field. It is part of the window chrome —
/// the lockup is decorative brand, the field is the palette's front door.
class SidebarChromeHeader extends StatelessWidget {
  /// Whether the sidebar shows its expanded (220 px) face.
  final bool isExpanded;

  const SidebarChromeHeader({super.key, required this.isExpanded});

  @override
  Widget build(BuildContext context) {
    final isMac = !kIsWebLike && Platform.isMacOS;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The strip that drags the window. On macOS it is also the room the
        // native traffic lights inset into — 40 px covers their full height.
        WindowDragArea(
          child: SizedBox(
            height: isMac
                ? ShellChromeMetrics.sidebarDragStripHeightMacOS
                : ShellChromeMetrics.sidebarDragStripHeight,
            width: double.infinity,
          ),
        ),
        if (isExpanded)
          const Padding(
            padding: EdgeInsets.only(
              left: SkotiqTokens.spaceLg,
              bottom: SkotiqTokens.spaceMd,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              // Sora is bundled, but a host missing the font (tests, a system
              // install) measures "skotiq" wider than the rail — the lockup
              // must shrink rather than clip or overflow the pane.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: SkotiqLockup(markSize: 26),
              ),
            ),
          )
        else
          // Collapsed the rail is 64 px wide: the mark alone, centred.
          const Padding(
            padding: EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
            child: Center(child: SkotiqMark(size: 26)),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.spaceMd,
          ),
          child: _SidebarCommandField(isExpanded: isExpanded),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
      ],
    );
  }
}

/// The command field as it lives in the sidebar header: a real field-shaped
/// button that opens the palette, collapsed to a square search button when the
/// rail is.
class _SidebarCommandField extends StatefulWidget {
  final bool isExpanded;

  const _SidebarCommandField({required this.isExpanded});

  @override
  State<_SidebarCommandField> createState() => _SidebarCommandFieldState();
}

class _SidebarCommandFieldState extends State<_SidebarCommandField> {
  bool _isHovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    final placeholder = l10n.text('commandPalettePlaceholder');

    if (!widget.isExpanded) {
      return Center(
        child: SizedBox(
          width: ShellChromeMetrics.railItemSize,
          height: ShellChromeMetrics.railItemSize,
          child: SkotiqIconButton(
            icon: LucideIcons.search,
            tooltip: placeholder,
            tooltipPosition: SkotiqTooltipPosition.right,
            onPressed: () => showCommandPalette(context),
          ),
        ),
      );
    }

    // Not a TextField: the field is a BUTTON that opens the palette, and the
    // palette owns the real input. Two live text fields for one search would
    // mean deciding which one the keystrokes belong to on every frame.
    return Semantics(
      container: true,
      button: true,
      enabled: true,
      focusable: true,
      label: placeholder,
      child: TooltipVisibility(
        visible: false,
        child: Tooltip(
          message: placeholder,
          excludeFromSemantics: true,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _isHovered = true),
            onExit: (_) => setState(() => _isHovered = false),
            child: FocusableActionDetector(
              onShowFocusHighlight: (value) => setState(() => _focused = value),
              actions: <Type, Action<Intent>>{
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) {
                    showCommandPalette(context);
                    return null;
                  },
                ),
                ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
                  onInvoke: (_) {
                    showCommandPalette(context);
                    return null;
                  },
                ),
              },
              child: GestureDetector(
                onTap: () => showCommandPalette(context),
                child: ExcludeSemantics(
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(
                      horizontal: SkotiqTokens.spaceSm + 2,
                    ),
                    // The field decoration, filled `well`: on the `surface`
                    // sidebar a well reads as an inset, which is what a field
                    // is.
                    decoration: SkotiqDecorations.field(colors).copyWith(
                      color: _isHovered ? colors.surfaceHover : colors.well,
                      border: Border.all(
                        color: _focused ? colors.primary : colors.border,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          LucideIcons.search,
                          size: SkotiqTokens.iconField,
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
            ),
          ),
        ),
      ),
    );
  }
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

/// The window's own 1 px edge, drawn by the app on Linux where the runner
/// installs no decorations at all — about 9% of the theme's ink, so red night
/// gets a red-tinted edge rather than a white one. Gated on the chrome state:
/// a maximized or full-screen window has no free edge to outline.
///
/// Painted above everything in the body Stack; pointer-transparent because it
/// is a line, not a control.
class WindowEdgeHairline extends StatelessWidget {
  const WindowEdgeHairline({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: ValueListenableBuilder<WindowChromeState>(
          valueListenable: window_impl.windowChromeState,
          builder: (context, chrome, _) {
            if (chrome.fillsScreen) return const SizedBox.shrink();
            return DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: colors.textPrimary.withValues(alpha: 0.09),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The invisible resize grips an undecorated Linux window needs: 5 px along
/// each edge, 14 px squares at the corners, gated off while the window fills
/// its work area or the screen (a maximized window has no free edge to grab).
///
/// Wraps the app at the root on Linux — the window-manager plugin answers the
/// edge hit-test natively on Windows and macOS, but nothing does on Linux.
class WindowResizeEdges extends StatelessWidget {
  final Widget child;

  const WindowResizeEdges({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<WindowChromeState>(
      valueListenable: window_impl.windowChromeState,
      builder: (context, chrome, _) {
        return Stack(
          children: [
            child,
            if (!chrome.fillsScreen)
              for (final edge in WindowResizeEdge.values)
                _ResizeGrip(edge: edge),
          ],
        );
      },
    );
  }
}

class _ResizeGrip extends StatelessWidget {
  final WindowResizeEdge edge;

  const _ResizeGrip({required this.edge});

  static const double _side = ShellChromeMetrics.windowResizeEdgeSize;
  static const double _corner = ShellChromeMetrics.windowResizeCornerSize;

  MouseCursor get _cursor => switch (edge) {
        WindowResizeEdge.left ||
        WindowResizeEdge.right =>
          SystemMouseCursors.resizeLeftRight,
        WindowResizeEdge.top ||
        WindowResizeEdge.bottom =>
          SystemMouseCursors.resizeUpDown,
        WindowResizeEdge.topLeft ||
        WindowResizeEdge.bottomRight =>
          SystemMouseCursors.resizeUpLeftDownRight,
        WindowResizeEdge.topRight ||
        WindowResizeEdge.bottomLeft =>
          SystemMouseCursors.resizeUpRightDownLeft,
      };

  @override
  Widget build(BuildContext context) {
    final isCorner = switch (edge) {
      WindowResizeEdge.topLeft ||
      WindowResizeEdge.topRight ||
      WindowResizeEdge.bottomLeft ||
      WindowResizeEdge.bottomRight =>
        true,
      _ => false,
    };
    final extent = isCorner ? _corner : _side;
    return Positioned(
      left: switch (edge) {
        WindowResizeEdge.left ||
        WindowResizeEdge.topLeft ||
        WindowResizeEdge.bottomLeft =>
          0,
        WindowResizeEdge.top || WindowResizeEdge.bottom => _corner,
        _ => null,
      },
      right: switch (edge) {
        WindowResizeEdge.right ||
        WindowResizeEdge.topRight ||
        WindowResizeEdge.bottomRight =>
          0,
        WindowResizeEdge.top || WindowResizeEdge.bottom => _corner,
        _ => null,
      },
      top: switch (edge) {
        WindowResizeEdge.top ||
        WindowResizeEdge.topLeft ||
        WindowResizeEdge.topRight =>
          0,
        WindowResizeEdge.left || WindowResizeEdge.right => _corner,
        _ => null,
      },
      bottom: switch (edge) {
        WindowResizeEdge.bottom ||
        WindowResizeEdge.bottomLeft ||
        WindowResizeEdge.bottomRight =>
          0,
        WindowResizeEdge.left || WindowResizeEdge.right => _corner,
        _ => null,
      },
      width: switch (edge) {
        WindowResizeEdge.left || WindowResizeEdge.right => extent,
        _ when isCorner => extent,
        _ => null,
      },
      height: switch (edge) {
        WindowResizeEdge.top || WindowResizeEdge.bottom => extent,
        _ when isCorner => extent,
        _ => null,
      },
      child: MouseRegion(
        cursor: _cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (_) => window_impl.startWindowResize(edge),
        ),
      ),
    );
  }
}
