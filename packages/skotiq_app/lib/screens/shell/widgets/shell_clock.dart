// Wall-clock and LST readout at the left of the main area's top band.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';

/// The LST readout's text.
///
/// `lstHours` is null when there is no site to compute it for.
///
/// A precise "LST 21:14" for a site the operator never gave is worse than no
/// LST: sidereal time is exactly what you read to decide what is transiting.
@visibleForTesting
String formatLstChip(double? lstHours) {
  // An em dash, not '--:--'. A row of hyphens looks like a value that failed
  // to render; an em dash is the app's word for "not known" everywhere else.
  if (lstHours == null) return '—';
  // Normalized to [0, 24) upstream; fold defensively so a bad input can never
  // render as "-1:-30".
  var hours = lstHours % 24;
  if (hours < 0) hours += 24;
  final h = hours.floor();
  final m = ((hours - h) * 60).floor();
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// Local time and sidereal time as one glance, in the top band's left slot.
///
/// The `brandWarm` dot is the "now" marker — the one place the warm accent is
/// allowed to mean "this is where tonight is right now". Owning the per-second
/// tick here scopes the rebuild to this readout; on a state a level up one
/// `setState` a second rebuilds the whole band, and on the Linux embedder a
/// dirty frame is a full-window repaint.
///
/// The [RepaintBoundary] below is insurance against the readout dirtying the
/// band, NOT a measured saving: Flutter's Linux embedder submits a full-window
/// frame regardless of damage.
///
/// Ticking stops while the app is backgrounded.
class ShellClock extends ConsumerStatefulWidget {
  const ShellClock({super.key});

  @override
  ConsumerState<ShellClock> createState() => _ShellClockState();
}

class _ShellClockState extends ConsumerState<ShellClock>
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
    final colors = SkotiqColors.of(context);
    final now = _now;
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final siteIsSet = settings != null &&
        siteLocationIsSet(settings.latitude, settings.longitude);
    // Only read the LST once we know whose LST it is.
    //
    // Watch what is DISPLAYED, not the underlying double. The readout renders
    // LST as `HH:mm`, but `localSiderealTimeProvider` is a `double` recomputed
    // off a 1 Hz wall clock, so a whole-provider watch rebuilt this widget
    // sixty times for every change an operator can see — and on Flutter's
    // Linux embedder, which has no damage region, each of those repainted the
    // entire window. Selecting the formatted text makes a rebuild MEAN the
    // text moved.
    //
    // `known` rides along because the semantic label distinguishes "no
    // sidereal time" from a real one, and the em dash [formatLstChip] returns
    // for null is a rendering detail, not a signal to switch on. Records
    // compare structurally, so the pair changes exactly when one of its
    // halves does.
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
    // screen from every page: this readout formatted the host's
    // `DateTime.now()` straight through, so a remote-observatory operator who
    // set the site offset saw the setting persist, the row's subtitle update,
    // and this clock keep the laptop's time. `Clock.fromUtc` re-expresses the
    // SAME instant in the chosen zone — the caller's timer still decides when
    // the chip reticks — and [SystemClock] leaves host-local users untouched.
    final displayNow = ref.watch(clockProvider).fromUtc(now.toUtc());
    final timeStr =
        '${displayNow.hour.toString().padLeft(2, '0')}:${displayNow.minute.toString().padLeft(2, '0')}:${displayNow.second.toString().padLeft(2, '0')}';

    return RepaintBoundary(
      child: Tooltip(
        message: lstTooltip,
        child: Semantics(
          label: 'Local time $timeStr, '
              '${lstChip.known ? 'LST ${lstChip.text}' : 'sidereal time unknown'}',
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: SkotiqTokens.spaceXs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The "now" marker — an approved brandWarm use.
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: colors.brandWarm,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Text(
                    timeStr,
                    style: SkotiqTypography.monoCaption.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Text(
                    'LST',
                    style: SkotiqTypography.captionSm.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceXs),
                  Text(
                    lstChip.text,
                    style: SkotiqTypography.monoCaption.copyWith(
                      color: colors.textSecondary,
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
