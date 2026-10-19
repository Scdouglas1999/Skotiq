// The Camera tab (TonightCamera.dc.html): the cooler with its history, the
// capture values, the filter wheel and where the frames go.
//
// While a run is live the run owns the camera: the capture values are its
// active step's, read-only, with a way to the Sequencer (a running plan
// cannot be edited); the filter slots and the cooler controls are off, each
// saying why.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../data/session/session_format.dart';
import '../../data/session/session_series_provider.dart';
import '../../night_control_contracts.dart';
import '../panel_ops.dart';
import '../panel_widgets.dart';
import 'camera_capture_section.dart';
import 'camera_panel_vm.dart';

class NightCameraTab extends ConsumerWidget {
  const NightCameraTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(nightCameraPanelProvider);
    return NightPanelBody(
      children: <Widget>[
        NightCoolerSection(
          vm: vm,
          history: ref.watch(nightCoolerHistoryProvider),
        ),
        NightCaptureSection(vm: vm),
        NightFilterSection(vm: vm),
        NightReadoutSection(vm: vm),
      ],
    );
  }
}

/// Why a camera control is off, or null when it is on.
String? nightCameraBlockedReason(
  NightCameraPanelVm vm,
  SkotiqLocalizations l10n, {
  bool runOwns = true,
}) {
  if (!vm.canCommand) return l10n.text('nightActWhyNoHost');
  if (!vm.connected) return l10n.text('nightActWhyNoCamera');
  if (runOwns && vm.runLive) return l10n.text('nightActWhyRunOwns');
  return null;
}

/// "−10" or "−7.5": a setpoint as the field shows it.
String nightSetpointText(double value) =>
    nightFixed(value, value == value.roundToDouble() ? 0 : 1);

/// `−10.0°`: a cooler readout, short enough for a quarter of the panel.
String _degrees(double value) => '${nightFixed(value, 1)}°';

/// Reads a number typed with either minus sign; null when it is not one.
double? nightParseNumber(String text) {
  final value = double.tryParse(text.trim().replaceAll('−', '-'));
  return value != null && value.isFinite ? value : null;
}

class NightCoolerSection extends ConsumerStatefulWidget {
  const NightCoolerSection({
    super.key,
    required this.vm,
    required this.history,
  });

  final NightCameraPanelVm vm;
  final NightSeriesVm history;

  @override
  ConsumerState<NightCoolerSection> createState() => _NightCoolerSectionState();
}

class _NightCoolerSectionState extends ConsumerState<NightCoolerSection> {
  late final TextEditingController _setpoint;
  String? _error;

  @override
  void initState() {
    super.initState();
    final start = widget.vm.defaultSetpoint ?? widget.vm.setpoint;
    _setpoint = TextEditingController(
      text: start == null ? '' : nightSetpointText(start),
    );
  }

  @override
  void dispose() {
    _setpoint.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final l10n = SkotiqLocalizations.of(context);
    final value = nightParseNumber(_setpoint.text);
    if (value == null) {
      setState(() => _error = l10n.text('nightPanelEnterNumber'));
      return;
    }
    setState(() => _error = null);
    await nightPanelAttempt(
      context,
      'nightPanelErrCooler',
      () => ref.read(nightPanelOpsProvider).setCoolerSetpoint(value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final vm = widget.vm;
    final blocked = nightCameraBlockedReason(vm, l10n);
    final (String stateKey, MetricTone? tone) = switch (vm.coolerState) {
      NightCoolerState.notConnected => (
          'nightPanelCoolerNotConnected',
          MetricTone.warning,
        ),
      NightCoolerState.off => ('nightPanelCoolerOff', null),
      NightCoolerState.cooling => ('nightPanelCoolerCooling', null),
      NightCoolerState.atSetpoint => (
          'nightPanelCoolerAtSetpoint',
          MetricTone.good,
        ),
      NightCoolerState.warming => ('nightPanelCoolerWarming', null),
    };
    final title = vm.deviceName == null
        ? l10n.text('nightPanelCooler')
        : l10n.text(
            'nightPanelCoolerNamed',
            params: <String, String>{'name': vm.deviceName!},
          );
    final warmReason = blocked ??
        switch (vm.coolerState) {
          NightCoolerState.warming => l10n.text('nightPanelCoolerWarming'),
          NightCoolerState.off => l10n.text('nightPanelWhyCoolerOff'),
          _ => null,
        };

    return NightPanelSection(
      title: title,
      trailing: l10n.text(stateKey),
      trailingTone: tone,
      children: <Widget>[
        MetricGrid(
          semanticLabel: l10n.text('nightPanelCooler'),
          items: <MetricGridItem>[
            MetricGridItem(
              label: l10n.text('nightPanelSensor'),
              value: vm.sensorTemp == null ? null : _degrees(vm.sensorTemp!),
            ),
            MetricGridItem(
              label: l10n.text('nightPanelSetpoint'),
              value: vm.setpoint == null ? null : _degrees(vm.setpoint!),
            ),
            MetricGridItem(
              label: l10n.text('nightPanelPower'),
              value:
                  vm.coolerPower == null ? null : '${vm.coolerPower!.round()}%',
            ),
          ],
        ),
        if (!widget.history.isEmpty) _history(l10n),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(
              child: SkotiqTextField(
                controller: _setpoint,
                label: l10n.text('nightPanelSetpointField'),
                dense: true,
                mono: true,
                enabled: blocked == null,
                errorText: _error,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                ),
                onSubmitted: (_) => _apply(),
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceXs),
            SizedBox(
              width: 44,
              child: NightPanelButton(
                label: l10n.text('nightPanelSet'),
                semanticLabel: l10n.text('nightPanelSetSemantics'),
                disabledReason: blocked,
                onPressed: blocked == null ? _apply : null,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceXs),
            SizedBox(
              width: 70,
              child: NightPanelButton(
                label: l10n.text('nightPanelWarmUp'),
                disabledReason: warmReason,
                onPressed: warmReason == null
                    ? () => nightPanelAttempt(
                          context,
                          'nightPanelErrCooler',
                          () => ref.read(nightPanelOpsProvider).warmUpCamera(),
                        )
                    : null,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceXs),
            SizedBox(
              width: 44,
              child: NightPanelButton(
                label: l10n.text('nightPanelOff'),
                semanticLabel: l10n.text('nightPanelCoolerOffSemantics'),
                disabledReason: blocked,
                onPressed: blocked == null
                    ? () => nightPanelAttempt(
                          context,
                          'nightPanelErrCooler',
                          () => ref.read(nightPanelOpsProvider).coolerOff(),
                        )
                    : null,
              ),
            ),
          ],
        ),
        NightPanelNote(
          l10n.text(
            'nightPanelWarmUpNote',
            params: <String, String>{
              'rate': kNightWarmUpRatePerMin.round().toString(),
            },
          ),
        ),
      ],
    );
  }

  Widget _history(SkotiqLocalizations l10n) {
    final history = widget.history;
    final from = history.from;
    final since = from == null ? null : nightPanelClock(from);
    final latest = history.lines.first.points.lastOrNull?.y;
    final semantic = <String>[
      if (since != null)
        l10n.text(
          'nightPanelCoolerHistorySince',
          params: <String, String>{'time': since},
        )
      else
        l10n.text('nightPanelCoolerHistory'),
      if (latest != null)
        l10n.text(
          'nightPanelNowValue',
          params: <String, String>{'value': nightCelsius(latest)},
        ),
    ].join(', ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SeriesChart(
          height: 34,
          from: history.from,
          to: history.to,
          semanticLabel: semantic,
          lines: <SeriesChartLine>[
            for (final line in history.lines.take(SeriesChart.maxLines))
              SeriesChartLine(
                points: <(DateTime, double?)>[
                  for (final p in line.points) (p.t, p.y),
                ],
                tone: nightChartTone(line.tone),
                axis: line.secondaryAxis
                    ? SeriesChartAxis.right
                    : SeriesChartAxis.left,
                dashed: line.dashed,
                stepped: line.stepped,
              ),
          ],
        ),
        if (since != null) ...<Widget>[
          const SizedBox(height: 2),
          ExcludeSemantics(
            child: NightPanelNote(
              l10n.text(
                'nightPanelCoolerHistorySince',
                params: <String, String>{'time': since},
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The wheel's slots, the current filter and its focus offset.
class NightFilterSection extends ConsumerWidget {
  const NightFilterSection({super.key, required this.vm});

  final NightCameraPanelVm vm;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = SkotiqLocalizations.of(context);
    final filters = vm.filters;
    final count = filters.names.length;
    final current = filters.current;
    final name = filters.currentName;
    final String? trailing;
    if (!filters.connected) {
      trailing = l10n.text('nightPanelWheelNotConnected');
    } else if (current == null || count == 0) {
      trailing = null;
    } else if (name != null && name.isNotEmpty) {
      trailing = l10n.text(
        'nightPanelFilterSlot',
        params: <String, String>{
          'name': name,
          'slot': '${current + 1}',
          'count': '$count',
        },
      );
    } else {
      trailing = l10n.text(
        'nightPanelFilterSlotOnly',
        params: <String, String>{'slot': '${current + 1}', 'count': '$count'},
      );
    }

    final String? blocked;
    if (!vm.canCommand) {
      blocked = l10n.text('nightActWhyNoHost');
    } else if (!filters.connected) {
      blocked = l10n.text('nightPanelWheelNotConnected');
    } else if (vm.runLive) {
      blocked = l10n.text('nightPanelWhyRunFilter');
    } else if (filters.moving) {
      blocked = l10n.text('nightPanelWhyWheelMoving');
    } else {
      blocked = null;
    }

    final offset = filters.currentOffset;
    final reference = filters.referenceFilter;
    final String? offsetNote;
    if (name != null && reference != null && name == reference) {
      offsetNote = l10n.text(
        'nightPanelFocusReference',
        params: <String, String>{'filter': reference},
      );
    } else if (offset != null && reference != null) {
      offsetNote = l10n.text(
        'nightPanelFocusOffset',
        params: <String, String>{
          'offset': offset > 0 ? '+$offset' : nightGrouped(offset),
          'filter': reference,
        },
      );
    } else {
      offsetNote = null;
    }

    return NightPanelSection(
      title: l10n.text('nightPanelFilter'),
      trailing: trailing,
      trailingTone: filters.connected ? null : MetricTone.warning,
      children: <Widget>[
        if (count > 0)
          NightPanelGrid(
            columns: 4,
            children: <Widget>[
              for (var i = 0; i < count; i++)
                NightPanelButton(
                  label:
                      filters.names[i].isEmpty ? '${i + 1}' : filters.names[i],
                  semanticLabel: l10n.text(
                    'nightPanelFilterSlotSemantics',
                    params: <String, String>{
                      'name': filters.names[i].isEmpty
                          ? '${i + 1}'
                          : filters.names[i],
                      'slot': '${i + 1}',
                    },
                  ),
                  selected: i == current,
                  disabledReason: blocked,
                  onPressed: blocked == null && i != current
                      ? () => nightPanelAttempt(
                            context,
                            'nightPanelErrFilter',
                            () => ref
                                .read(nightPanelOpsProvider)
                                .setFilterSlot(i),
                          )
                      : null,
                ),
            ],
          ),
        if (vm.runLive && filters.connected && count > 0)
          NightPanelNote(l10n.text('nightPanelWhyRunFilter')),
        if (offsetNote != null) NightPanelNote(offsetNote),
      ],
    );
  }
}

/// Sensor, folder and disk.
class NightReadoutSection extends StatelessWidget {
  const NightReadoutSection({super.key, required this.vm});

  final NightCameraPanelVm vm;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final free = vm.diskFreeBytes;
    final nights = vm.nightsOfSpace;
    final String? disk = free == null
        ? null
        : nights == null
            ? l10n.text(
                'nightPanelDiskFree',
                params: <String, String>{'free': nightBytes(free)},
              )
            : l10n.text(
                'nightPanelDiskFreeNights',
                params: <String, String>{
                  'free': nightBytes(free),
                  'nights': '$nights',
                },
              );
    return NightPanelSection(
      title: l10n.text('nightPanelReadout'),
      divider: false,
      gap: SkotiqTokens.spaceXs,
      children: <Widget>[
        NightPanelRow(
            label: l10n.text('nightPanelSensor'), value: vm.sensorSpecs),
        NightPanelRow(label: l10n.text('nightPanelSavesTo'), value: vm.savesTo),
        NightPanelRow(label: l10n.text('nightPanelDisk'), value: disk),
      ],
    );
  }
}
