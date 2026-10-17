import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Driver-selection step — the user picks which discovery backends to
/// scan. The set is persisted to the draft so the camera/mount/etc.
/// discovery steps later only spin up the chosen backends.
class OnboardingDriverStep extends ConsumerWidget {
  const OnboardingDriverStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final draft = ref.watch(onboardingDraftProvider);
    final notifier = ref.read(onboardingDraftProvider.notifier);
    final available = ref.watch(availableOnboardingDriversProvider);

    // Preserve a stable rendering order so the chip layout is identical
    // between platforms and across launches.
    const displayOrder = [
      DriverType.native,
      DriverType.ascom,
      DriverType.alpaca,
      DriverType.indi,
      DriverType.simulator,
    ];

    // Scrollable: four driver tiles plus the ASCOM footnote exceed the wizard
    // body in a small window (and on a phone), and as a bare Column the surplus
    // overflowed instead of scrolling.
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(
            icon: SkotiqIcons.connected,
            title: 'Which drivers should we scan?',
          ),
          Text(
            'Pick everything that applies to your setup. You can change this '
            'later.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          ...displayOrder.where(available.contains).map((driver) => _DriverTile(
                driver: driver,
                selected: draft.selectedDrivers.contains(driver),
                onToggle: () => notifier.toggleDriver(driver),
              )),
          if (!available.contains(DriverType.ascom))
            Padding(
              padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    SkotiqIcons.info,
                    size: SkotiqTokens.iconXs,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Expanded(
                    child: Text(
                      'ASCOM COM drivers are Windows-only. Use Alpaca to reach '
                      'an ASCOM server from this platform.',
                      style: SkotiqTypography.caption.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DriverTile extends StatefulWidget {
  const _DriverTile({
    required this.driver,
    required this.selected,
    required this.onToggle,
  });

  final DriverType driver;
  final bool selected;
  final VoidCallback onToggle;

  @override
  State<_DriverTile> createState() => _DriverTileState();
}

class _DriverTileState extends State<_DriverTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final driver = widget.driver;
    final selected = widget.selected;
    final onToggle = widget.onToggle;

    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
      // One accessible node for the whole row, describing what it actually is.
      //
      // Read off the live accessibility tree (GUI drive 2026-08-09), every
      // driver row came out as:
      //
      //   panel: Native
      //   Direct SDK connection ... [DISABLED]
      //
      // — focusable, no checked state, and announced as not enabled, while the
      // row was in fact live and checked (clicking it toggled the box). Two
      // untruths at once: a screen-reader user is told there is nothing to
      // operate here, and is never told whether the driver is selected.
      //
      // The cause is that a bare `InkWell` publishes a tappable, focusable node
      // that never sets `isEnabled`, and its node shadows the
      // `SkotiqCheckbox`'s own correct `checked`/`enabled` semantics. The
      // checkbox is not at fault — it is simply not the node assistive tech
      // reaches. Declaring the container here, and excluding the now-duplicate
      // inner node, makes the row announce as "Native, <description>, checkbox,
      // checked" and leaves the pointer/keyboard behaviour untouched.
      child: Semantics(
        container: true,
        checked: selected,
        enabled: true,
        label: '${driver.shortLabel}. ${driver.description}',
        onTap: onToggle,
        child: InkWell(
          // The wrapper above is the accessible node; without this the
          // InkWell publishes a second, unflagged one and AT still reads
          // the row as disabled. Verified on the running app.
          excludeFromSemantics: true,
          onTap: onToggle,
          // InkWell is focusable and Space already toggled the row, but its focus
          // highlight paints BEHIND the child, and this row's own opaque surface
          // decoration covers it — so a keyboard user tabbing through the driver
          // list saw nothing move and could not tell which row Space would toggle.
          // The ring is drawn on the row's own decoration, in front of the fill.
          onFocusChange: (value) {
            if (_focused == value) return;
            setState(() => _focused = value);
          },
          borderRadius: SkotiqTokens.borderRadiusSm,
          child: Container(
            foregroundDecoration: _focused
                ? BoxDecoration(
                    borderRadius: SkotiqTokens.borderRadiusSm,
                    border: Border.all(color: colors.primary, width: 2),
                  )
                : null,
            padding: SkotiqTokens.paddingMd,
            // A tappable row inside the step panel: a `well` inset, with the
            // selection carried by a `primary` ring rather than a second fill
            // (05 §9 — panel → well is the deepest the ladder goes).
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: SkotiqTokens.borderRadiusSm,
              border: Border.all(
                color: selected
                    ? colors.primary.withValues(
                        alpha: SkotiqTokens.opacitySelectedRing,
                      )
                    : Colors.transparent,
              ),
            ),
            child: ExcludeSemantics(
              // The row above carries the label, the checked state and the tap.
              // Leaving these in would make a screen reader read the driver name
              // twice and offer a second, competing tap target for the same
              // action.
              child: Row(
                children: [
                  SkotiqCheckbox(
                    value: selected,
                    onChanged: (_) => onToggle(),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          driver.shortLabel,
                          style: SkotiqTypography.bodyStrong.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        Text(
                          driver.description,
                          style: SkotiqTypography.bodySm.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
