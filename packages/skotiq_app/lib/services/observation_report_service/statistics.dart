// Pure numeric helpers used by report summary tables.
part of '../observation_report_service.dart';

double _listMin(List<double> values) {
  var min = values.first;
  for (final v in values) {
    if (v < min) min = v;
  }
  return min;
}

double _listMax(List<double> values) {
  var max = values.first;
  for (final v in values) {
    if (v > max) max = v;
  }
  return max;
}

double _listMean(List<double> values) {
  if (values.isEmpty) return 0.0;
  var sum = 0.0;
  for (final v in values) {
    sum += v;
  }
  return sum / values.length;
}

double _listMedian(List<double> values) {
  if (values.isEmpty) return 0.0;
  final sorted = List<double>.from(values)..sort();
  final mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[mid];
  return (sorted[mid - 1] + sorted[mid]) / 2.0;
}

double _rms(List<double> values) {
  if (values.isEmpty) return 0.0;
  var sumSq = 0.0;
  for (final v in values) {
    sumSq += v * v;
  }
  return math.sqrt(sumSq / values.length);
}
