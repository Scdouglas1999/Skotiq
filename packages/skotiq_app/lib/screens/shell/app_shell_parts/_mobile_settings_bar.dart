// The mobile settings bar shown in the shell chrome.
part of '../app_shell.dart';

class _MobileSettingsBar extends StatelessWidget {
  final VoidCallback onOpenSettings;

  const _MobileSettingsBar({required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    // A narrow DESKTOP window still has no OS decorations (the runners set
    // TitleBarStyle.hidden), so this bar owns minimize/maximize/close and the
    // drag-to-move region below the side-nav breakpoint exactly as the top
    // band does above it. Without them, resizing under 768px left the window
    // with no mouse-reachable way to be closed, minimized or moved.
    //
    // macOS is the exception: the native traffic lights stay, so no custom
    // controls are drawn — and the bar clears the room they inset into.
    final isDesktopWindow = ShellChrome.isDesktopWindow;
    final isMac = !kIsWebLike && Platform.isMacOS;
    final showWindowControls = isDesktopWindow && !isMac;

    final bar = Container(
      height: ShellChromeMetrics.titleBarHeight,
      color: colors.surface,
      // Caption buttons are flush to the window edge (platform convention and
      // Fitts' law), so the trailing inset is dropped when they are present.
      padding: EdgeInsets.only(
        // On macOS the traffic lights sit at the top-left ~78 px of every
        // window — the lockup must start past them, not underneath.
        left: isMac ? 80 : SkotiqTokens.spaceLg,
        right: showWindowControls
            ? ShellChromeMetrics.topBandRightInset
            : SkotiqTokens.spaceLg,
      ),
      child: Row(
        children: [
          // The wordmark yields before the caption buttons do: on a very
          // narrow window the lockup may ellipsize, but close must not vanish.
          const Flexible(
            child: SkotiqLockup(markSize: 18),
          ),
          const Spacer(),
          SkotiqIconButton(
            key: TutorialKeys.navSettings,
            icon: SkotiqIcons.settings,
            tooltip: l10n.text('settingsTitle'),
            tooltipPosition: SkotiqTooltipPosition.bottom,
            onPressed: onOpenSettings,
          ),
          if (showWindowControls) ...[
            const SizedBox(width: SkotiqTokens.spaceSm),
            WindowControls(colors: colors),
          ],
        ],
      ),
    );

    if (!isDesktopWindow) return bar;
    return WindowDragArea(child: bar);
  }
}
