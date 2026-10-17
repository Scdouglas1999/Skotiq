import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../imaging/widgets/osc_stacking_controls.dart';

/// A run failure split into what the operator reads and what a developer needs.
class StackShareFailure {
  /// The sentence to show: the payload of the failure, with the exception /
  /// bridge wrapper stripped off.
  final String message;

  /// A concrete next step for the causes we can actually name one for, or null
  /// when we would only be guessing (a wrong next step at 2am is worse than
  /// none).
  final String? nextStep;

  /// The unmodified exception text, for the collapsed technical section. Null
  /// when it is identical to [message] and would add nothing.
  final String? technical;

  const StackShareFailure({
    required this.message,
    this.nextStep,
    this.technical,
  });
}

/// Matches a freezed / flutter_rust_bridge stringified union, e.g.
/// `SkotiqError.imageError(field0: Reference frame has only 0 stars)`.
/// The name must be followed immediately by `(`, so a real sentence that merely
/// ends in a parenthetical ("… 10.34px (max 10.00px)") is left alone.
final RegExp _bridgeWrapper = RegExp(
  r'^[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*\(\s*(?:field0:\s*)?(.*)\)$',
  dotAll: true,
);

/// Matches a Dart exception's `toString()` type prefix, e.g.
/// `LiveStackBusyException: …` or `Exception: …`.
final RegExp _exceptionPrefix = RegExp(
  r'^[A-Za-z_$][\w$]*(?:Exception|Error|Failure)?:\s+',
);

/// Turn the orchestrator's raw exception string into something an imager can
/// act on.
///
/// `e.toString()` renders the Rust union's Dart wrapper —
/// `SkotiqError.imageError(field0: …)`, positional-field label and all —
/// rather than the sentence inside it. This unwraps the payload (nested
/// wrappers included), keeps the raw text for the technical-details disclosure,
/// and attaches a next step for the causes that have one.
StackShareFailure describeStackShareFailure(String raw) {
  var message = raw.trim();
  // Peel layer by layer: an app exception can carry a bridge union, which can
  // carry another. Bounded so a pathological string cannot spin here.
  for (var i = 0; i < 4; i++) {
    final before = message;
    final prefix = _exceptionPrefix.firstMatch(message);
    if (prefix != null && prefix.end < message.length) {
      message = message.substring(prefix.end).trim();
    }
    final match = _bridgeWrapper.firstMatch(message);
    final inner = match?.group(1)?.trim();
    if (inner != null && inner.isNotEmpty) message = inner;
    if (message == before) break;
  }
  if (message.isEmpty) message = raw.trim();

  final lower = message.toLowerCase();
  String? nextStep;
  if (lower.contains('stars') &&
      (lower.contains('need at least') || lower.contains('too few'))) {
    nextStep = 'No usable stars were found in the reference frame. Check focus '
        'and tracking for this session, and if the calibration masters are '
        'suspect, re-run with "Apply calibration" off.';
  } else if (lower.contains('alignment residual too high')) {
    nextStep = 'The reference frame could not be aligned tightly enough. Cull '
        'the trailed or badly guided subs in Session Review, or pick a session '
        'whose subs share one pointing, then run again.';
  } else if (lower.contains('follower frames was rejected')) {
    nextStep = 'Only the reference survived, so there is nothing to integrate. '
        'Address the reason above — usually culling the bad subs in Session '
        'Review — and run again.';
  } else if (lower.contains('no lights') || lower.contains('no light frames')) {
    nextStep = 'Accept at least one light frame for this session (Session '
        'Review → Workbench) and run again.';
  }

  final trimmedRaw = raw.trim();
  return StackShareFailure(
    message: message,
    nextStep: nextStep,
    technical: trimmedRaw == message ? null : trimmedRaw,
  );
}

/// Launcher dialog for the **Stack-and-Share Loop**.
///
/// Summarises the lights selected for [sessionId] (target, per-filter frame
/// counts, total integration, frame count), lets the operator tune the run
/// (calibration, auto-stretch, quality gate), and drives
/// [stackAndShareProvider] end-to-end. While the run is in flight it renders a
/// live [SkotiqProgressBar] with the current phase and frame counters. On
/// success it auto-pops and navigates to the result viewer
/// (`/stack-result?id=<resultId>`); on failure it surfaces the error inline as a
/// [SkotiqBanner].
///
/// Show it with [StackAndShareDialog.show], which wires the dialog into a
/// [SkotiqDialog] scaffold via `showDialog`.
class StackAndShareDialog extends ConsumerStatefulWidget {
  /// Imaging session whose lights are stacked.
  final int sessionId;

  /// Pre-computed selection summary for [sessionId], used to render the summary
  /// well (target, per-filter counts, integration, frame count) before the run
  /// starts. The orchestrator re-selects internally; this is purely the
  /// human-facing preview the operator confirms.
  final StackSelectionSummary selection;

  const StackAndShareDialog({
    super.key,
    required this.sessionId,
    required this.selection,
  });

  /// Show the Stack-and-Share launcher for [sessionId] with its [selection]
  /// preview. Resolves when the dialog is dismissed.
  static Future<void> show(
    BuildContext context, {
    required int sessionId,
    required StackSelectionSummary selection,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StackAndShareDialog(
        sessionId: sessionId,
        selection: selection,
      ),
    );
  }

  @override
  ConsumerState<StackAndShareDialog> createState() =>
      _StackAndShareDialogState();
}

class _StackAndShareDialogState extends ConsumerState<StackAndShareDialog> {
  late bool _applyCalibration;
  late bool _autoStretch;
  late final TextEditingController _qualityController;

  /// Sensor acquisition mode for the run: `'auto'`, `'mono'`, or `'osc'`.
  /// Folded into [StackAndShareConfig.sensorMode] by [_buildConfig].
  late String _sensorMode;

  /// Bayer-pattern override dropdown value ([oscBayerAutoValue] → no override),
  /// folded into [StackAndShareConfig.bayerPatternOverride].
  late String _bayerPattern;

  /// Demosaic-quality dropdown value, folded into
  /// [StackAndShareConfig.demosaicQuality].
  late String _demosaicQuality;

  /// Whether the manual OSC override controls are expanded. Only relevant when
  /// a colour camera is auto-detected (otherwise the controls are always shown).
  bool _oscOverrideExpanded = false;

  /// Parse error for the quality field, surfaced inline. Null when the field
  /// holds a valid (or empty → "no gate") value.
  String? _qualityError;

  /// Guards against double-navigation if the provider emits `complete` more than
  /// once (e.g. a rebuild after the post-frame callback is already scheduled).
  bool _navigated = false;

  /// Whether the raw exception text is expanded under the failure alert.
  bool _showTechnicalDetail = false;

  @override
  void initState() {
    super.initState();
    const defaults = StackAndShareConfig.defaults;
    _applyCalibration = defaults.applyCalibration;
    _autoStretch = defaults.autoStretch;
    _sensorMode = defaults.sensorMode;
    _bayerPattern =
        defaults.bayerPatternOverride?.toUpperCase() ?? oscBayerAutoValue;
    _demosaicQuality = defaults.demosaicQuality.toLowerCase();
    _qualityController = TextEditingController(
      text: defaults.minQualityScore > 0
          ? _trimNum(defaults.minQualityScore)
          : '',
    );
  }

  @override
  void dispose() {
    _qualityController.dispose();
    super.dispose();
  }

  /// Parse the quality field. An empty field means "no quality gate" (`0`); a
  /// non-numeric or negative value is a hard input error we surface rather than
  /// silently coercing to a default.
  double? _parseQuality() {
    final text = _qualityController.text.trim();
    if (text.isEmpty) return 0;
    final value = double.tryParse(text);
    if (value == null) {
      setState(
          () => _qualityError = 'Enter a number (or leave blank for none)');
      return null;
    }
    if (value < 0) {
      setState(() => _qualityError = 'Quality threshold cannot be negative');
      return null;
    }
    if (_qualityError != null) {
      setState(() => _qualityError = null);
    }
    return value;
  }

  StackAndShareConfig _buildConfig(double quality) {
    // The Auto sentinel means "no override" — let the engine resolve the
    // pattern from the reference frame's FITS BAYERPAT geometry. Because the
    // model's copyWith treats a null `bayerPatternOverride` as "leave unchanged"
    // (not "clear"), the Auto case is expressed by constructing directly with
    // null rather than copying.
    final override = _bayerPattern == oscBayerAutoValue ? null : _bayerPattern;
    return StackAndShareConfig(
      applyCalibration: _applyCalibration,
      autoStretch: _autoStretch,
      minQualityScore: quality,
      sensorMode: _sensorMode,
      bayerPatternOverride: override,
      demosaicQuality: _demosaicQuality,
    );
  }

  /// The detected Bayer pattern of the currently connected colour camera
  /// (upper-cased, e.g. `'RGGB'`), or null when no colour camera is connected /
  /// the query is in flight / the driver reported no pattern.
  ///
  /// Drives the auto-detected read-only summary in the OSC options. A null
  /// result means "no live OSC hint" — the manual controls are shown directly
  /// rather than a guessed pattern (errors/uncertainty surface, never a
  /// silent colour assumption).
  String? _detectedOscPattern() {
    final deviceId = ref.watch(connectedCameraIdProvider);
    if (deviceId == null || deviceId.isEmpty) return null;
    final caps = ref.watch(equipmentCameraCapabilitiesProvider(deviceId));
    final value = caps.maybeWhen(
      data: (c) => c,
      orElse: () => null,
    );
    if (value == null || !value.isColor) return null;
    final raw = value.bayerPattern?.trim().toUpperCase();
    if (raw == null || raw.isEmpty) return null;
    return oscBayerPatternValues.contains(raw) ? raw : null;
  }

  Future<void> _start() async {
    final quality = _parseQuality();
    if (quality == null) return; // Inline error already surfaced.

    final config = _buildConfig(quality);
    // Fire-and-forget: the notifier owns failure presentation and never
    // rethrows, so the dialog just listens to state transitions below.
    await ref
        .read(stackAndShareProvider.notifier)
        .runForSession(widget.sessionId, config: config);
  }

  void _onComplete(StackAndShareResult result) {
    if (_navigated) return;
    final id = result.id;
    if (id == null) {
      // A completed run without a persisted id cannot be opened in the viewer.
      // Rather than navigate to a broken route, surface it: the notifier marks
      // the run complete only after the DAO insert, so a null id here is a real
      // invariant break worth showing.
      return;
    }
    _navigated = true;
    // Defer navigation/pop out of the build/listener frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop();
      context.push('/stack-result?id=$id');
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(stackAndShareProvider);

    // Navigate to the result viewer as soon as a run completes successfully.
    ref.listen<StackAndShareState>(stackAndShareProvider, (prev, next) {
      if (next.isComplete && next.result != null) {
        _onComplete(next.result!);
      }
    });

    final running = state.isRunning;

    return SkotiqDialog(
      title: 'Stack & Share',
      icon: SkotiqIcons.layers,
      width: 600,
      // Block the close button while a run is active so we never tear the
      // dialog down mid-pipeline.
      showCloseButton: !running,
      actions: [
        SkotiqButton(
          label: 'Close',
          variant: ButtonVariant.ghost,
          onPressed: running ? null : () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          label: running ? 'Stacking…' : 'Start',
          icon: SkotiqIcons.play,
          isLoading: running,
          onPressed: running ? null : _start,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _SelectionSummary(selection: widget.selection),
          if (state.errorMessage != null) ...[
            const SizedBox(height: SkotiqTokens.spaceLg),
            _buildError(context, state.errorMessage!),
          ],
          const SizedBox(height: SkotiqTokens.spaceLg),
          _buildOptions(running),
          if (running) ...[
            const SizedBox(height: SkotiqTokens.spaceXl),
            _RunProgress(progress: state.progress),
          ],
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context, String raw) {
    // The orchestrator surfaces the raw exception string. When it is a
    // live-stacking conflict, give the operator the concrete next step.
    final isBusy = raw.contains('LiveStackBusyException') ||
        raw.contains('Stop live stacking');
    if (isBusy) {
      return SkotiqBanner(
        tone: BannerTone.error,
        title: 'Live stacking is active',
        message: 'The stacking engine is busy with a live session. Stop live '
            'stacking before running Stack & Share.',
        action: SkotiqButton(
          label: 'Stop live stacking',
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          icon: SkotiqIcons.stopCircle,
          onPressed: _stopLiveStacking,
        ),
      );
    }

    final colors = SkotiqColors.of(context);
    final failure = describeStackShareFailure(raw);
    final body = failure.nextStep == null
        ? failure.message
        : '${failure.message}\n\n${failure.nextStep}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SkotiqBanner(
          tone: BannerTone.error,
          title: 'Stack & Share failed',
          message: body,
          action: failure.technical == null
              ? null
              : SkotiqButton(
                  label: _showTechnicalDetail
                      ? 'Hide technical details'
                      : 'Technical details',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                  icon: _showTechnicalDetail
                      ? SkotiqIcons.chevronDown
                      : SkotiqIcons.chevronRight,
                  onPressed: () => setState(
                    () => _showTechnicalDetail = !_showTechnicalDetail,
                  ),
                ),
        ),
        if (failure.technical != null && _showTechnicalDetail) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          Container(
            constraints: const BoxConstraints(maxHeight: 160),
            padding: SkotiqTokens.paddingMd,
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: SkotiqTokens.borderRadiusMd,
              border: Border.all(color: colors.border),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                failure.technical!,
                style: SkotiqTypography.monoSm
                    .copyWith(color: colors.textMuted),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _stopLiveStacking() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(liveStackingProvider.notifier).stop();
      if (!mounted) return;
      // Clear the prior error so the user can immediately retry.
      ref.read(stackAndShareProvider.notifier).reset();
    } catch (e) {
      if (!mounted) return;
      // Surface the stop failure rather than leaving the user stuck.
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not stop live stacking: $e')),
      );
    }
  }

  Widget _buildOptions(bool running) {
    return SectionWell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SectionTitle(icon: SkotiqIcons.sliders, title: 'Options'),
          const SizedBox(height: SkotiqTokens.spaceSm),
          SkotiqSwitchRow(
            label: 'Apply calibration',
            subtitle: 'Subtract matched dark / flat / bias before stacking',
            value: _applyCalibration,
            onChanged:
                running ? null : (v) => setState(() => _applyCalibration = v),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqSwitchRow(
            label: 'Auto-stretch',
            subtitle:
                'Apply the screen-transfer (STF) stretch to the integrated '
                'result for display and export',
            value: _autoStretch,
            onChanged: running ? null : (v) => setState(() => _autoStretch = v),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _buildOscOptions(running),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _buildQualityField(running),
        ],
      ),
    );
  }

  /// The OSC / colour options.
  ///
  /// When a live colour camera is detected, the section leads with a read-only
  /// "Auto-detected" summary (so the common case needs no interaction) and
  /// tucks the manual override controls behind an expansion. With no live
  /// colour hint the controls are shown directly.
  Widget _buildOscOptions(bool running) {
    final colors = context.skotiqColors;
    final detected = _detectedOscPattern();
    final oscEnabled = _sensorMode.toLowerCase() != 'mono';

    final toggle = SkotiqSwitchRow(
      label: 'OSC / Color',
      subtitle: 'Demosaic Bayer frames to RGB',
      value: oscEnabled,
      onChanged: running
          ? null
          : (v) => setState(() => _sensorMode = v ? 'auto' : 'mono'),
    );

    if (!oscEnabled) {
      return toggle;
    }

    final manualControls = <Widget>[
      OscDropdownField(
        label: 'Bayer pattern',
        value: _bayerPattern,
        items: oscBayerPatternValues,
        itemLabels: oscBayerPatternValues
            .map((v) => oscBayerPatternLabel(v, detected))
            .toList(growable: false),
        enabled: !running,
        onChanged: (v) {
          if (v == null) return;
          setState(() => _bayerPattern = v);
        },
      ),
      const SizedBox(height: SkotiqTokens.spaceMd),
      OscDropdownField(
        label: 'Demosaic quality',
        value: _demosaicQuality,
        items: oscDemosaicQualityValues,
        itemLabels: oscDemosaicQualityValues
            .map((v) => oscDemosaicQualityLabels[v] ?? v)
            .toList(growable: false),
        enabled: !running,
        onChanged: (v) {
          if (v == null) return;
          setState(() => _demosaicQuality = v);
        },
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        toggle,
        const SizedBox(height: SkotiqTokens.spaceMd),
        if (detected != null) ...[
          // Live colour camera detected: surface the auto-detection read-only,
          // with the manual override behind an expander.
          SkotiqBanner(
            title: 'Colour camera detected',
            message: 'Auto-detected: OSC $detected',
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _OverrideDisclosure(
            expanded: _oscOverrideExpanded,
            colors: colors,
            onToggle: running
                ? null
                : () => setState(
                    () => _oscOverrideExpanded = !_oscOverrideExpanded),
          ),
          if (_oscOverrideExpanded) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            ...manualControls,
          ],
        ] else
          ...manualControls,
      ],
    );
  }

  Widget _buildQualityField(bool running) {
    return SkotiqTextField(
      label: 'Quality threshold',
      hint: 'e.g. 0.5 (blank = no gate)',
      controller: _qualityController,
      enabled: !running,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      ],
      errorText: _qualityError,
      onChanged: (_) {
        if (_qualityError != null) {
          setState(() => _qualityError = null);
        }
      },
    );
  }
}

/// The selection-summary well: target name, per-filter pill rows, total
/// integration, and frame count.
class _SelectionSummary extends StatelessWidget {
  final StackSelectionSummary selection;

  const _SelectionSummary({required this.selection});

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final filterEntries = selection.perFilterCounts.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return SectionWell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            selection.targetName ?? 'Stacked result',
            style: SkotiqTypography.sectionTitle
                .copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          if (filterEntries.isNotEmpty) ...[
            Wrap(
              spacing: SkotiqTokens.spaceSm,
              runSpacing: SkotiqTokens.spaceSm,
              children: [
                for (final e in filterEntries)
                  StatusPill(
                    icon: SkotiqIcons.filter,
                    label: e.key,
                    value: '${e.value}',
                    status: StatusPillStatus.active,
                  ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
          ],
          Row(
            children: [
              Expanded(
                child: _MetricColumn(
                  label: 'Integration',
                  value: formatHms(selection.totalIntegrationSecs),
                ),
              ),
              Expanded(
                child: _MetricColumn(
                  label: 'Frames',
                  value: '${selection.selectedCount}',
                ),
              ),
            ],
          ),
          if (selection.excludedCount > 0) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              '${selection.excludedCount} frame'
              '${selection.excludedCount == 1 ? '' : 's'} excluded by quality / '
              'filter gates',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A label-over-value metric using tabular telemetry type for the value.
class _MetricColumn extends StatelessWidget {
  final String label;
  final String value;

  const _MetricColumn({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: SkotiqTypography.labelSm.copyWith(
            color: colors.textMuted,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          value,
          style: SkotiqTypography.telemetryMd.copyWith(
            color: colors.textPrimary,
          ),
        ),
      ],
    );
  }
}

/// Live progress display while a run is in flight: a bar bound to
/// [StackAndShareProgress.fraction], the current phase label, and the
/// `frame X/Y, Z rejected` counter.
class _RunProgress extends StatelessWidget {
  final StackAndShareProgress progress;

  const _RunProgress({required this.progress});

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _phaseLabel(progress.phase),
                style: SkotiqTypography.telemetryMd.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
            Text(
              '${(progress.fraction * 100).round()}%',
              style: SkotiqTypography.monoSm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        SkotiqProgressBar(value: progress.fraction),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Text(
          'frame ${progress.framesProcessed}/${progress.framesTotal}, '
          '${progress.framesRejected} rejected',
          style: SkotiqTypography.monoSm.copyWith(
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }

  static String _phaseLabel(StackAndSharePhase phase) {
    return switch (phase) {
      StackAndSharePhase.idle => 'Idle',
      StackAndSharePhase.selectingLights => 'Selecting lights…',
      StackAndSharePhase.calibrating => 'Calibrating…',
      StackAndSharePhase.stacking => 'Stacking…',
      StackAndSharePhase.stretching => 'Stretching…',
      StackAndSharePhase.exporting => 'Exporting…',
      StackAndSharePhase.complete => 'Complete',
      StackAndSharePhase.error => 'Failed',
    };
  }
}

/// Formats a number without a trailing `.0` for whole values, otherwise with a
/// single decimal place (mirrors the model helper, kept private to the UI).
String _trimNum(double value) {
  if (value == value.roundToDouble()) {
    return value.round().toString();
  }
  return value.toStringAsFixed(1);
}

/// The "Override auto-detection" disclosure row that expands the manual OSC
/// controls when a colour camera was auto-detected.
class _OverrideDisclosure extends StatelessWidget {
  final bool expanded;
  final SkotiqColors colors;
  final VoidCallback? onToggle;

  const _OverrideDisclosure({
    required this.expanded,
    required this.colors,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onToggle != null;
    final tint = enabled ? colors.primary : colors.textMuted;
    return InkWell(
      onTap: onToggle,
      borderRadius: SkotiqTokens.borderRadiusSm,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: SkotiqTokens.spaceXs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              expanded
                  ? SkotiqIcons.chevronDown
                  : SkotiqIcons.chevronRight,
              size: SkotiqTokens.iconSm,
              color: tint,
            ),
            const SizedBox(width: SkotiqTokens.spaceXs),
            Text(
              'Override auto-detection',
              style: SkotiqTypography.label.copyWith(color: tint),
            ),
          ],
        ),
      ),
    );
  }
}
