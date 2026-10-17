import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;

import '../../../localization/skotiq_localizations.dart';
import '../../../utils/device_format_utils.dart';
import '../../../widgets/operation_status_bar.dart';
import '../../sequencer/widgets/run_dashboard/recovery_banner.dart';
import '../../settings/settings_screen.dart' show SettingsSectionRequest;

part 'status_bar/sequence_indicator.dart';
part 'status_bar/temperature_and_time.dart';

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

/// How confident the save-path pill is allowed to look.
enum SavePathTone {
  /// Verified: the configured directory is there.
  ok,

  /// Not assessed (probe unfinished or failed). Neutral — never an alarm.
  unknown,

  /// Known bad: nothing configured, or the configured directory is gone.
  alarm,
}

/// The save-path pill's rendering, derived from what is actually known.
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

/// Maps the async save-path probe onto pill text.
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
  if (backend is NetworkBackend) {
    final validation = await backend.validateRemoteDirectory(
      savePath,
      mustExist: true,
      mustBeWritable: false,
    );
    return validation['valid'] == true;
  }
  return Directory(savePath).exists();
}

/// Free space, rendered the way a 22px pill has room for.
///
/// Whole GB up to a terabyte, then one decimal of TB. Not "412.7 GB free": the
/// operator is checking whether the night fits, not auditing the volume.
@visibleForTesting
String formatFreeSpace(int freeBytes) {
  const gb = 1024 * 1024 * 1024;
  if (freeBytes < gb) {
    final mb = freeBytes / (1024 * 1024);
    return '${mb.round()} MB free';
  }
  final gigabytes = freeBytes / gb;
  if (gigabytes < 1024) return '${gigabytes.round()} GB free';
  return '${(gigabytes / 1024).toStringAsFixed(1)} TB free';
}

/// The instrument bar (04-shell §5).
///
/// The app's ONE persistent status surface: 32 px of [InstrumentPill]s over a
/// `surface` fill with a top hairline. The left group names what is attached
/// and what is running, and yields its width first; the right group carries the
/// readouts that are never sacrificed.
///
/// It is not mounted below the tablet breakpoint at all — the narrow shell gets
/// the bottom nav and a 28 px strip inside the Tonight and Imaging page headers
/// instead — which is why the old `compact` variant is gone.
///
/// Also gone: the web-dashboard button and the share button. Neither was
/// status, and the remote indicator in the top bar is where a remote session
/// is opened and shared from.
class StatusBar extends ConsumerStatefulWidget {
  const StatusBar({super.key});

  @override
  ConsumerState<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends ConsumerState<StatusBar> {
  // Keep the per-second clock tick inside [_TimeDisplay] so the rest of the
  // instrument bar remains idle.

  /// Widest a device name may run before it ellipsizes inside its pill.
  ///
  /// Uncapped, a long ASCOM name pushes the whole left group into the scroll
  /// viewport and the pill at the cut is sliced mid-word. An ellipsis inside
  /// the pill is a truncation the reader can see; a viewport slice is not.
  double get _deviceValueMaxWidth =>
      ShellChromeMetrics.scaledStatusPillValueMaxWidth(context);

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

  /// What a device pill is called to assistive tech.
  ///
  /// "Camera, Simulated Camera" when there is one; "Camera, not connected"
  /// when there is not. The pill itself renders only the value, because the
  /// glyph says which device it is — but a glyph is not a name, so the role
  /// has to be spelled out here.
  String _deviceSemanticLabel(
    String role, {
    required bool connected,
    required String value,
    required SkotiqLocalizations l10n,
  }) {
    return connected
        ? '$role, $value'
        : '$role, ${l10n.text('disconnected').toLowerCase()}';
  }

  InstrumentTone _connectionTone(DeviceConnectionState state) =>
      state == DeviceConnectionState.connected
          ? InstrumentTone.success
          : InstrumentTone.idle;

  void _go(String route) {
    try {
      context.go(route);
    } catch (_) {
      // A pill that cannot navigate is inert, not broken; the bar keeps
      // reporting either way.
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    final savePathChip = savePathChipFor(
      ref.watch(_savePathStatusProvider),
      _formatPathLabel,
      l10n,
    );

    // A device publishes far more than this bar shows. A tracking mount emits a
    // fresh position every 2 s (`_normalPollInterval` in `mount_state_provider`),
    // and a whole-object watch turned each one into a rebuild of the entire bar
    // — which on Flutter's Linux embedder is a full-window frame, because that
    // embedder has no damage region and repaints everything for any dirty frame.
    // The bar is on every screen, so that was an idle frame every 2 s in the
    // whole app, on screens that show no mount at all.
    //
    // Select only the fields rendered below. Records compare structurally, so
    // the bar now rebuilds when one of THESE changes and not before; the field
    // names are kept identical so the render code reads the same either way.
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
        (s) => (connectionState: s.connectionState, isGuiding: s.isGuiding),
      ),
    );
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
    final filterWheelConnected =
        filterWheelState.connectionState == DeviceConnectionState.connected;

    // The pill's VALUE is the device name, or the phrase for its absence —
    // never "Camera: ASI2600MM". The glyph carries the role (04 §5); spelling
    // it out again spends half a 22px pill saying what the icon said.
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

    final leading = <Widget>[
      // 1. Run state. The only pill whose word is the whole story, and the
      // only thing in the chrome allowed a live halo.
      _SequenceIndicator(
        colors: colors,
        l10n: l10n,
        onTap: () => _go('/sequencer'),
      ),
      const InstrumentSeparator(),

      // 2-7. What is attached, each opening the screen that deals with it.
      InstrumentPill(
        icon: SkotiqIcons.camera,
        dotTone: _connectionTone(cameraState.connectionState),
        value: cameraValue,
        semanticLabel: _deviceSemanticLabel(
          l10n.text('statusCamera'),
          connected: cameraConnected,
          value: cameraValue,
          l10n: l10n,
        ),
        maxValueWidth: _deviceValueMaxWidth,
        onTap: () => _go('/equipment'),
      ),
      InstrumentPill(
        icon: LucideIcons.mountain,
        dotTone: _connectionTone(mountState.connectionState),
        value: mountValue,
        semanticLabel: _deviceSemanticLabel(
          l10n.text('mount'),
          connected: mountConnected,
          value: mountValue,
          l10n: l10n,
        ),
        maxValueWidth: _deviceValueMaxWidth,
        onTap: () => _go('/equipment'),
      ),
      InstrumentPill(
        icon: SkotiqIcons.crosshair,
        dotTone: _connectionTone(guiderState.connectionState),
        // "Idle" here used to mean "no guider" — the same word the app uses
        // for a connected, ready guider that simply is not guiding. At a
        // glance the bar said the guider was present and calm when there was
        // no guider at all.
        value: guiderValue,
        semanticLabel: _deviceSemanticLabel(
          l10n.text('statusGuider'),
          connected: guiderConnected,
          value: guiderValue,
          l10n: l10n,
        ),
        maxValueWidth: _deviceValueMaxWidth,
        onTap: () => _go('/guiding'),
      ),
      InstrumentPill(
        icon: SkotiqIcons.focuser,
        dotTone: _connectionTone(focuserState.connectionState),
        // The POSITION, not the word "Ready": a focuser's position is the one
        // thing about it worth a permanent slot in the chrome. The old pill
        // showed "---" when nothing was attached, which is the placeholder
        // this overhaul removes.
        value: focuserValue,
        mono: focuserConnected && focuserState.position != null,
        semanticLabel: _deviceSemanticLabel(
          l10n.text('focus'),
          connected: focuserConnected,
          value: focuserValue,
          l10n: l10n,
        ),
        maxValueWidth: _deviceValueMaxWidth,
        onTap: () => _go('/equipment'),
      ),
      // Only when connected: a filter wheel is optional equipment, and a
      // permanent "No filter wheel" pill on a rig that has never had one is
      // the bar reporting the absence of something nobody asked for.
      if (filterWheelConnected)
        Builder(
          builder: (context) {
            final filter =
                filterWheelState.filterName ?? l10n.text('statusReady');
            return InstrumentPill(
              icon: LucideIcons.disc,
              dotTone: InstrumentTone.success,
              value: filter,
              semanticLabel: 'Filter: $filter',
              maxValueWidth: _deviceValueMaxWidth,
              onTap: () => _go('/equipment'),
            );
          },
        ),

      // 8. The temperature-compensation LED, the sequencer LED and the
      // in-flight operation strip, after the devices, in the same style.
      _TempCompIndicator(colors: colors, l10n: l10n),
      const SequencerStatusLed(showLabel: false),
      const OperationStatusBar(),
    ];

    final trailing = <Widget>[
      // The scrolling region always ends at a rule, whatever it is showing.
      // Without one, at 900 px the pill group's last item is sliced mid-word
      // with the next glyph painted straight against it, so the bar reads as
      // broken rather than scrolled.
      ..._cutAffordance(colors),
      const InstrumentSeparator(),

      // Only for a COOLED camera: a DSLR has no sensor setpoint, and an em
      // dash where a temperature should be is a permanent question.
      if (cameraConnected && cameraState.temperature != null)
        InstrumentPill(
          icon: SkotiqIcons.temperature,
          value: '${cameraState.temperature!.toStringAsFixed(1)}°C',
          mono: true,
          semanticLabel: 'Sensor temperature '
              '${cameraState.temperature!.toStringAsFixed(1)} degrees Celsius',
        ),

      _SaveFolderPill(chip: savePathChip),
      const InstrumentSeparator(),
      _TimeDisplay(colors: colors),
    ];

    return Container(
      height: ShellChromeMetrics.statusBarHeight,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border, width: 1)),
      ),
      // The device pills take the slack and scroll when there is none; the
      // readouts on the right are never sacrificed. A bare Row + Spacer
      // silently CLIPPED the trailing group at narrow window widths — at
      // 1000x700 the clock and LST readouts were gone entirely and at 800x600
      // the save-path pill was cut mid-word, with no ellipsis and no way to
      // reach either.
      child: Row(
        children: [
          // Expanded, not Flexible: a SingleChildScrollView shrink-wraps under
          // a loose constraint, which would let the readouts drift left off
          // the right edge. A tight fit makes the pill group take all the
          // slack and scroll only once the slack runs out.
          Expanded(child: _scrollingStrip(leading)),
          ...trailing,
        ],
      ),
    );
  }

  /// The filter the wheel is actually on, or null when it cannot say.
  String? _currentFilterName(FilterWheelState state) {
    final position = state.currentPosition;
    if (position == null) return null;
    if (position < 0 || position >= state.filterNames.length) return null;
    final name = state.filterNames[position].trim();
    return name.isEmpty ? null : name;
  }

  /// The horizontally scrolling group, with the edge fade that says content is
  /// hidden past the right edge and the metrics wiring that keeps that claim
  /// true.
  Widget _scrollingStrip(List<Widget> children) {
    final scroller = SingleChildScrollView(
      controller: _pillsController,
      scrollDirection: Axis.horizontal,
      child: Row(children: children),
    );
    return NotificationListener<ScrollNotification>(
      // Layout changes arrive as ScrollMetricsNotification; dragging arrives
      // as ScrollNotification. Both change whether anything is still hidden to
      // the right, and the fade and the cut mark are only honest if they track
      // it.
      onNotification: (notification) {
        _updatePillsOverflow(notification.metrics);
        return false;
      },
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) {
          _updatePillsOverflow(notification.metrics);
          return false;
        },
        // Scrolling alone is silent — the bar simply ended and looked
        // complete, so a disconnected mount was indistinguishable from no
        // mount at all. The fade says "there is more this way"; it appears
        // only while the group actually overflows.
        child: _pillsCutRight
            ? ShaderMask(
                shaderCallback: _fadeRightEdge,
                blendMode: BlendMode.dstIn,
                child: scroller,
              )
            : scroller,
      ),
    );
  }

  /// The truncation mark and the control that reaches what it marks.
  ///
  /// The item at the viewport edge is sliced and dissolved by the fade with
  /// nothing saying it was cut. An ellipsis is how this app says "truncated"
  /// everywhere else, so the cut gets one; the chevron beside it is the
  /// control a fade is not. Both are drawn OUTSIDE the viewport, flush against
  /// it, because inside they would scroll away with the content they describe.
  List<Widget> _cutAffordance(SkotiqColors colors) => [
        if (_pillsCutRight) _PillsCutMarker(colors: colors),
        if (_pillsOverflow)
          _PillsOverflowAffordance(
            colors: colors,
            onTap: _scrollPillsRight,
          ),
      ];

  /// True while the pill group is wider than its viewport at all — i.e. some
  /// pill is unreachable without scrolling. Drives the scroll affordance,
  /// which stays offered even at the end of the strip (it wraps back).
  bool _pillsOverflow = false;

  /// True while content is hidden PAST THE RIGHT EDGE right now. Drives the
  /// edge fade and the truncation mark, both of which are claims about the
  /// current scroll offset, not about the strip's total width.
  bool _pillsCutRight = false;

  /// Drives the pill strip so the overflow affordance can actually move it —
  /// a fade alone told the operator there was more without offering any way to
  /// reach it with a mouse.
  final ScrollController _pillsController = ScrollController();

  @override
  void dispose() {
    _pillsController.dispose();
    super.dispose();
  }

  void _scrollPillsRight() {
    if (!_pillsController.hasClients) return;
    final position = _pillsController.position;
    final target = position.pixels >= position.maxScrollExtent - 1
        ? position.minScrollExtent
        : (position.pixels + _scrollStep).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          );
    _pillsController.animateTo(
      target,
      duration: SkotiqTokens.durationSmooth,
      curve: SkotiqTokens.curveStandard,
    );
  }

  /// How far one press of the overflow chevron moves the strip: about two
  /// device pills, so a press reveals something new without skipping one.
  static const double _scrollStep = 160.0;

  void _updatePillsOverflow(ScrollMetrics metrics) {
    final overflow = metrics.maxScrollExtent > 0;
    final cutRight = overflow && metrics.pixels < metrics.maxScrollExtent - 0.5;
    if (_pillsOverflow == overflow && _pillsCutRight == cutRight) return;
    // The notification arrives during layout; defer so this is not a setState
    // inside a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pillsOverflow == overflow && _pillsCutRight == cutRight) return;
      setState(() {
        _pillsOverflow = overflow;
        _pillsCutRight = cutRight;
      });
    });
  }

  /// Alpha ramp that dissolves the last 8% of the pill group.
  ///
  /// Only the alpha channel is consumed by [ShaderMask], so these are mask
  /// values rather than interface colours.
  static Shader _fadeRightEdge(Rect bounds) => const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Color(0xFFFFFFFF),
          Color(0xFFFFFFFF),
          Color(0x00FFFFFF),
        ],
        stops: [0.0, 0.92, 1.0],
      ).createShader(bounds);

  String _formatPathLabel(String path) {
    final normalized = p.normalize(path);
    final baseName = p.basename(normalized);
    return baseName.isNotEmpty ? baseName : normalized;
  }
}

/// Where frames land, and whether there is room for tonight's.
///
/// The folder and the free space are ONE pill because they are one question.
/// Split across two, an operator reads "Captures" and "412 GB free" as facts
/// about different things.
class _SaveFolderPill extends ConsumerWidget {
  final SavePathChip chip;

  const _SaveFolderPill({required this.chip});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final space = ref.watch(captureDirDiskSpaceProvider).valueOrNull;
    final free = space == null ? null : formatFreeSpace(space.freeBytes);
    // No free-space figure next to a path we know is unusable: "No save folder
    // · 412 GB free" reports room in a place that does not exist.
    final value = chip.tone == SavePathTone.alarm || free == null
        ? chip.label
        : '${chip.label} · $free';

    return Tooltip(
      message: chip.tooltip,
      child: InstrumentPill(
        // The folder-X alarm is reserved for a path we KNOW is unusable. "Not
        // checked yet" / "could not verify" gets the neutral search folder, so
        // an unfinished probe never reads as a broken rig.
        icon: switch (chip.tone) {
          SavePathTone.ok => LucideIcons.hardDrive,
          SavePathTone.alarm => LucideIcons.folderX,
          SavePathTone.unknown => LucideIcons.folderSearch,
        },
        value: value,
        semanticLabel: chip.tooltip,
        maxValueWidth: _maxWidth,
        onTap: () {
          // Raised as an event as well as a route, so a second click while
          // Settings is already open still moves the detail pane.
          SettingsSectionRequest.raise('storage');
          context.go('/settings?section=storage');
        },
      ),
    );
  }

  /// Enough for a folder name and a free-space figure; beyond that the path
  /// ellipsizes rather than pushing the clock off the bar.
  static const double _maxWidth = 200.0;
}

/// The truncation mark drawn where the pill strip is cut by its viewport.
///
/// Capping a pill's value is not enough on its own: at 1000x800 with four
/// devices connected the strip still scrolls, with the pill at the cut reading
/// "Si", sliced mid-word and dissolved by the edge fade. A viewport slice is
/// not a truncation the reader can recognise; an ellipsis is, and it is what
/// every other truncation in this app uses.
///
/// Decorative for assistive tech — the scroll affordance beside it carries the
/// meaning as a real, named control.
class _PillsCutMarker extends StatelessWidget {
  final SkotiqColors colors;

  const _PillsCutMarker({required this.colors});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Text(
        '…',
        style: SkotiqTypography.bodySm.copyWith(
          color: colors.textSecondary,
        ),
      ),
    );
  }
}

/// The "there is more equipment this way" control at the right edge of the
/// scrolling pill group.
///
/// Without it the group scrolls silently: at 900 px the last visible pill is
/// cut mid-word and Mount / Guider / Focus are simply absent, with nothing on
/// screen saying they exist. The alpha fade is the only hint, and a fade is not
/// a control: with a mouse there is nothing to click. This is.
class _PillsOverflowAffordance extends StatelessWidget {
  final SkotiqColors colors;
  final VoidCallback onTap;

  const _PillsOverflowAffordance({required this.colors, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: true,
      label: 'More equipment status',
      child: Tooltip(
        message: 'More equipment status — scroll',
        child: InkWell(
          onTap: onTap,
          borderRadius: SkotiqTokens.borderRadiusXs,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceXs + 2,
              vertical: 2,
            ),
            child: Icon(
              SkotiqIcons.chevronRight,
              size: SkotiqTokens.iconXs,
              color: colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
