// The chart row before a run (TonightReady.dc.html): the last autofocus
// curve, the guider's idle card and the cooling ramp.
part of 'session_charts_row.dart';

// ---------------------------------------------------------------------------
// Inputs for the before-the-run cards
// ---------------------------------------------------------------------------

/// The last finished autofocus run of this app session.
@immutable
class NightAutofocusCurveVm {
  const NightAutofocusCurveVm({
    required this.points,
    this.bestPosition,
    this.bestHfr,
    this.temperature,
  });

  /// (focuser position, HFR) in acquisition order.
  final List<(int, double)> points;
  final int? bestPosition;
  final double? bestHfr;
  final double? temperature;

  @override
  bool operator ==(Object other) =>
      other is NightAutofocusCurveVm &&
      listEquals(other.points, points) &&
      other.bestPosition == bestPosition &&
      other.bestHfr == bestHfr &&
      other.temperature == temperature;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(points), bestPosition, bestHfr, temperature);
}

/// Keeps the curve of the last finished autofocus. The overlay clears its
/// result a few seconds after a run, so this holds it for the app session.
/// Nothing persists autofocus curves, so it starts empty after a restart.
final nightLastAutofocusProvider = Provider<NightAutofocusCurveVm?>(
  (ref) => ref.watch(_lastAutofocusRecorder),
);

final _lastAutofocusRecorder =
    NotifierProvider<_LastAutofocus, NightAutofocusCurveVm?>(
  _LastAutofocus.new,
);

class _LastAutofocus extends Notifier<NightAutofocusCurveVm?> {
  @override
  NightAutofocusCurveVm? build() {
    ref.listen<AutofocusOverlayState>(
      autofocusOverlayProvider,
      (_, next) => _take(next),
    );
    return _curveOf(ref.read(autofocusOverlayProvider));
  }

  void _take(AutofocusOverlayState af) {
    final curve = _curveOf(af);
    if (curve != null) state = curve;
  }

  static NightAutofocusCurveVm? _curveOf(AutofocusOverlayState af) {
    final result = af.result;
    if (af.isRunning || result == null || af.vcurvePoints.isEmpty) {
      return null;
    }
    return NightAutofocusCurveVm(
      points: <(int, double)>[
        for (final point in af.vcurvePoints) (point.position, point.hfr),
      ],
      bestPosition: result.bestPosition,
      bestHfr: result.bestHfr,
      temperature: result.temperature,
    );
  }
}

/// The guider before a run.
@immutable
class NightGuiderIdleVm {
  const NightGuiderIdleVm({
    required this.connected,
    required this.canCommand,
    this.state,
  });

  final bool connected;
  final bool canCommand;

  /// PHD2's own state; null when not connected.
  final Phd2State? state;

  @override
  bool operator ==(Object other) =>
      other is NightGuiderIdleVm &&
      other.connected == connected &&
      other.canCommand == canCommand &&
      other.state == state;

  @override
  int get hashCode => Object.hash(connected, canCommand, state);
}

final nightGuiderIdleProvider = Provider<NightGuiderIdleVm>((ref) {
  final connected = ref.watch(
    guiderStateProvider.select(
      (g) => g.connectionState == DeviceConnectionState.connected,
    ),
  );
  return NightGuiderIdleVm(
    connected: connected,
    canCommand: ref.watch(backendCanCommandProvider),
    state: connected ? ref.watch(phd2StateProvider) : null,
  );
});

// ---------------------------------------------------------------------------
// Before the run
// ---------------------------------------------------------------------------

class _FocusCard extends ConsumerWidget {
  const _FocusCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final l10n = context.l10n;
    final curve = ref.watch(nightLastAutofocusProvider);
    final title = l10n.text('nightCtrChartFocus');
    if (curve == null) {
      return _Cell(
        title: title,
        body: _ChartBody(
          semanticLabel:
              l10n.text('nightCtrSemNoData', params: {'title': title}),
          lines: const <SeriesChartLine>[],
          empty: l10n.text('nightCtrFocusNone'),
        ),
      );
    }
    final best = curve.bestPosition;
    final bestHfr = curve.bestHfr;
    final temp = curve.temperature;
    final caption = <String>[
      if (best != null)
        l10n.text(
          'nightCtrFocusBest',
          params: <String, String>{'position': nightGrouped(best)},
        ),
      if (bestHfr != null)
        l10n.text(
          'nightCtrHfrValue',
          params: <String, String>{'hfr': bestHfr.toStringAsFixed(2)},
        ),
      if (temp != null) nightCelsius(temp),
    ].join(' · ');
    return _Cell(
      title: title,
      note: l10n.text('nightCtrFocusThisSession'),
      body: Semantics(
        label: l10n.text(
          'nightCtrSemFocus',
          params: <String, String>{
            'count': '${curve.points.length}',
            'details': caption,
          },
        ),
        excludeSemantics: true,
        child: CustomPaint(
          size: Size.infinite,
          painter: _VCurvePainter(
            points: curve.points,
            best: best,
            line: colors.primary.withValues(alpha: 0.6),
            dot: colors.primary,
          ),
        ),
      ),
      legend: TextSpan(text: caption),
    );
  }
}

/// A bare V-curve: the samples joined in focuser order, the best one dotted.
class _VCurvePainter extends CustomPainter {
  _VCurvePainter({
    required this.points,
    required this.best,
    required this.line,
    required this.dot,
  });

  final List<(int, double)> points;
  final int? best;
  final Color line;
  final Color dot;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2 || size.isEmpty) return;
    final sorted = [...points]..sort((a, b) => a.$1.compareTo(b.$1));
    final minX = sorted.first.$1.toDouble();
    final maxX = sorted.last.$1.toDouble();
    var minY = sorted.first.$2;
    var maxY = minY;
    for (final (_, hfr) in sorted) {
      minY = math.min(minY, hfr);
      maxY = math.max(maxY, hfr);
    }
    const inset = 4.0;
    double x(num v) => maxX == minX
        ? size.width / 2
        : inset + (v - minX) / (maxX - minX) * (size.width - 2 * inset);
    double y(double v) => maxY == minY
        ? size.height / 2
        : inset + (maxY - v) / (maxY - minY) * (size.height - 2 * inset);
    final path = Path()..moveTo(x(sorted.first.$1), y(sorted.first.$2));
    for (final (position, hfr) in sorted.skip(1)) {
      path.lineTo(x(position), y(hfr));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    // Dot the sample nearest the fitted best, or the lowest one.
    var mark = sorted.first;
    for (final sample in sorted) {
      final better = best == null
          ? sample.$2 < mark.$2
          : (sample.$1 - best!).abs() < (mark.$1 - best!).abs();
      if (better) mark = sample;
    }
    canvas.drawCircle(Offset(x(mark.$1), y(mark.$2)), 3, Paint()..color = dot);
  }

  @override
  bool shouldRepaint(_VCurvePainter old) =>
      !listEquals(old.points, points) ||
      old.best != best ||
      old.line != line ||
      old.dot != dot;
}

class _GuiderIdleCard extends ConsumerWidget {
  const _GuiderIdleCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final l10n = context.l10n;
    final guider = ref.watch(nightGuiderIdleProvider);
    final state = guider.state;
    final (String status, Color statusColor) = !guider.connected
        ? (l10n.text('nightCtrGuideNotConnected'), colors.textMuted)
        : switch (state) {
            Phd2State.guiding => (
                l10n.text('nightCtrGuideGuiding'),
                colors.success
              ),
            Phd2State.looping => (
                l10n.text('nightCtrGuideLooping'),
                colors.success
              ),
            Phd2State.calibrating => (
                l10n.text('nightCtrGuideCalibrating'),
                colors.textSecondary
              ),
            Phd2State.settling => (
                l10n.text('nightCtrGuideSettling'),
                colors.textSecondary
              ),
            Phd2State.paused => (
                l10n.text('nightCtrGuidePaused'),
                colors.warning
              ),
            Phd2State.lostLock => (
                l10n.text('nightCtrGuideLost'),
                colors.warning
              ),
            Phd2State.selected => (
                l10n.text('nightCtrGuideSelected'),
                colors.textSecondary
              ),
            Phd2State.unknown || null => (
                l10n.text('nightCtrGuideUnknown'),
                colors.textMuted
              ),
            Phd2State.stopped => (
                l10n.text('nightCtrGuideIdle'),
                colors.warning
              ),
          };
    final idle = guider.connected &&
        (state == Phd2State.stopped || state == Phd2State.selected);
    final body = !guider.connected
        ? l10n.text('nightCtrGuideOpenBody')
        : idle
            ? l10n.text('nightCtrGuideIdleBody')
            : null;

    final String? loopReason = !guider.canCommand
        ? l10n.text('nightActWhyNoHost')
        : !guider.connected
            ? l10n.text('nightActWhyNoGuider')
            : !idle
                ? l10n.text('nightCtrGuideAlreadyRunning')
                : null;
    final String? openReason =
        guider.canCommand ? null : l10n.text('nightActWhyNoHost');

    return _Cell(
      title: l10n.text('nightCtrChartGuide'),
      note: status,
      noteColor: statusColor,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (body != null)
            Flexible(
              child: Text(
                body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: SkotiqTypography.captionSm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          const Spacer(),
          SingleChildScrollView(
            primary: false,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                if (guider.connected)
                  _CardButton(
                    label: l10n.text('nightCtrGuideStartLooping'),
                    disabledReason: loopReason,
                    onPressed: () => _loop(ref, l10n),
                  )
                else
                  _CardButton(
                    label: l10n.text('nightCtrGuideOpen'),
                    disabledReason: openReason,
                    onPressed: () => _open(ref, l10n),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _loop(WidgetRef ref, SkotiqLocalizations l10n) {
    final notifications = ref.read(uiNotificationProvider.notifier);
    unawaited(
      ref.read(phd2ControllerProvider).loop().catchError((Object error) {
        notifications.showError(
          l10n.text('nightCtrGuideLoopFailed', params: {'detail': '$error'}),
        );
      }),
    );
  }

  /// Connects PHD2 the way the Guide tab does, which starts PHD2 on this
  /// machine first when its socket is closed (the PHD2 launcher).
  void _open(WidgetRef ref, SkotiqLocalizations l10n) {
    final notifications = ref.read(uiNotificationProvider.notifier);
    final controller = ref.read(phd2ControllerProvider);
    unawaited(() async {
      try {
        final settings = await ref.read(appSettingsProvider.future);
        await controller.connect(settings.phd2Host, settings.phd2Port);
      } catch (error) {
        notifications.showError(
          l10n.text('nightCtrGuideOpenFailed', params: {'detail': '$error'}),
        );
      }
    }());
  }
}

class _CardButton extends StatelessWidget {
  const _CardButton({
    required this.label,
    required this.onPressed,
    this.disabledReason,
  });

  final String label;
  final VoidCallback onPressed;
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final enabled = disabledReason == null;
    final button = Semantics(
      button: true,
      enabled: enabled,
      label: label,
      hint: disabledReason,
      excludeSemantics: true,
      onTap: enabled ? onPressed : null,
      child: Material(
        color: enabled
            ? colors.surfaceHover
            : colors.surfaceHover.withValues(alpha: SkotiqTokens.opacityMuted),
        borderRadius: SkotiqTokens.borderRadiusLg,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: SkotiqTokens.borderRadiusLg,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 28),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  style: SkotiqTypography.labelSm.copyWith(
                    color: enabled ? colors.textPrimary : colors.textMuted,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final reason = disabledReason;
    if (reason == null) return button;
    return Tooltip(message: reason, excludeFromSemantics: true, child: button);
  }
}

class _CoolingCard extends ConsumerWidget {
  const _CoolingCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final vm = ref.watch(nightCoolerHistoryProvider);
    final title = l10n.text('nightCtrChartCooling');
    final sensor = _values(_lineOf(vm, NightSeriesId.sensorTemp));
    final from = vm.from;
    final semantic = sensor.isEmpty
        ? l10n.text('nightCtrSemNoData', params: {'title': title})
        : l10n.text(
            'nightCtrSemRange',
            params: <String, String>{
              'name': l10n.text('nightCtrSemSensor'),
              'from': nightCelsius(sensor.first),
              'to': nightCelsius(sensor.last),
            },
          );
    return _Cell(
      title: title,
      note: from == null
          ? null
          : l10n.text(
              'nightCtrSince',
              params: <String, String>{'time': nightClockHm(from)},
            ),
      body: _ChartBody(
        semanticLabel: semantic,
        empty: sensor.isEmpty ? l10n.text('nightCtrCoolingNone') : null,
        lines: <SeriesChartLine>[for (final line in vm.lines) _line(line)],
        from: vm.from,
        to: vm.to,
      ),
      legend: sensor.isEmpty ? null : _legend(context, vm),
    );
  }
}
