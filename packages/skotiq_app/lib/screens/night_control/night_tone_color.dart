import 'package:flutter/widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The color a [MetricGridTone] reads in on Tonight, on [colors].
Color nightToneColor(MetricGridTone tone, SkotiqColors colors) =>
    switch (tone) {
      MetricGridTone.neutral => colors.textPrimary,
      MetricGridTone.good => colors.success,
      MetricGridTone.warning => colors.warning,
      MetricGridTone.bad => colors.error,
    };
