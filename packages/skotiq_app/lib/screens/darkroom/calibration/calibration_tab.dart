import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'calibration_library_panel.dart';
import 'calibration_match_panel.dart';
import 'calibration_settings_panel.dart';
import 'calibration_waiting_panel.dart';

/// The Darkroom's Calibration tab: one library of darks, bias and flats.
///
/// Raw calibration frames Skotiq captured wait at the top until a master
/// covers them; the library lists every registered master; the side column
/// holds how frames are calibrated while imaging and a match check.
class DarkroomCalibrationTab extends ConsumerStatefulWidget {
  const DarkroomCalibrationTab({super.key});

  /// Content narrower than this stacks the side column under the main one.
  static const double twoColumnMinWidth = 1080;
  static const double sideColumnWidth = 420;

  @override
  ConsumerState<DarkroomCalibrationTab> createState() =>
      _DarkroomCalibrationTabState();
}

class _DarkroomCalibrationTabState
    extends ConsumerState<DarkroomCalibrationTab> {
  final _library = GlobalKey<CalibrationLibraryPanelState>();

  @override
  void initState() {
    super.initState();
    // Frames captured since the tab was last open must show without a manual
    // reload.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(calibrationBacklogProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final main = <Widget>[
      const CalibrationWaitingPanel(),
      CalibrationLibraryPanel(key: _library),
    ];
    final side = <Widget>[
      const CalibrationSettingsPanel(),
      CalibrationMatchPanel(
        onAccept: (record) async => _library.currentState?.acceptRemote(record),
      ),
      const _CaptureLinks(),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns =
            constraints.maxWidth >= DarkroomCalibrationTab.twoColumnMinWidth;
        const gap = SkotiqTokens.spaceLg + 2;
        Widget column(List<Widget> children) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(height: gap),
                  children[i],
                ],
              ],
            );
        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal:
                twoColumns ? SkotiqTokens.space2xl : SkotiqTokens.spaceLg,
            vertical: SkotiqTokens.spaceXl,
          ),
          child: twoColumns
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: column(main)),
                    const SizedBox(width: gap),
                    SizedBox(
                      width: DarkroomCalibrationTab.sideColumnWidth,
                      child: column(side),
                    ),
                  ],
                )
              : column([...main, ...side]),
        );
      },
    );
  }
}

/// Where calibration frames come from, one click away.
class _CaptureLinks extends StatelessWidget {
  const _CaptureLinks();

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Wrap(
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceSm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'Need more frames?',
          style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
        ),
        SkotiqButton(
          label: 'Take flats',
          icon: LucideIcons.sun,
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () => context.go('/flat-wizard'),
        ),
        SkotiqButton(
          label: 'Night-end darks and bias',
          icon: LucideIcons.moonStar,
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () => context.go('/darkroom?tab=activity'),
        ),
      ],
    );
  }
}
