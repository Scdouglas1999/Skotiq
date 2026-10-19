// The Camera tab's Capture block.
//
// With no run live the fields are the manual exposure settings that
// Snapshot and Loop use, saved per equipment profile as the Imaging screen
// saves them. During a run they show the active step's values, read-only:
// a running plan cannot be edited (`canEditSequenceProvider`), so the block
// offers the Sequencer instead.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../../sequencer/sequencer_screen.dart' show kSequencerRoutePath;
import '../../actions/night_action_controller.dart';
import '../../night_control_contracts.dart';
import '../panel_ops.dart';
import '../panel_widgets.dart';
import 'camera_panel_vm.dart';

/// The frame types the block offers, in board order.
const List<FrameType> kNightCaptureFrameTypes = <FrameType>[
  FrameType.light,
  FrameType.dark,
  FrameType.flat,
  FrameType.bias,
];

/// N×N binnings the block offers.
const List<int> kNightCaptureBinnings = <int>[1, 2, 3, 4];

String _frameTypeKey(FrameType type) => switch (type) {
      FrameType.light => 'nightPanelFrameLight',
      FrameType.dark => 'nightPanelFrameDark',
      FrameType.flat => 'nightPanelFrameFlat',
      FrameType.bias => 'nightPanelFrameBias',
      FrameType.darkFlat => 'nightPanelFrameDarkFlat',
      FrameType.snapshot => 'nightPanelFrameSnapshot',
    };

String _seconds(double secs) =>
    secs == secs.roundToDouble() ? secs.round().toString() : secs.toString();

class NightCaptureSection extends ConsumerStatefulWidget {
  const NightCaptureSection({super.key, required this.vm});

  final NightCameraPanelVm vm;

  @override
  ConsumerState<NightCaptureSection> createState() =>
      _NightCaptureSectionState();
}

class _NightCaptureSectionState extends ConsumerState<NightCaptureSection> {
  final _exposure = TextEditingController();
  final _gain = TextEditingController();
  final _offset = TextEditingController();
  final _exposureFocus = FocusNode();
  final _gainFocus = FocusNode();
  final _offsetFocus = FocusNode();
  String? _exposureError;
  String? _gainError;
  String? _offsetError;

  @override
  void initState() {
    super.initState();
    _syncFields(force: true);
    for (final node in <FocusNode>[_exposureFocus, _gainFocus, _offsetFocus]) {
      node.addListener(() {
        if (!node.hasFocus) _commit();
      });
    }
  }

  @override
  void didUpdateWidget(NightCaptureSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.vm.manual != widget.vm.manual) _syncFields();
  }

  @override
  void dispose() {
    for (final c in <TextEditingController>[_exposure, _gain, _offset]) {
      c.dispose();
    }
    for (final n in <FocusNode>[_exposureFocus, _gainFocus, _offsetFocus]) {
      n.dispose();
    }
    super.dispose();
  }

  /// Copies the manual settings into the fields the operator is not typing
  /// in, so a profile switch shows its own values.
  void _syncFields({bool force = false}) {
    final manual = widget.vm.manual;
    if (manual == null) return;
    if (force || !_exposureFocus.hasFocus) {
      _exposure.text = _seconds(manual.exposureTime);
    }
    if (force || !_gainFocus.hasFocus) _gain.text = '${manual.gain}';
    if (force || !_offsetFocus.hasFocus) _offset.text = '${manual.offset}';
  }

  /// Validates the three fields and saves them when they changed.
  void _commit() {
    final manual = widget.vm.manual;
    if (manual == null || !mounted) return;
    final l10n = SkotiqLocalizations.of(context);
    final exposure = nightParsePositive(_exposure.text);
    final gain = int.tryParse(_gain.text.trim());
    final offset = int.tryParse(_offset.text.trim());
    setState(() {
      _exposureError =
          exposure == null ? l10n.text('nightPanelEnterSeconds') : null;
      _gainError =
          gain == null || gain < 0 ? l10n.text('nightPanelEnterWhole') : null;
      _offsetError = offset == null || offset < 0
          ? l10n.text('nightPanelEnterWhole')
          : null;
    });
    if (exposure == null || _gainError != null || _offsetError != null) return;
    final next = manual.copyWith(
      exposureTime: exposure,
      gain: gain,
      offset: offset,
    );
    if (next != manual) _update(next);
  }

  void _update(ExposureSettings next) =>
      ref.read(nightPanelOpsProvider).updateManualExposure(next);

  void _openSequencer() {
    final nodeId = widget.vm.stepNodeId;
    if (nodeId != null) {
      ref.read(selectedNodeIdProvider.notifier).state = nodeId;
    }
    GoRouter.maybeOf(context)?.go(kSequencerRoutePath);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final vm = widget.vm;
    final manual = vm.manual;
    final editable = manual != null && !vm.runLive && vm.canCommand;
    final values = vm.runLive
        ? vm.step
        : (manual == null ? null : NightCaptureValues.fromSettings(manual));
    final String? choiceBlocked = vm.runLive
        ? l10n.text('nightPanelWhyRunCapture')
        : !vm.canCommand
            ? l10n.text('nightActWhyNoHost')
            : null;
    final actions = <ManualActionId, ManualActionVm>{
      for (final action in ref.watch(nightManualActionsProvider))
        action.id: action,
    };

    final String trailing;
    if (vm.runLive) {
      trailing = vm.stepIndex == null
          ? l10n.text('nightPanelCaptureFromRun')
          : l10n.text(
              'nightPanelCaptureFromStep',
              params: <String, String>{'n': '${vm.stepIndex}'},
            );
    } else {
      trailing = l10n.text('nightPanelCaptureManual');
    }

    return NightPanelSection(
      title: l10n.text('nightPanelCapture'),
      trailing: trailing,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: editable
                  ? _field(
                      l10n.text('nightPanelExposureField'),
                      _exposure,
                      _exposureFocus,
                      _exposureError,
                      decimal: true,
                    )
                  : _ReadOnlyField(
                      label: l10n.text('nightPanelExposureField'),
                      value: values?.exposureSecs == null
                          ? null
                          : _seconds(values!.exposureSecs!),
                    ),
            ),
            const SizedBox(width: kNightPanelRowGap),
            Expanded(
              child: editable
                  ? _field(
                      l10n.text('nightPanelGain'),
                      _gain,
                      _gainFocus,
                      _gainError,
                    )
                  : _ReadOnlyField(
                      label: l10n.text('nightPanelGain'),
                      value: values?.gain?.toString(),
                    ),
            ),
            const SizedBox(width: kNightPanelRowGap),
            Expanded(
              child: editable
                  ? _field(
                      l10n.text('nightPanelOffset'),
                      _offset,
                      _offsetFocus,
                      _offsetError,
                    )
                  : _ReadOnlyField(
                      label: l10n.text('nightPanelOffset'),
                      value: values?.offset?.toString(),
                    ),
            ),
          ],
        ),
        NightPanelLabel(l10n.text('nightPanelFrame')),
        NightPanelGrid(
          columns: 4,
          children: <Widget>[
            for (final type in kNightCaptureFrameTypes)
              NightPanelButton(
                label: l10n.text(_frameTypeKey(type)),
                selected: values?.frameType == type,
                disabledReason: choiceBlocked,
                onPressed: editable && manual.frameType != type
                    ? () => _update(manual.copyWith(frameType: type))
                    : null,
              ),
          ],
        ),
        NightPanelLabel(l10n.text('nightPanelBinning')),
        NightPanelGrid(
          columns: 4,
          children: <Widget>[
            for (final bin in kNightCaptureBinnings)
              NightPanelButton(
                label: '$bin×$bin',
                selected: values?.binning == bin,
                disabledReason: choiceBlocked,
                onPressed: editable && values?.binning != bin
                    ? () => _update(
                          manual.copyWith(binningX: bin, binningY: bin),
                        )
                    : null,
              ),
          ],
        ),
        NightPanelGrid(
          columns: 2,
          children: <Widget>[
            for (final id in const <ManualActionId>[
              ManualActionId.snapshot,
              ManualActionId.loop,
            ])
              if (actions[id] case final action?)
                NightPanelButton(
                  label: action.label.resolve(l10n),
                  selected: action.running,
                  disabledReason: action.disabledReason?.resolve(l10n),
                  onPressed: action.enabled
                      ? () => ref.read(nightActionApiProvider).run(id)
                      : null,
                ),
          ],
        ),
        if (vm.runLive) ...<Widget>[
          NightPanelNote(
            switch ((vm.step, vm.stepLabel)) {
              (_?, final label?) => l10n.text(
                  'nightPanelCaptureRunNote',
                  params: <String, String>{'step': label},
                ),
              (null, final label?) => l10n.text(
                  'nightPanelCaptureNotExposure',
                  params: <String, String>{'step': label},
                ),
              (_, null) => l10n.text('nightPanelCaptureNoStep'),
            },
          ),
          NightPanelButton(
            label: l10n.text('nightPanelEditInSequencer'),
            onPressed: _openSequencer,
          ),
        ],
      ],
    );
  }

  Widget _field(
    String label,
    TextEditingController controller,
    FocusNode focus,
    String? error, {
    bool decimal = false,
  }) =>
      SkotiqTextField(
        controller: controller,
        focusNode: focus,
        label: label,
        dense: true,
        mono: true,
        errorText: error,
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        onSubmitted: (_) => _commit(),
      );
}

/// A positive finite number of seconds; null otherwise.
double? nightParsePositive(String text) {
  final value = double.tryParse(text.trim());
  return value != null && value.isFinite && value > 0 ? value : null;
}

/// A field's look without its editing: the run's value, read-only.
class _ReadOnlyField extends StatelessWidget {
  const _ReadOnlyField({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    return Semantics(
      label: label,
      value: value ?? l10n.text('nightPanelUnknown'),
      readOnly: true,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Container(
            height: SkotiqTokens.inputHeightSm,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceSm,
            ),
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
              border: Border.all(color: colors.border),
            ),
            child: Text(
              value ?? kReadoutUnknown,
              style: SkotiqTypography.monoSm.copyWith(
                color: value == null ? colors.textMuted : colors.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
