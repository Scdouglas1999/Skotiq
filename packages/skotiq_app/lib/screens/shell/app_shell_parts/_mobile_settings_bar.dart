// The mobile settings bar shown in the shell chrome.
part of '../app_shell.dart';

class _MobileSettingsBar extends ConsumerWidget {
  final VoidCallback onOpenSettings;

  const _MobileSettingsBar({required this.onOpenSettings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(phoneBarStatusProvider);
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
          // narrow window the lockup scales down, but close must not vanish.
          const Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: SkotiqLockup(markSize: 18),
            ),
          ),
          const Spacer(),
          // The link to the imaging host, as the wide top band shows it: a
          // linked client must see whether its host answers at every width.
          const RemoteConnectionIndicator(compact: true),
          if (status != null) status,
          SkotiqIconButton(
            key: TourTarget.navSettings.key,
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

/// The shell's item on a phone, carried at the end of each screen's header:
/// the link to the imaging host and the phone's own status. Settings is in
/// the More sheet, so a header never shows the shell's gear beside a screen's
/// own.
class _PhoneHeaderTrailing extends ConsumerWidget {
  const _PhoneHeaderTrailing();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(phoneBarStatusProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (status != null) status,
        const RemoteConnectionIndicator(dot: true),
      ],
    );
  }
}

/// A routed screen on a phone: its header carries the shell's trailing item,
/// and it reserves no bottom inset, which the bottom bar under it owns. Built
/// inside the shell's SafeArea, so the MediaQuery it trims has the top and
/// side insets already taken out.
class _PhoneScreen extends StatelessWidget {
  final Widget child;

  const _PhoneScreen({required this.child});

  @override
  Widget build(BuildContext context) {
    return ShellHeaderTrailing(
      trailing: const _PhoneHeaderTrailing(),
      child: MediaQuery.removePadding(
        context: context,
        removeBottom: true,
        child: child,
      ),
    );
  }
}
