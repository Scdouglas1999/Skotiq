// Go to: an object name or J2000 coordinates, then Slew, Slew & center or
// Sync here.
//
// While a run is loaded the run owns pointing. Slew & center then goes only
// to the run's own target, through the action controller, which pauses the
// run, stops guiding, centers, restarts guiding and resumes. Slew and Sync
// wait until the run is unloaded.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show objectSearchProvider;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../../../models/command_action_result.dart';
import '../../../../services/mount_command_service.dart';
import '../../actions/manual_action_gating.dart';
import '../../actions/night_action_controller.dart';
import '../../night_control_contracts.dart';
import 'night_mount_tab.dart';
import 'night_panel_parts.dart';

/// An object the Go to field resolved, J2000.
@immutable
class NightGoToTarget {
  const NightGoToTarget({
    required this.name,
    required this.raHours,
    required this.decDegrees,
  });

  final String name;
  final double raHours;
  final double decDegrees;
}

typedef NightGoToResolver = Future<NightGoToTarget?> Function(String query);

/// Turns an object name into coordinates: the planetarium's ranked search
/// over Messier, NGC, IC, named stars and solar-system bodies. Tests
/// override it.
final nightGoToResolverProvider = Provider<NightGoToResolver>(
  (ref) => (query) async {
    final object =
        await ref.read(objectSearchProvider.notifier).resolveBest(query);
    if (object == null) return null;
    return NightGoToTarget(
      name: object.name,
      raHours: object.coordinates.ra,
      decDegrees: object.coordinates.dec,
    );
  },
);

/// Two pointings closer than this are the same target (1 arcminute).
const double _sameTargetDeg = 1 / 60;

bool _sameTarget(double ra1, double dec1, double ra2, double dec2) {
  const rad = math.pi / 180;
  final a1 = ra1 * 15 * rad, a2 = ra2 * 15 * rad;
  final d1 = dec1 * rad, d2 = dec2 * rad;
  final cosSep = math.sin(d1) * math.sin(d2) +
      math.cos(d1) * math.cos(d2) * math.cos(a1 - a2);
  return math.acos(cosSep.clamp(-1.0, 1.0)) / rad <= _sameTargetDeg;
}

class NightMountGoToSection extends ConsumerStatefulWidget {
  const NightMountGoToSection({super.key});

  @override
  ConsumerState<NightMountGoToSection> createState() =>
      _NightMountGoToSectionState();
}

class _NightMountGoToSectionState extends ConsumerState<NightMountGoToSection> {
  final _name = TextEditingController();
  final _ra = TextEditingController();
  final _dec = TextEditingController();

  /// The command in flight ('resolve', 'slew', 'center', 'sync').
  String? _busy;

  /// Why the last name lookup found nothing.
  String? _lookupError;

  @override
  void initState() {
    super.initState();
    // Start on the run's target, so Slew & center works without typing.
    final target = ref.read(nightCenterTargetProvider);
    if (target != null) _fill(target.name, target.raHours, target.decDegrees);
    _ra.addListener(_onEdited);
    _dec.addListener(_onEdited);
  }

  @override
  void dispose() {
    _name.dispose();
    _ra.dispose();
    _dec.dispose();
    super.dispose();
  }

  void _onEdited() {
    if (mounted) setState(() {});
  }

  void _fill(String? name, double raHours, double decDegrees) {
    _name.text = name ?? '';
    _ra.text = CoordinateFormat.ra(
      raHours,
      style: SexagesimalStyle.compactLetters,
      seconds: SecondsPrecision.integerRounded,
      wrapHours: true,
    );
    _dec.text = CoordinateFormat.dec(
      decDegrees,
      style: SexagesimalStyle.compactLetters,
      seconds: SecondsPrecision.integerRounded,
    );
  }

  ({double ra, double dec})? get _coordinates {
    final ra = CoordinateParser.parseRa(_ra.text);
    final dec = CoordinateParser.parseDec(_dec.text);
    if (ra == null || dec == null) return null;
    return (ra: ra, dec: dec);
  }

  Future<void> _resolve(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    setState(() {
      _busy = 'resolve';
      _lookupError = null;
    });
    try {
      final found = await ref.read(nightGoToResolverProvider)(trimmed);
      if (!mounted) return;
      if (found == null) {
        setState(() => _lookupError = context.l10n
            .text('nightScopeGoToNotFound', params: {'name': trimmed}));
        return;
      }
      _fill(found.name, found.raHours, found.decDegrees);
    } catch (e) {
      if (mounted) {
        setState(() => _lookupError = context.l10n
            .text('nightScopeGoToLookupFailed', params: {'error': '$e'}));
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final facts = watchNightMountFacts(ref);
    final runTarget = ref.watch(nightCenterTargetProvider);
    final coordinates = _coordinates;
    final isRunTarget = coordinates != null &&
        runTarget != null &&
        _sameTarget(
          coordinates.ra,
          coordinates.dec,
          runTarget.raHours,
          runTarget.decDegrees,
        );
    final noCoordinates =
        coordinates == null ? l10n.text('nightScopeWhyNoCoordinates') : null;
    final busy = _busy != null
        ? l10n.text(manualActionKey('nightActBusy', ManualActionId.center))
        : null;

    // Slew and Sync: nothing in flight, a run not loaded, an unparked mount.
    String? plainReason(bool Function(MountCapabilities) can) {
      final reason = facts.baseReason(l10n);
      if (reason != null) return reason;
      if (noCoordinates != null) return noCoordinates;
      if (busy != null) return busy;
      if (facts.mount.isSlewing) return l10n.text('nightScopeWhySlewing');
      if (!can(facts.capabilities!)) {
        return l10n.text('nightScopeWhyMountCannot');
      }
      return null;
    }

    final slewReason = plainReason((c) => c.canSlew || c.canSlewAsync);
    final syncReason = plainReason((c) => c.canSync);

    // Slew & center on the run's target goes through the action controller,
    // which has its own gating; anything else is the plain path plus a camera.
    final String? centerReason;
    if (isRunTarget) {
      centerReason = manualActionDisabledReason(
        facts.inputs,
        ManualActionId.center,
      )?.resolve(l10n);
    } else if (facts.runActive) {
      centerReason = l10n.text('nightScopeWhyRunTargetOnly');
    } else {
      centerReason = plainReason((c) => c.canSlew || c.canSlewAsync) ??
          (facts.inputs.cameraConnected
              ? null
              : l10n.text('nightActWhyNoCamera'));
    }
    final centerInFlight = facts.inputs.action.isBusy &&
        facts.inputs.action.active == ManualActionId.center;

    return NightPanelSection(
      title: l10n.text('nightScopeGoTo'),
      trailing: l10n.text('nightScopeJ2000'),
      children: [
        SkotiqTextField(
          key: const ValueKey<String>('nightMount.goToName'),
          controller: _name,
          label: l10n.text('nightScopeGoToObject'),
          hint: l10n.text('nightScopeGoToObjectHint'),
          mono: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (value) => unawaited(_resolve(value)),
          errorText: _lookupError,
          suffixWidget: _busy == 'resolve'
              ? const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SkotiqTextField(
                key: const ValueKey<String>('nightMount.goToRa'),
                controller: _ra,
                label: l10n.text('nightScopeRa'),
                mono: true,
              ),
            ),
            const SizedBox(width: kNightPanelRowGap),
            Expanded(
              child: SkotiqTextField(
                key: const ValueKey<String>('nightMount.goToDec'),
                controller: _dec,
                label: l10n.text('nightScopeDec'),
                mono: true,
              ),
            ),
          ],
        ),
        // Slew & center on its own row: its label does not fit a third of
        // the panel.
        NightPanelButtonGrid(
          columns: 1,
          buttons: [
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightMount.slewCenter'),
              label: l10n.text('nightScopeSlewCenter'),
              emphasized: true,
              busy: _busy == 'center' || (isRunTarget && centerInFlight),
              disabledReason: centerReason,
              onPressed: centerReason == null
                  ? () => isRunTarget
                      ? unawaited(ref.read(nightActionApiProvider).center())
                      : _run('center', () => _center(coordinates!))
                  : null,
            ),
          ],
        ),
        NightPanelButtonGrid(
          columns: 2,
          buttons: [
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightMount.slew'),
              label: l10n.text('nightScopeSlew'),
              busy: _busy == 'slew',
              disabledReason: slewReason,
              onPressed: slewReason == null
                  ? () => _run('slew', () => _slew(coordinates!))
                  : null,
            ),
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightMount.sync'),
              label: l10n.text('nightScopeSync'),
              busy: _busy == 'sync',
              disabledReason: syncReason,
              onPressed: syncReason == null
                  ? () => _run(
                        'sync',
                        () => ref
                            .read(mountCommandServiceProvider)
                            .sync(coordinates!.ra, coordinates.dec),
                      )
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _run(
    String id,
    Future<CommandActionResult> Function() command,
  ) async {
    setState(() => _busy = id);
    try {
      final result = await command();
      if (mounted) showNightCommandResult(context, result);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Guiding stops before any slew: a slew under guiding drags the guide
  /// star off and reads as a lost star. It is not restarted, because no run
  /// is waiting on it.
  Future<CommandActionResult?> _stopGuidingFirst(
    SkotiqLocalizations l10n,
  ) async {
    if (!ref.read(guiderStateProvider).isGuiding) return null;
    try {
      await ref.read(phd2ControllerProvider).stopGuiding();
      return null;
    } catch (e) {
      return CommandActionResult.failure(
        l10n.text('nightScopeErrStopGuiding', params: {'error': '$e'}),
      );
    }
  }

  Future<CommandActionResult> _slew(({double ra, double dec}) to) async {
    final refused = await _stopGuidingFirst(context.l10n);
    if (refused != null) return refused;
    return ref.read(mountCommandServiceProvider).slewTo(to.ra, to.dec);
  }

  /// Slew and center on coordinates that are not the run's target, with the
  /// same solver and centering settings the action controller uses.
  Future<CommandActionResult> _center(({double ra, double dec}) to) async {
    final l10n = context.l10n;
    final refused = await _stopGuidingFirst(l10n);
    if (refused != null) return refused;
    final settings = await ref.read(appSettingsProvider.future);
    final profile = ref.read(activeEquipmentProfileProvider);
    final exposure = profile?.defaultCenteringExposure;
    final result = await ref.read(centeringServiceProvider).centerOnTarget(
          targetRa: to.ra,
          targetDec: to.dec,
          solverConfig: PlateSolverConfig(
            type: PlateSolverType.astap,
            executablePath: settings.astapPath,
            timeoutSeconds: settings.plateSolveTimeout,
            searchRadius: settings.plateSolveSearchRadius,
          ),
          config: CenteringConfig(
            exposureTime: exposure != null && exposure > 0 ? exposure : 5.0,
            binning: profile?.defaultBinX ?? 2,
            gain: profile?.defaultGain,
            offset: profile?.defaultOffset,
            syncMount: settings.centeringSyncMount,
          ),
          onStatusUpdate: (status) =>
              ref.read(centeringStatusProvider.notifier).state = status,
        );
    if (!result.success) {
      return CommandActionResult.failure(
        result.errorMessage ?? l10n.text('nightScopeErrCenter'),
      );
    }
    final offset = result.finalOffsetArcsec;
    return CommandActionResult.success(
      message: offset == null
          ? l10n.text('nightScopeCentered')
          : l10n.text(
              'nightScopeCenteredWithin',
              params: {'arcsec': offset.toStringAsFixed(1)},
            ),
    );
  }
}
