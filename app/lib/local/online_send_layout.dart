import 'package:flutter/widgets.dart';

double onlineSendDialogWidth(
  Size screenSize, {
  double preferred = 440,
  double horizontalInset = 16,
}) {
  final available = screenSize.width - horizontalInset * 2;
  if (!available.isFinite || available <= 0) return preferred;
  return available < preferred ? available : preferred;
}

double onlineSendUserChipWidth(
  BoxConstraints constraints, {
  double preferred = 180,
  double maxFraction = 0.48,
}) {
  final maxWidth = constraints.maxWidth;
  if (!maxWidth.isFinite || maxWidth <= 0) return preferred;
  final available = maxWidth * maxFraction.clamp(0, 1);
  return available < preferred ? available : preferred;
}
