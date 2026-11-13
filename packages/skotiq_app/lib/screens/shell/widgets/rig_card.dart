import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../utils/device_format_utils.dart';
import '../../../utils/device_type_ui.dart';
import 'operation_status_bar.dart';
import '../../../router/settings_sections.dart';
import '../../../utils/guide_distance.dart';
import '../../../router/app_routes.dart';

/// What the shell actually knows about the configured capture directory.
///
/// [unknown] is a first-class answer: settings may still be loading, or the
/// existence probe may have failed (a remote host that did not answer). It must
/// never be collapsed into [missing] — "your output path is gone" is an alarm,
/// and raising it because a check has not finished yet is a lie.
enum SavePathExistence { unknown, present, missing }

@visibleForTesting
class SavePathStatus {
  final String path;
  final SavePathExistence existence;

  const SavePathStatus({
    required this.path,
    required this.existence,
  });
}

final _savePathStatusProvider = FutureProvider<SavePathStatus>((ref) async {
  final settings = await ref.watch(appSettingsProvider.future);
  final savePath = settings.imageOutputPath.trim();

  if (savePath.isEmpty) {
    // Genuinely nothing configured — that IS the finding, not an unknown.
    return const SavePathStatus(
      path: '',
      existence: SavePathExistence.missing,
    );
  }

  final backend = ref.watch(backendProvider);
  try {
    final exists = await configuredSavePathExists(backend, savePath);
    return SavePathStatus(
      path: savePath,
      existence: exists ? SavePathExistence.present : SavePathExistence.missing,
    );
  } catch (_) {
    // The probe itself failed (remote host unreachable, permission error). We
    // do not know whether the directory is there.
    return SavePathStatus(
      path: savePath,
      existence: SavePathExistence.unknown,
    );
  }
});

/// How confident the save-path row is allowed to look.
enum SavePathTone {
  /// Verified: the configured directory is there.
  ok,

  /// Not assessed (probe unfinished or failed). Neutral — never an alarm.
  unknown,

  /// Known bad: nothing configured, or the configured directory is gone.
  alarm,
}

/// The save-path row's rendering, derived from what is actually known.
@visibleForTesting
class SavePathChip {
  final String label;
  final String tooltip;
  final SavePathTone tone;

  const SavePathChip({
    required this.label,
    required this.tooltip,
    required this.tone,
  });
}

/// Maps the async save-path probe onto row text.
///
/// Pure and directly testable. A PENDING probe is not a missing path:
/// defaulting an unresolved [AsyncValue] to `exists: false` claims "No save
/// path" with the alarm icon on a rig whose path is configured and fine — for a
/// full network round-trip on a remote backend, and permanently for a probe
/// that threw.
@visibleForTesting
SavePathChip savePathChipFor(
  AsyncValue<SavePathStatus> status,
  String Function(String path) formatLabel,
  SkotiqLocalizations l10n,
) {
  final value = status.valueOrNull;
  if (value == null) {
    // Not assessed yet (or the provider itself failed): say so.
    return SavePathChip(
      label: status.hasError
          ? l10n.text('statusSavePathUnreadable')
          : l10n.text('statusSavePathChecking'),
      tooltip: status.hasError
          ? l10n.text('statusSavePathUnreadableTooltip')
          : l10n.text('statusSavePathCheckingTooltip'),
      tone: SavePathTone.unknown,
    );
  }
  if (value.path.isEmpty) {
    return SavePathChip(
      label: l10n.text('statusNoSavePath'),
      tooltip: l10n.text('statusNoSavePathTooltip'),
      tone: SavePathTone.alarm,
    );
  }
  final label = formatLabel(value.path);
  switch (value.existence) {
    case SavePathExistence.present:
      return SavePathChip(
        label: label,
        tooltip: l10n.text(
          'statusSavePathOkTooltip',
          params: {'path': value.path},
        ),
        tone: SavePathTone.ok,
      );
    case SavePathExistence.missing:
      return SavePathChip(
        label: label,
        tooltip: l10n.text(
          'statusSavePathMissingTooltip',
          params: {'path': value.path},
        ),
        tone: SavePathTone.alarm,
      );
    case SavePathExistence.unknown:
      return SavePathChip(
        label: label,
        tooltip: l10n.text(
          'statusSavePathUnknownTooltip',
          params: {'path': value.path},
        ),
        tone: SavePathTone.unknown,
      );
  }
}

/// Checks the configured capture directory on the machine that performs the
/// capture. A remote controller cannot infer host-path validity from its own
/// filesystem.
Future<bool> configuredSavePathExists(
  SkotiqBackend backend,
  String savePath,
) async {
  if (backend.remoteHost case final linkedHost?) {
    final validation = await linkedHost.files.validateRemoteDirectory(
      savePath,
      mustExist: true,
      mustBeWritable: false,
    );
    return validation['valid'] == true;
  }
  return Directory(savePath).exists();
}

/// The Rig card: the sidebar's pinned footer and the window's one persistent
/// status surface. First line is the run state; below it, one row per device
/// with a status dot; then the save path and — while one is in flight — the
/// operation strip.
///
/// Expanded it is a card of labelled rows; collapsed to the 64 px rail it is
/// a rig summary that opens the full device list beside the rail.
class RigCard extends ConsumerWidget {
  /// Whether the enclosing sidebar is expanded (shows labels).
  final bool isExpanded;

  const RigCard({super.key, required this.isExpanded});

  /// Row height inside the card: icon, dot and text have air without pushing
  /// the card taller than the rail has room for.
  static const double rowHeight = 26.0;

  static const double _dotSize = 7.0;

  /// The four devices the card always lists, present or not.
  static const Set<DeviceType> _alwaysListed = {
    DeviceType.camera,
    DeviceType.mount,
    DeviceType.guider,
    DeviceType.focuser,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;

    // A device publishes far more than this card shows. A tracking mount emits
    // a fresh position every 2 s, and a whole-object watch turned each one
    // into a rebuild of the shell — which on Flutter's Linux embedder is a
    // full-window frame, because that embedder has no damage region and
    // repaints everything for any dirty frame. The card is on every screen,
    // so that was an idle frame every 2 s in the whole app.
    //
    // Select only the fields rendered below. Records compare structurally, so
    // the card rebuilds when one of THESE changes and not before.
    final cameraState = ref.watch(
      cameraStateProvider.select(
        (s) => (
          connectionState: s.connectionState,
          deviceName: s.deviceName,
          deviceId: s.deviceId,
          temperature: s.temperature,
        ),
      ),
    );
    final mountState = ref.watch(
      mountStateProvider.select(
        (s) => (
          connectionState: s.connectionState,
          deviceName: s.deviceName,
          deviceId: s.deviceId,
        ),
      ),
    );
    final guiderState = ref.watch(
      guiderStateProvider.select(
        (s) => (
          connectionState: s.connectionState,
          isGuiding: s.isGuiding,
          rmsTotal: s.rmsTotal,
        ),
      ),
    );
    final guideScale = ref.watch(guideScaleProvider);
    final focuserState = ref.watch(
      focuserStateProvider.select(
        (s) => (connectionState: s.connectionState, position: s.position),
      ),
    );
    // The name is resolved inside the selector rather than selected alongside
    // `filterNames`: a record holding that list would compare by identity and
    // defeat the whole point of selecting.
    final filterWheelState = ref.watch(
      filterWheelStateProvider.select(
        (s) => (
          connectionState: s.connectionState,
          filterName: _currentFilterName(s),
        ),
      ),
    );

    final cameraConnected =
        cameraState.connectionState == DeviceConnectionState.connected;
    final mountConnected =
        mountState.connectionState == DeviceConnectionState.connected;
    final guiderConnected =
        guiderState.connectionState == DeviceConnectionState.connected;
    final focuserConnected =
        focuserState.connectionState == DeviceConnectionState.connected;
    final rotatorState = ref.watch(
      rotatorStateProvider.select(
        (s) => (connectionState: s.connectionState, position: s.position),
      ),
    );
    final rig = ref.watch(rigDevicesProvider);

    // The row's VALUE is the device name, or the phrase for its absence —
    // never "Camera: ASI2600MM". The glyph carries the role; spelling it out
    // again spends half a row saying what the icon said.
    //
    // The accessible NAME has to carry the role, because a screen reader has
    // no glyph: "Camera, Simulated Camera" / "Camera, not connected".
    final cameraValue = cameraConnected
        ? _deviceDisplayName(
            cameraState.deviceName,
            cameraState.deviceId,
            l10n.text('statusConnected'),
          )
        : l10n.text('statusNoCamera');
    final mountValue = mountConnected
        ? _deviceDisplayName(
            mountState.deviceName,
            mountState.deviceId,
            l10n.text('statusConnected'),
          )
        : l10n.text('statusNoMount');
    final guiderValue = guiderConnected
        ? (guiderState.isGuiding
            ? l10n.text('guiding')
            : l10n.text('statusReady'))
        : l10n.text('statusNoGuider');
    final focuserValue = focuserConnected
        ? (focuserState.position?.toString() ?? l10n.text('statusReady'))
        : l10n.text('statusNoFocuser');

    final deviceRows = <Widget>[
      _RigRow(
        icon: SkotiqIcons.camera,
        dotTone: _connectionTone(cameraState.connectionState),
        value: cameraValue,
        semanticLabel: deviceRowSemanticLabel(
          l10n.text('statusCamera'),
          connected: cameraConnected,
          value: cameraValue,
          l10n: l10n,
        ),
        isExpanded: true,
        isMenuItem: !isExpanded,
        route: AppRoute.equipment.path,
        // Only for a COOLED camera: a DSLR has no sensor setpoint, and an em
        // dash where a temperature should be is a permanent question.
        trailing: cameraConnected && cameraState.temperature != null
            ? formatCelsius(cameraState.temperature!)
            : null,
        trailingSemanticLabel: cameraConnected &&
                cameraState.temperature != null
            ? 'Sensor temperature '
                '${cameraState.temperature!.toStringAsFixed(1)} degrees Celsius'
            : null,
      ),
      _RigRow(
        icon: LucideIcons.mountain,
        dotTone: _connectionTone(mountState.connectionState),
        value: mountValue,
        semanticLabel: deviceRowSemanticLabel(
          l10n.text('mount'),
          connected: mountConnected,
          value: mountValue,
          l10n: l10n,
        ),
        isExpanded: true,
        isMenuItem: !isExpanded,
        route: AppRoute.equipment.path,
      ),
      _RigRow(
        icon: SkotiqIcons.crosshair,
        dotTone: _connectionTone(guiderState.connectionState),
        // "Idle" here used to mean "no guider" — the same word the app uses
        // for a connected, ready guider that simply is not guiding. At a
        // glance the strip said the guider was present and calm when there
        // was no guider at all.
        value: guiderValue,
        semanticLabel: deviceRowSemanticLabel(
          l10n.text('statusGuider'),
          connected: guiderConnected,
          value: guiderValue,
          l10n: l10n,
        ),
        isExpanded: true,
        isMenuItem: !isExpanded,
        route: AppRoute.guiding.path,
        // Guiding RMS is the one live figure a guiding row can carry that
        // the glyph cannot; it trails the word the way temperature trails
        // the camera's name.
        trailing: guiderConnected &&
                guiderState.isGuiding &&
                guiderState.rmsTotal != null
            ? guideDistanceText(guiderState.rmsTotal!, guideScale)
            : null,
        trailingSemanticLabel: guiderConnected &&
                guiderState.isGuiding &&
                guiderState.rmsTotal != null
            ? 'Guiding RMS '
                '${guideDistanceSpoken(guiderState.rmsTotal!, guideScale)}'
            : null,
      ),
      _RigRow(
        icon: SkotiqIcons.focuser,
        dotTone: _connectionTone(focuserState.connectionState),
        // The POSITION, not the word "Ready": a focuser's position is the one
        // thing about it worth a permanent slot in the chrome.
        value: focuserValue,
        semanticLabel: deviceRowSemanticLabel(
          l10n.text('focus'),
          connected: focuserConnected,
          value: focuserValue,
          l10n: l10n,
        ),
        isExpanded: true,
        isMenuItem: !isExpanded,
        route: AppRoute.equipment.path,
        mono: focuserConnected && focuserState.position != null,
        trailingChild: const _TempCompMark(),
      ),
      // Optional equipment has a row when it is part of the rig: the active
      // profile assigns it, or it is connected. A permanent "No filter wheel"
      // on a rig that has never had one reports the absence of something
      // nobody asked for; hiding a profile's filter wheel while it is down
      // made the card count fewer devices than the profile holds.
      for (final device in rig.devices)
        if (!_alwaysListed.contains(device.type))
          _OptionalDeviceRow(
            type: device.type,
            isMenuItem: !isExpanded,
            filterName: filterWheelState.filterName,
            rotatorPosition: rotatorState.position,
          ),
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(
        isExpanded ? SkotiqTokens.spaceMd : SkotiqTokens.spaceXs,
        0,
        isExpanded ? SkotiqTokens.spaceMd : SkotiqTokens.spaceXs,
        SkotiqTokens.spaceMd,
      ),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: 'Rig',
        child: Container(
          // A well on the `surface` sidebar: recessed, because the card is a
          // report pinned under the controls, not a panel asking to be tapped.
          decoration: SkotiqDecorations.well(colors).copyWith(
            borderRadius: SkotiqTokens.borderRadiusLg,
          ),
          padding: EdgeInsets.symmetric(
            horizontal:
                isExpanded ? SkotiqTokens.spaceSm : SkotiqTokens.spaceXs,
            vertical: SkotiqTokens.spaceSm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _RunStateRow(isExpanded: isExpanded),
              if (isExpanded)
                ...deviceRows
              else
                _RigSummary(
                  connectedCount: rig.connected,
                  totalCount: rig.total,
                  deviceRows: deviceRows,
                ),
              _SavePathRow(isExpanded: isExpanded),
              const OperationStatusBar(),
            ],
          ),
        ),
      ),
    );
  }

  String? _currentFilterName(FilterWheelState state) {
    final position = state.currentPosition;
    if (position == null) return null;
    if (position < 0 || position >= state.filterNames.length) return null;
    final name = state.filterNames[position].trim();
    return name.isEmpty ? null : name;
  }

  String _deviceDisplayName(
    String? deviceName,
    String? deviceId,
    String fallback,
  ) {
    if (deviceName != null && deviceName.isNotEmpty) return deviceName;
    if (deviceId != null && deviceId.isNotEmpty) {
      return formatDeviceId(deviceId);
    }
    return fallback;
  }

  InstrumentTone _connectionTone(DeviceConnectionState state) =>
      state == DeviceConnectionState.connected
          ? InstrumentTone.success
          : InstrumentTone.idle;
}

/// A row for a device the card lists only while it is part of the rig.
class _OptionalDeviceRow extends ConsumerWidget {
  final DeviceType type;
  final bool isMenuItem;
  final String? filterName;
  final double? rotatorPosition;

  const _OptionalDeviceRow({
    required this.type,
    required this.isMenuItem,
    required this.filterName,
    required this.rotatorPosition,
  });

  /// The phrase for the device's absence, named like the always-listed
  /// four: a column of rows all reading "Disconnected" says which state
  /// every device is in and which device none of them is.
  String get _absentKey => switch (type) {
        DeviceType.camera => 'statusNoCamera',
        DeviceType.mount => 'statusNoMount',
        DeviceType.guider => 'statusNoGuider',
        DeviceType.focuser => 'statusNoFocuser',
        DeviceType.filterWheel => 'statusNoFilterWheel',
        DeviceType.rotator => 'statusNoRotator',
        DeviceType.dome => 'statusNoDome',
        DeviceType.weather => 'statusNoWeather',
        DeviceType.safetyMonitor => 'statusNoSafetyMonitor',
        DeviceType.switch_ => 'statusNoSwitch',
        DeviceType.coverCalibrator => 'statusNoCoverCalibrator',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final slot = ref.watch(
      type.slot.state.select(
        (s) => (connectionState: s.connectionState, deviceName: s.deviceName),
      ),
    );
    final connected = slot.connectionState == DeviceConnectionState.connected;
    final ready = l10n.text('statusReady');
    final value = !connected
        ? l10n.text(_absentKey)
        : switch (type) {
            DeviceType.filterWheel => filterName ?? ready,
            DeviceType.rotator => rotatorPosition == null
                ? ready
                : '${rotatorPosition!.toStringAsFixed(1)}°',
            _ => slot.deviceName ?? ready,
          };
    final role = type == DeviceType.filterWheel
        ? l10n.text('statusFilterWheel')
        : type.displayName;
    return _RigRow(
      icon: type.icon,
      dotTone: connected ? InstrumentTone.success : InstrumentTone.idle,
      value: value,
      semanticLabel: deviceRowSemanticLabel(
        role,
        connected: connected,
        value: value,
        l10n: l10n,
      ),
      isExpanded: true,
      isMenuItem: isMenuItem,
      route: AppRoute.equipment.path,
    );
  }
}

class _RigSummary extends StatefulWidget {
  /// From [rigDevicesProvider], not from the rows: the card always lists a
  /// camera, mount, guider and focuser, whether or not the rig has them.
  final int connectedCount;
  final int totalCount;
  final List<Widget> deviceRows;

  const _RigSummary({
    required this.connectedCount,
    required this.totalCount,
    required this.deviceRows,
  });

  @override
  State<_RigSummary> createState() => _RigSummaryState();
}

class _RigSummaryState extends State<_RigSummary> {
  final _buttonFocusNode = FocusNode();

  @override
  void dispose() {
    _buttonFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connectedCount = widget.connectedCount;
    final deviceRows = widget.deviceRows;
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    final totalCount = widget.totalCount;
    final missingCount = totalCount - connectedCount;
    final label = '${l10n.text('navEquipment')}: '
        '$connectedCount ${l10n.text('statusConnected').toLowerCase()}, '
        '$missingCount ${l10n.text('disconnected').toLowerCase()}';
    final color = connectedCount == 0
        ? colors.textMuted
        : missingCount == 0
            ? colors.success
            : colors.warning;

    return MenuAnchor(
      childFocusNode: _buttonFocusNode,
      alignmentOffset: const Offset(60, 0),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(colors.surface),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: SkotiqTokens.borderRadiusLg,
            side: BorderSide(color: colors.border),
          ),
        ),
      ),
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Text(l10n.text('navEquipment'),
              style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted)),
        ),
        ...deviceRows,
      ],
      builder: (context, controller, child) => Tooltip(
        message: label,
        child: Semantics(
          label: label,
          child: IconButton(
            key: const ValueKey('rig.summary'),
            focusNode: _buttonFocusNode,
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            padding: const EdgeInsets.symmetric(vertical: 6),
            constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
            icon: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.plug, size: 20, color: color),
                  const SizedBox(height: 4),
                  Text('$connectedCount/$totalCount',
                      style:
                          SkotiqTypography.monoCaption.copyWith(color: color)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a rig row is called to assistive tech.
///
/// "Camera, Simulated Camera" when there is one; "Camera, not connected" when
/// there is not. The row itself renders only the value, because the glyph says
/// which device it is — but a glyph is not a name, so the role has to be
/// spelled out here.
String deviceRowSemanticLabel(
  String role, {
  required bool connected,
  required String value,
  required SkotiqLocalizations l10n,
}) {
  return connected
      ? '$role, $value'
      : '$role, ${l10n.text('disconnected').toLowerCase()}';
}

/// One fact in the Rig card: glyph, state dot, value, optional trailing
/// readout. A row, not a pill — full width so the tap target is the whole
/// line the operator is reading.
///
/// Collapsed it is the same fact as a centred glyph with the dot riding its
/// corner; the tooltip then carries the sentence the value used to say.
class _RigRow extends StatefulWidget {
  final IconData icon;
  final InstrumentTone dotTone;
  final String value;
  final bool isExpanded;
  final String? route;
  final String? semanticLabel;
  final String? tooltipMessage;
  final String? trailing;
  final String? trailingSemanticLabel;
  final Widget? trailingChild;
  final bool mono;
  final bool isMenuItem;

  const _RigRow({
    required this.icon,
    required this.dotTone,
    required this.value,
    required this.isExpanded,
    this.route,
    this.semanticLabel,
    this.tooltipMessage,
    this.trailing,
    this.trailingSemanticLabel,
    this.trailingChild,
    this.mono = false,
    this.isMenuItem = false,
  });

  @override
  State<_RigRow> createState() => _RigRowState();
}

class _RigRowState extends State<_RigRow> {
  bool _isHovered = false;

  void _go(BuildContext context) {
    final route = widget.route;
    if (route == null) return;
    try {
      context.go(route);
    } catch (_) {
      // A row that cannot navigate is inert, not broken; the card keeps
      // reporting either way.
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final baseLabel = widget.semanticLabel ?? widget.value;
    final label = widget.trailingSemanticLabel != null
        ? '$baseLabel, ${widget.trailingSemanticLabel}'
        : baseLabel;

    Widget row;
    if (widget.isExpanded) {
      row = Container(
        height: RigCard.rowHeight,
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceXs,
        ),
        decoration: BoxDecoration(
          color: _isHovered && widget.route != null
              ? colors.surfaceHover
              : Colors.transparent,
          borderRadius: SkotiqTokens.borderRadiusXs,
        ),
        child: Row(
          children: [
            Icon(
              widget.icon,
              size: InstrumentPill.iconSize,
              color: colors.textMuted,
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            _StateDot(tone: widget.dotTone),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                widget.value,
                style: (widget.mono
                        ? SkotiqTypography.monoCaption
                        : SkotiqTypography.bodySm)
                    .copyWith(color: colors.textSecondary),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            if (widget.trailing != null)
              Text(
                widget.trailing!,
                style: SkotiqTypography.monoCaption.copyWith(
                  color: colors.textMuted,
                ),
              ),
            if (widget.trailingChild != null) ...[
              const SizedBox(width: SkotiqTokens.spaceXs),
              widget.trailingChild!,
            ],
          ],
        ),
      );
    } else {
      row = SizedBox(
        height: 32,
        child: Center(
          child: SizedBox(
            width: 32,
            height: 32,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _isHovered && widget.route != null
                        ? colors.surfaceHover
                        : Colors.transparent,
                    borderRadius: SkotiqTokens.borderRadiusXs,
                  ),
                  child: Icon(
                    widget.icon,
                    size: InstrumentPill.iconSize,
                    color: colors.textSecondary,
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: _StateDot(tone: widget.dotTone),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (widget.isMenuItem) {
      return Semantics(
        label: label,
        child: MenuItemButton(
          onPressed: widget.route != null ? () => _go(context) : null,
          style: const ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size(264, 40)),
          ),
          child: ExcludeSemantics(child: SizedBox(width: 240, child: row)),
        ),
      );
    }

    Widget result = Semantics(
      button: widget.route != null,
      enabled: widget.route != null,
      label: label,
      child: MouseRegion(
        cursor: widget.route != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.route != null ? () => _go(context) : null,
          child: ExcludeSemantics(child: row),
        ),
      ),
    );
    // Collapsed, the tooltip is the sentence the row no longer has room to
    // say; expanded, the value is on screen and a tooltip repeating it is
    // noise — except when the row was given a real message (the save path's
    // full-path tooltip).
    final message =
        widget.tooltipMessage ?? (widget.isExpanded ? null : baseLabel);
    if (message != null && message.isNotEmpty) {
      result = Tooltip(message: message, child: result);
    }
    return result;
  }
}

/// The 7 px state dot the card's rows share — the same size and tones the
/// instrument pills used, so "is it happy" reads the same way it always did.
class _StateDot extends StatelessWidget {
  final InstrumentTone tone;
  final bool live;

  const _StateDot({required this.tone, this.live = false});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final color = switch (tone) {
      InstrumentTone.idle => colors.textMuted,
      InstrumentTone.primary => colors.primary,
      InstrumentTone.success => colors.success,
      InstrumentTone.warning => colors.warning,
      InstrumentTone.error => colors.error,
    };
    return Container(
      width: RigCard._dotSize,
      height: RigCard._dotSize,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        // A ring, not a pulse. This dot is on screen on every route, and an
        // animated dot repaints the card at ~60 Hz for the length of a run to
        // produce a fade nobody is watching.
        border: live
            ? Border.all(
                color: color.withValues(
                  alpha: SkotiqTokens.opacitySelectedRing,
                ),
                width: 2,
                strokeAlign: BorderSide.strokeAlignOutside,
              )
            : null,
      ),
    );
  }
}

/// The run-state row — the card's first line and the app's one answer to "is
/// it running?". Tap opens the sequencer.
class _RunStateRow extends ConsumerStatefulWidget {
  final bool isExpanded;

  const _RunStateRow({required this.isExpanded});

  @override
  ConsumerState<_RunStateRow> createState() => _RunStateRowState();
}

class _RunStateRowState extends ConsumerState<_RunStateRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = SkotiqColors.of(context);
    final executionState = ref.watch(sequenceExecutionStateProvider);
    // Watch what is DISPLAYED. While a run is in flight the executor
    // republishes progress every second, and most of what moves in it —
    // elapsed seconds, the smoothed ETA — is not on this row. Whole-watching
    // it rebuilt the row once a second for the length of a night, and on an
    // embedder with no damage region that is a full-window repaint each time.
    //
    // The percentage is rounded INSIDE the selector, so the row rebuilds when
    // the integer it prints changes, not when the underlying double drifts.
    final progress = ref.watch(
      sequenceProgressProvider.select(
        (p) => (
          hasExposures: p.totalExposures > 0,
          percent: (p.progressPercent * 100).round(),
          currentTarget: p.currentTarget ?? '',
          currentNodeName: p.currentNodeName ?? '',
          message: p.message ?? '',
        ),
      ),
    );
    final statusText = _statusText(executionState, l10n);
    final isRunning = executionState == SequenceExecutionState.running;
    final progressPercent = progress.hasExposures ? progress.percent : null;
    // The percentage rides on the row only while a run is actually in
    // flight; "Completed 100%" and "Idle 0%" are two words where one is true.
    final displayText = progressPercent != null &&
            executionState != SequenceExecutionState.idle &&
            executionState != SequenceExecutionState.completed &&
            executionState != SequenceExecutionState.failed
        ? '$statusText $progressPercent%'
        : statusText;
    final tooltipLines = <String>[
      statusText,
      if (progress.currentTarget.isNotEmpty)
        l10n.text(
          'statusSequenceTarget',
          params: {'name': progress.currentTarget},
        ),
      if (progress.currentNodeName.isNotEmpty)
        l10n.text(
          'statusSequenceStep',
          params: {'name': progress.currentNodeName},
        ),
      if (progress.message.isNotEmpty) progress.message,
    ];

    void open() {
      try {
        context.go(AppRoute.sequencer.path);
      } catch (_) {
        // Same rule as the device rows: a row that cannot navigate is inert.
      }
    }

    final dot = _StateDot(tone: _tone(executionState), live: isRunning);
    final label = 'Sequence, $displayText';
    final tooltipMessage = tooltipLines.join('\n');

    if (!widget.isExpanded) {
      // Collapsed the row is a state dot on the sequencer glyph — the rail's
      // language for "look here" — with the tooltip carrying the sentence.
      return Semantics(
        button: true,
        enabled: true,
        label: label,
        child: Tooltip(
          message: tooltipMessage,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: open,
              child: ExcludeSemantics(
                child: SizedBox(
                  height: RigCard.rowHeight + 6,
                  child: Center(
                    child: SizedBox(
                      width: 32,
                      height: 32,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Icon(
                            SkotiqIcons.listOrdered,
                            size: InstrumentPill.iconSize,
                            color: colors.textSecondary,
                          ),
                          Positioned(top: 3, right: 3, child: dot),
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

    return Semantics(
      button: true,
      enabled: true,
      label: label,
      child: Tooltip(
        message: tooltipMessage,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: GestureDetector(
            onTap: open,
            child: ExcludeSemantics(
              child: Container(
                height: RigCard.rowHeight + 2,
                padding: const EdgeInsets.symmetric(
                  horizontal: SkotiqTokens.spaceXs,
                ),
                decoration: BoxDecoration(
                  color: _isHovered ? colors.surfaceHover : Colors.transparent,
                  borderRadius: SkotiqTokens.borderRadiusXs,
                ),
                child: Row(
                  children: [
                    dot,
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    Expanded(
                      child: Text(
                        displayText,
                        style: SkotiqTypography.bodyStrong.copyWith(
                          color: isRunning
                              ? colors.textPrimary
                              : colors.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  InstrumentTone _tone(SequenceExecutionState state) {
    switch (state) {
      case SequenceExecutionState.idle:
        return InstrumentTone.idle;
      case SequenceExecutionState.running:
        return InstrumentTone.success;
      case SequenceExecutionState.paused:
        return InstrumentTone.warning;
      case SequenceExecutionState.stopping:
        return InstrumentTone.error;
      case SequenceExecutionState.completed:
        return InstrumentTone.primary;
      case SequenceExecutionState.failed:
        return InstrumentTone.error;
      case SequenceExecutionState.recovering:
        // Recovery is its own visible state. The error colour says
        // "something is wrong, the sequence is fighting through it" — the
        // same colour as the recovery banner.
        return InstrumentTone.error;
      case SequenceExecutionState.stopFailed:
        // Native stop failed — hardware may still be imaging.
        return InstrumentTone.error;
      case SequenceExecutionState.cleanupFailed:
        // Hardware stopped; session save failed and needs a retry.
        return InstrumentTone.warning;
      case SequenceExecutionState.finalizing:
        // Run ended, durable cleanup wrapping up — calm, transient.
        return InstrumentTone.primary;
    }
  }

  String _statusText(SequenceExecutionState state, SkotiqLocalizations l10n) {
    switch (state) {
      case SequenceExecutionState.idle:
        return l10n.text('idle');
      case SequenceExecutionState.running:
        return l10n.text('sequenceRunning');
      case SequenceExecutionState.paused:
        return l10n.text('sequencePaused');
      case SequenceExecutionState.stopping:
        return l10n.text('statusSequenceStopping');
      case SequenceExecutionState.completed:
        return l10n.text('statusSequenceCompleted');
      case SequenceExecutionState.failed:
        return l10n.text('statusSequenceFailed');
      case SequenceExecutionState.recovering:
        return l10n.text('statusSequenceRecovering');
      case SequenceExecutionState.stopFailed:
        return l10n.text('statusSequenceStopFailed');
      case SequenceExecutionState.cleanupFailed:
        return l10n.text('statusSequenceCleanupFailed');
      case SequenceExecutionState.finalizing:
        return l10n.text('statusSequenceFinalizing');
    }
  }
}

/// The save-path row: where frames land, and whether there is room for
/// tonight's. Tap opens Settings → Storage.
class _SavePathRow extends ConsumerWidget {
  final bool isExpanded;

  const _SavePathRow({required this.isExpanded});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chip = savePathChipFor(
      ref.watch(_savePathStatusProvider),
      _formatPathLabel,
      context.l10n,
    );
    final freeText = ref.watch(captureDirDiskSpaceProvider.select(freeSpaceText));
    final free = freeText == null ? null : '$freeText free';
    // No free-space figure next to a path we know is unusable: "No save folder
    // · 412 GB free" reports room in a place that does not exist.
    final value = chip.tone == SavePathTone.alarm || free == null
        ? chip.label
        : '${chip.label} · $free';

    return _RigRow(
      // The folder-X alarm is reserved for a path we KNOW is unusable. "Not
      // checked yet" / "could not verify" gets the neutral search folder, so
      // an unfinished probe never reads as a broken rig.
      icon: switch (chip.tone) {
        SavePathTone.ok => LucideIcons.hardDrive,
        SavePathTone.alarm => LucideIcons.folderX,
        SavePathTone.unknown => LucideIcons.folderSearch,
      },
      dotTone: switch (chip.tone) {
        SavePathTone.ok => InstrumentTone.success,
        SavePathTone.alarm => InstrumentTone.error,
        SavePathTone.unknown => InstrumentTone.idle,
      },
      value: value,
      semanticLabel: chip.tooltip,
      tooltipMessage: chip.tooltip,
      isExpanded: isExpanded,
      route: AppRoutes.settings(SettingsSectionId.filesStorage),
    );
  }

  String _formatPathLabel(String path) {
    final normalized = p.normalize(path);
    final baseName = p.basename(normalized);
    return baseName.isNotEmpty ? baseName : normalized;
  }
}

/// The temperature-compensation mark on the focuser row — a small "TC" whose
/// dot says whether the model behind it is off, unreliable, or compensating.
/// Only visible when the focuser is connected and reports temperature.
class _TempCompMark extends ConsumerWidget {
  const _TempCompMark();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    // Connection and temperature only: a focuser that is stepping publishes a
    // new position on every move, and this mark is mounted on every screen, so
    // a whole-object watch made each step dirty the shell.
    final focuserState = ref.watch(
      focuserStateProvider.select(
        (s) => (connectionState: s.connectionState, temperature: s.temperature),
      ),
    );
    final focuserConnected =
        focuserState.connectionState == DeviceConnectionState.connected;

    if (!focuserConnected || focuserState.temperature == null) {
      return const SizedBox.shrink();
    }

    final settingsAsync = ref.watch(appSettingsProvider);
    final settings = settingsAsync.valueOrNull;
    final tempCompEnabled = settings?.tempCompensation ?? false;

    final activeProfile = ref.watch(activeEquipmentProfileProvider);
    if (activeProfile == null) return const SizedBox.shrink();

    final profileId = activeProfile.id.toString();
    final focusService = ref.watch(focusModelServiceProvider);
    final profileData = focusService.getProfileData(profileId);
    final model = profileData?.temperatureModel;
    final hasReliableModel = model != null && model.isReliable;

    InstrumentTone indicatorTone;
    String tooltip;

    if (!tempCompEnabled) {
      indicatorTone = InstrumentTone.idle;
      tooltip = l10n.text('statusTempCompOff');
    } else if (!hasReliableModel) {
      indicatorTone = InstrumentTone.warning;
      tooltip = model == null
          ? l10n.text('statusTempCompNoModel')
          : l10n.text(
              'statusTempCompUnreliable',
              params: {'r2': model.rSquared.toStringAsFixed(2)},
            );
    } else {
      final prediction = focusService.predictFocusPosition(
        profileId: profileId,
        currentTemperature: focuserState.temperature!,
      );
      indicatorTone = InstrumentTone.success;
      final slope = model.slope.toStringAsFixed(1);
      tooltip = prediction != null
          ? l10n.text(
              'statusTempCompActive',
              params: {
                'slope': slope,
                'position': prediction.position.toString(),
              },
            )
          : l10n.text(
              'statusTempCompActiveNoPrediction',
              params: {'slope': slope},
            );
    }

    final colors = SkotiqColors.of(context);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        child: ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'TC',
                style: SkotiqTypography.monoCaption.copyWith(
                  color: colors.textMuted,
                ),
              ),
              const SizedBox(width: 3),
              _StateDot(tone: indicatorTone),
            ],
          ),
        ),
      ),
    );
  }
}
