import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart';
import 'darkroom_targets_model.dart';
import 'darkroom_targets_providers.dart';
import 'nights_strip.dart' show darkroomShortDate;

const _fitsFiles = XTypeGroup(
  label: 'FITS images',
  extensions: ['fits', 'fit', 'fts'],
);

/// Picks a master flat file; replaceable in tests.
typedef DarkroomFlatPicker = Future<String?> Function(String filter);

final darkroomFlatPickerProvider = Provider<DarkroomFlatPicker>(
  (ref) => (filter) async => (await openFile(
        acceptedTypeGroups: const [_fitsFiles],
        confirmButtonText: 'Use this flat for $filter',
      ))
          ?.path,
);

const double _filterColumn = 28;
const double _darkColumn = 170;
const double _biasColumn = 120;

/// Narrower than this, a filter's row wraps instead of keeping columns.
const double _wideRow = 640;

/// The flat a filter of [key] will be calibrated with: the operator's choice,
/// else the library's match.
String? darkroomFlatFor(
  String filter,
  List<DarkroomFilterCalibration> matches,
  Map<String, String> choices,
) =>
    choices[filter] ??
    matches
        .where((m) => m.filter == filter)
        .firstOrNull
        ?.match
        .flat
        ?.record
        .filePath;

/// Per filter: the dark, bias and flat the build will use, with a fix inline
/// where one is missing.
class DarkroomCalibrationPanel extends ConsumerWidget {
  const DarkroomCalibrationPanel({super.key, required this.target});

  final DarkroomTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final matches = ref.watch(darkroomTargetCalibrationProvider(target.key));
    final choices = ref.watch(darkroomFlatChoicesProvider(target.key));
    return _Panel(
      title: 'Calibration',
      trailing: SkotiqButton(
        label: 'Library',
        variant: ButtonVariant.ghost,
        size: ButtonSize.small,
        onPressed: () =>
            context.go(darkroomTabLocation(DarkroomTab.calibration)),
      ),
      child: matches.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(SkotiqTokens.spaceLg),
          child:
              Center(child: SkotiqProgressBar(value: 0, indeterminate: true)),
        ),
        error: (error, _) => Text(
          'The calibration library could not be read: $error',
          style: SkotiqTypography.bodySm.copyWith(color: colors.error),
        ),
        data: (list) => list.isEmpty
            ? Text(
                'No kept subs to match calibration to.',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final m in list)
                    _FilterRow(
                      targetKey: target.key,
                      calibration: m,
                      all: list,
                      choices: choices,
                    ),
                ],
              ),
      ),
    );
  }
}

class _FilterRow extends ConsumerWidget {
  const _FilterRow({
    required this.targetKey,
    required this.calibration,
    required this.all,
    required this.choices,
  });

  final String targetKey;
  final DarkroomFilterCalibration calibration;
  final List<DarkroomFilterCalibration> all;
  final Map<String, String> choices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final filter = calibration.filter;
    final match = calibration.match;
    final dark = match.dark;
    final bias = match.bias;
    final chosen = choices[filter];
    final flat = match.flat;
    final muted = SkotiqTypography.bodySm.copyWith(color: colors.textMuted);
    final value = SkotiqTypography.bodySm.copyWith(color: colors.textPrimary);
    final warn = SkotiqTypography.bodySm.copyWith(color: colors.warning);
    String frames(int? n) => n == null ? 'master' : '$n frames';
    final darkText = dark == null
        ? null
        : dark.exposureScaled
            ? 'scaled from ${_secs(dark.record.exposureSeconds)} · '
                '${frames(dark.record.frameCount)}'
            : '${_secs(dark.record.exposureSeconds)} · '
                '${frames(dark.record.frameCount)}';
    final borrow = [
      for (final other in all)
        if (other.filter != filter &&
            darkroomFlatFor(other.filter, all, choices) != null)
          other.filter,
    ];
    final choicesNotifier =
        ref.read(darkroomFlatChoicesProvider(targetKey).notifier);
    final fixes = <Widget>[
      if (chosen != null)
        SkotiqButton(
          label: 'Undo',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () => choicesNotifier.state = {
            for (final e in choices.entries)
              if (e.key != filter) e.key: e.value,
          },
        )
      else if (flat == null) ...[
        if (borrow.isNotEmpty)
          SkotiqButton(
            key: ValueKey('darkroom_use_flat_${filter}_${borrow.first}'),
            label: 'Use the ${borrow.first} flat',
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => choicesNotifier.state = {
              ...choices,
              filter: darkroomFlatFor(borrow.first, all, choices)!,
            },
          ),
        SkotiqButton(
          key: ValueKey('darkroom_choose_flat_$filter'),
          label: 'Choose a flat',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () async {
            final path = await ref.read(darkroomFlatPickerProvider)(filter);
            if (path != null) {
              choicesNotifier.state = {...choices, filter: path};
            }
          },
        ),
      ],
    ];
    final filterLabel = Text(
      filter,
      style: SkotiqTypography.labelStrong.copyWith(color: colors.textPrimary),
    );
    final darkCell = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'Dark ', style: muted),
          TextSpan(
            text: darkText ?? 'none',
            style: darkText == null ? warn : value,
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final biasCell = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'Bias ', style: muted),
          TextSpan(
            text: bias == null ? 'none' : frames(bias.record.frameCount),
            style: value,
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final flatCell = Tooltip(
      message: chosen ?? flat?.record.filePath ?? 'No matching flat',
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: 'Flat ', style: muted),
            TextSpan(
              text: chosen != null
                  ? p.basename(chosen)
                  : (flat == null
                      ? 'none'
                      : darkroomShortDate(flat.record.createdAt)),
              style: chosen == null && flat == null ? warn : value,
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    return Container(
      key: ValueKey('darkroom_calibration_row_$filter'),
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= _wideRow) {
            return Row(
              children: [
                SizedBox(width: _filterColumn, child: filterLabel),
                const SizedBox(width: SkotiqTokens.spaceMd),
                SizedBox(width: _darkColumn, child: darkCell),
                SizedBox(width: _biasColumn, child: biasCell),
                Expanded(child: flatCell),
                for (final fix in fixes) ...[
                  const SizedBox(width: SkotiqTokens.spaceXs),
                  fix,
                ],
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: _filterColumn, child: filterLabel),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Wrap(
                  spacing: SkotiqTokens.spaceLg,
                  runSpacing: SkotiqTokens.spaceXs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [darkCell, biasCell, flatCell, ...fixes],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _secs(double? s) {
    if (s == null) return '? s';
    return s == s.roundToDouble() ? '${s.round()} s' : '$s s';
  }
}

/// The hairline-bordered panel the Targets detail is built from.
class DarkroomTargetPanel extends StatelessWidget {
  const DarkroomTargetPanel({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.stackHeaderBelow = 0,
    this.padding = const EdgeInsets.fromLTRB(
      SkotiqTokens.spaceXl,
      SkotiqTokens.spaceMd,
      SkotiqTokens.spaceXl,
      SkotiqTokens.spaceMd,
    ),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  /// Narrower than this, a [trailing] wider than a button would crowd the
  /// title, so it goes on a line of its own.
  final double stackHeaderBelow;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: SkotiqTokens.borderRadiusLg,
        border: Border.all(color: colors.border),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final head = Row(
            children: [
              Text(
                title,
                style: SkotiqTypography.sectionTitle.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(width: SkotiqTokens.spaceMd),
                Flexible(
                  child: Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ],
          );
          final stacked =
              trailing != null && constraints.maxWidth < stackHeaderBelow;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (stacked) ...[
                head,
                const SizedBox(height: SkotiqTokens.spaceXs),
                Align(alignment: Alignment.centerLeft, child: trailing),
              ] else
                Row(
                  children: [
                    Expanded(child: head),
                    if (trailing != null) ...[
                      const SizedBox(width: SkotiqTokens.spaceLg),
                      trailing!,
                    ],
                  ],
                ),
              const SizedBox(height: SkotiqTokens.spaceXs),
              child,
            ],
          );
        },
      ),
    );
  }
}

typedef _Panel = DarkroomTargetPanel;
