import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../dashboard_layout_provider.dart';
import 'dashboard_widget_registry.dart';

/// Opens the dashboard widget picker as an adaptive modal: a centered,
/// viewport-capped dialog on tablet/desktop and a bottom sheet on a phone.
///
/// Adaptive rather than a plain `showDialog`, so the picker never renders as a
/// fixed desktop-sized dialog on a narrow phone.
Future<void> showWidgetPickerModal(BuildContext context) {
  return showAdaptiveModal<void>(
    context: context,
    designWidth: 420,
    designHeight: 640,
    builder: (context) => const WidgetPickerDialog(),
  );
}

/// The dashboard widget picker body.
///
/// Rendered inside [showWidgetPickerModal] which supplies the surrounding
/// chrome (Dialog frame on tablet/desktop, bottom sheet on phone). The body is
/// a titled, scrollable checkbox list that toggles each tile's enabled flag.
class WidgetPickerDialog extends ConsumerWidget {
  const WidgetPickerDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final layoutAsync = ref.watch(dashboardLayoutProvider);
    final isPhone = Responsive.isPhone(context);

    final header = Padding(
      padding: EdgeInsets.fromLTRB(
        isPhone ? 16 : 24,
        isPhone ? 8 : 20,
        isPhone ? 16 : 24,
        12,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Dashboard Widgets',
              // 05 §13: a dialog title is `sectionTitle`, one size on every
              // surface — the phone/desktop split was a second scale.
              style: SkotiqTypography.sectionTitle.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
          SkotiqIconButton(
            icon: SkotiqIcons.close,
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );

    final body = layoutAsync.when(
      data: (layout) {
        final tilesById = {
          for (final tile in layout.tiles) tile.widgetId: tile,
        };

        final children = <Widget>[];
        // Grouped, not flat: the registry carries two generations of tiles that
        // overlap in subject matter, and a flat list showed the operator two
        // rows named "Guiding" with nothing to tell them apart.
        for (final group in DashboardWidgetGroup.values) {
          final members = dashboardWidgetRegistry
              .where((definition) => definition.group == group);
          if (members.isEmpty) continue;

          children.add(_SectionHeader(
            colors: colors,
            isPhone: isPhone,
            group: group,
          ));

          for (final definition in members) {
            final tile = tilesById[definition.id];
            final enabled = tile?.enabled ?? false;

            children.add(Divider(color: colors.border, height: 1));
            children.add(
              CheckboxListTile(
                value: enabled,
                onChanged: (value) {
                  if (value == null) return;
                  ref
                      .read(dashboardLayoutProvider.notifier)
                      .setTileEnabled(definition.id, value);
                },
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  definition.title,
                  style: SkotiqTypography.body.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                subtitle: Text(
                  definition.subtitle,
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
            );
          }
        }

        return ListView(
          padding: EdgeInsets.only(bottom: isPhone ? 8 : 12),
          shrinkWrap: true,
          children: children,
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
            child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Failed to load widgets: $error',
          style: SkotiqTypography.bodySm.copyWith(
            color: colors.textSecondary,
          ),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Flexible(child: body),
      ],
    );
  }
}

/// Names the family the rows beneath it belong to, so a tile that overlaps an
/// older card is placed rather than guessed at.
class _SectionHeader extends StatelessWidget {
  final SkotiqColors colors;
  final bool isPhone;
  final DashboardWidgetGroup group;

  const _SectionHeader({
    required this.colors,
    required this.isPhone,
    required this.group,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(isPhone ? 16 : 24, 16, isPhone ? 16 : 24, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            group.label.toUpperCase(),
            style: SkotiqTypography.eyebrow.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            group.description,
            style: SkotiqTypography.caption.copyWith(
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}
