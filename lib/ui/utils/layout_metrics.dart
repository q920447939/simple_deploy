import 'package:flutter/widgets.dart';

double masterDetailLeftWidth(
  BoxConstraints constraints, {
  double min = 320,
  double max = 440,
  double ratio = 0.33,
}) {
  final w = constraints.maxWidth;
  if (!w.isFinite) return max;
  return (w * ratio).clamp(min, max);
}
