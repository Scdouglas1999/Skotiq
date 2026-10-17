part of '../predictive_af_service.dart';

class _RegressionFit {
  final double slope;
  final double intercept;
  final double referenceTemp;
  final double rSquared;

  const _RegressionFit({
    required this.slope,
    required this.intercept,
    required this.referenceTemp,
    required this.rSquared,
  });
}
