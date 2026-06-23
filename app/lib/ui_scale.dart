import 'package:flutter/widgets.dart';

import 'local/prefs.dart';

// Global UI zoom (like a browser's): one factor that scales all text, icons,
// paddings and bar heights together, so the cockpit fits without going
// fullscreen. Persisted to Prefs['ui.scale']; changing it rebuilds the whole app
// live via the [uiScale] notifier wired into MaterialApp.builder.

const uiScaleMin = 0.7;
const uiScaleMax = 1.3;
const uiScaleStep = 0.1;

final uiScale = ValueNotifier<double>(
  Prefs.getDouble(
    'ui.scale',
    def: 1.0,
  ).clamp(uiScaleMin, uiScaleMax).toDouble(),
);

void setUiScale(double v) {
  // snap to 5% steps so the slider/shortcuts land on clean values
  final c = (v.clamp(uiScaleMin, uiScaleMax) * 20).roundToDouble() / 20;
  if (c == uiScale.value) return;
  uiScale.value = c;
  Prefs.setDouble('ui.scale', c);
}

void nudgeUiScale(double delta) => setUiScale(uiScale.value + delta);

void resetUiScale() => setUiScale(1.0);

// UiScaler gives [child] `available ÷ scale` logical pixels, then GPU-scales it
// to fill the window — so scale < 1 lays the app out with more room (fits more)
// and scale > 1 with less. Identity at 1.0 (no Transform, crispest text), so
// default users are unaffected.
class UiScaler extends StatelessWidget {
  final Widget child;
  final double scale;
  const UiScaler({super.key, required this.child, required this.scale});

  @override
  Widget build(BuildContext context) {
    if (scale == 1.0) return child;
    final mq = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (ctx, c) {
        final w = c.maxWidth / scale, h = c.maxHeight / scale;
        return FittedBox(
          fit: BoxFit.fill,
          child: SizedBox(
            width: w,
            height: h,
            child: MediaQuery(
              data: mq.copyWith(size: Size(w, h)),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
