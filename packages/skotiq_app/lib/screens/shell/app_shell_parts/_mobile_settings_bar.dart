// The mobile settings bar shown in the shell chrome.
part of '../app_shell.dart';

class _MobileSettingsBar extends StatelessWidget {
  final VoidCallback onOpenSettings;

  const _MobileSettingsBar({required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    // A narrow DESKTOP window still has no OS decorations (the runners set
    // TitleBarStyle.hidden), so this bar owns minimize/maximize/close and the
    // drag-to-move region below the side-nav breakpoint exactly as the full
    // TitleBar does above it. Without them, resizing under 768px left the
    // window with no mouse-reachable way to be closed, minimized or moved.
    final isDesktopWindow = ShellChrome.isDesktopWindow;

    final bar = Container(
      height: ShellChromeMetrics.titleBarHeight,
      color: colors.surface,
      // Caption buttons are flush to the window edge (platform convention and
      // Fitts' law), so the trailing inset is dropped when they are present.
      padding: EdgeInsets.only(
        left: SkotiqTokens.spaceLg,
        right: isDesktopWindow ? 0 : SkotiqTokens.spaceLg,
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: colors.primary,
              borderRadius: SkotiqTokens.borderRadiusMd,
            ),
            child: Icon(SkotiqIcons.sparkle, size: 14, color: onPrimary),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm + 2),
          // The wordmark yields before the caption buttons do: on a very
          // narrow window the title may ellipsize, but close must not vanish.
          Flexible(
            child: Text(
              'SKOTIQ',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: SkotiqTypography.fontSize13,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
              ),
            ),
          ),
          const Spacer(),
          InkWell(
            key: TutorialKeys.navSettings,
            onTap: onOpenSettings,
            borderRadius: SkotiqTokens.borderRadiusInline4,
            child: Padding(
              padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
              child: Icon(
                SkotiqIcons.settings,
                size: SkotiqTokens.iconSm,
                color: colors.textSecondary,
              ),
            ),
          ),
          if (isDesktopWindow) ...[
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
