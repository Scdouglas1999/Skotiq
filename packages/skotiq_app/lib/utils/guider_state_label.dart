import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// What every screen calls a guider's state (a localization key), and its
/// tone. The built-in guider reports through the same states as PHD2.
(String key, MetricGridTone tone) guiderStateLabel(Phd2State state) =>
    switch (state) {
      Phd2State.stopped => ('nightScopeGuideStopped', MetricGridTone.neutral),
      Phd2State.selected => ('nightScopeGuideSelected', MetricGridTone.neutral),
      Phd2State.looping => ('nightScopeGuideLooping', MetricGridTone.warning),
      Phd2State.calibrating => (
          'nightScopeGuideCalibrating',
          MetricGridTone.warning
        ),
      Phd2State.guiding => ('nightScopeGuideGuiding', MetricGridTone.good),
      Phd2State.settling => ('nightScopeGuideSettling', MetricGridTone.warning),
      Phd2State.paused => ('nightScopeGuidePaused', MetricGridTone.warning),
      Phd2State.lostLock => ('nightScopeGuideLostLock', MetricGridTone.bad),
      Phd2State.unknown => ('nightScopeGuideUnknown', MetricGridTone.warning),
    };
