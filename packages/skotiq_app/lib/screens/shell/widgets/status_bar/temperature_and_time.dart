part of '../status_bar.dart';

/// Small indicator showing temp comp status next to focus pill.
/// Only visible when the focuser is connected and has temperature data.
class _TempCompIndicator extends ConsumerWidget {
  final SkotiqColors colors;
  final SkotiqLocalizations l10n;

  const _TempCompIndicator({required this.colors, required this.l10n});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Connection and temperature only: a focuser that is stepping publishes a
    // new position on every move, and this chip is mounted on every screen, so
    // a whole-object watch made each step dirty the shell — and on Flutter's
    // Linux embedder a dirty frame is a full-window repaint.
    final focuserState = ref.watch(
      focuserStateProvider.select(
        (s) => (connectionState: s.connectionState, temperature: s.temperature),
      ),
    );
    final focuserConnected =
        focuserState.connectionState == DeviceConnectionState.connected;

    // Only show when focuser is connected and reports temperature
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

    // Determine state
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

    return Tooltip(
      message: tooltip,
      child: InstrumentPill(
        icon: LucideIcons.thermometerSun,
        dotTone: indicatorTone,
        value: 'TC',
        semanticLabel: tooltip,
      ),
    );
  }
}

// `siteLocationIsSet` used to be defined here, beside its one caller. It is now
// the canonical predicate on the settings model in `skotiq_core` (exported
// through the package barrel), because a not-set rule living inside a
// status-bar widget invites every other surface to re-derive its own copy —
// and those copies drifted.

/// The LST chip's text.
///
/// `lstHours` is null when there is no site to compute it for.
///
/// A precise "LST 21:14" for a site the operator never gave is worse than no
/// LST: sidereal time is exactly what you read to decide what is transiting.
@visibleForTesting
String formatLstChip(double? lstHours) {
  // An em dash, not '--:--'. A row of hyphens looks like a value that failed
  // to render; an em dash is the app's word for "not known" everywhere else.
  if (lstHours == null) return '\u2014';
  // Normalized to [0, 24) upstream; fold defensively so a bad input can never
  // render as "-1:-30".
  var hours = lstHours % 24;
  if (hours < 0) hours += 24;
  final h = hours.floor();
  final m = ((hours - h) * 60).floor();
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// Wall-clock and LST chip that owns its per-second tick.
///
/// Owning the tick here scopes the per-second rebuild to this chip; on
/// `_StatusBarState` one `setState` a second rebuilds every device pill, both
/// action buttons and the enclosing `LayoutBuilder` to move one digit.
/// `status_bar_idle_repaint_test.dart` pins it via Flutter's rebuild tracer.
///
/// The [RepaintBoundary] below is insurance against this chip dirtying the bar,
/// NOT a measured saving: Flutter's Linux embedder submits a full-window frame
/// regardless of damage.
///
/// Ticking stops while the app is backgrounded.
class _TimeDisplay extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const _TimeDisplay({required this.colors});

  @override
  ConsumerState<_TimeDisplay> createState() => _TimeDisplayState();
}

class _TimeDisplayState extends ConsumerState<_TimeDisplay>
    with WidgetsBindingObserver {
  AlignedTicker? _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    // Aligned to the wall-clock second so this tick shares its frame with the
    // planetarium's two 1 Hz clocks rather than costing a full-window frame of
    // its own. It also makes the displayed second change *on* the second.
    // See [AlignedTicker].
    _timer = AlignedTicker(const Duration(seconds: 1), () {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_timer == null || !_timer!.isActive) {
        // Resync immediately so the clock doesn't show a stale time.
        _now = DateTime.now();
        _startTimer();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = _now;
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final siteIsSet = settings != null &&
        siteLocationIsSet(settings.latitude, settings.longitude);
    // Only read the LST once we know whose LST it is.
    //
    // Watch what is DISPLAYED, not the underlying double. The chip renders LST
    // as `HH:mm`, but `localSiderealTimeProvider` is a `double` recomputed off
    // a 1 Hz wall clock, so a whole-provider watch rebuilt this chip sixty
    // times for every change an operator can see — and on Flutter's Linux
    // embedder, which has no damage region, each of those repainted the entire
    // window. Selecting the formatted text makes a rebuild MEAN the text moved.
    //
    // `known` rides along because the semantic label distinguishes "no sidereal
    // time" from a real one, and the em dash [formatLstChip] returns for null
    // is a rendering detail, not a signal to switch on. Records compare
    // structurally, so the pair changes exactly when one of its halves does.
    final lstChip = siteIsSet
        ? ref.watch(
            localSiderealTimeProvider.select(
              (hours) => (text: formatLstChip(hours), known: hours != null),
            ),
          )
        : (text: formatLstChip(null), known: false);
    final l10n = context.l10n;
    final lstTooltip = settings == null
        ? l10n.text('statusLstLoading')
        : siteIsSet
            ? l10n.text('statusLstTooltip')
            : l10n.text('statusLstNoSite');
    // Settings → Location → Timezone was inert on the one clock that is on
    // screen from every page: this chip formatted the host's `DateTime.now()`
    // straight through, so a remote-observatory operator who set the site
    // offset saw the setting persist, the row's subtitle update, and this
    // clock keep the laptop's time. `Clock.fromUtc` re-expresses the SAME
    // instant in the chosen zone — the caller's timer still decides when the
    // chip reticks — and [SystemClock] leaves host-local users untouched.
    final displayNow = ref.watch(clockProvider).fromUtc(now.toUtc());
    final timeStr =
        '${displayNow.hour.toString().padLeft(2, '0')}:${displayNow.minute.toString().padLeft(2, '0')}:${displayNow.second.toString().padLeft(2, '0')}';

    // The boundary is the point of the exercise: without it, repainting one
    // digit marks the parent layer dirty and the whole window re-rasterises
    // once a second.
    //
    // ONE pill, not two: local time and sidereal time are a single glance,
    // and a hover boundary between them would say they are separate facts.
    return RepaintBoundary(
      child: Tooltip(
        message: lstTooltip,
        child: InstrumentPill(
          icon: SkotiqIcons.clock,
          value: timeStr,
          mono: true,
          trailingLabel: 'LST',
          trailingValue: lstChip.text,
          semanticLabel: 'Local time $timeStr, '
              '${lstChip.known ? 'LST ${lstChip.text}' : 'sidereal time unknown'}',
        ),
      ),
    );
  }
}
