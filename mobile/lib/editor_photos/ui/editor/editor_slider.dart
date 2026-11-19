// Google-Photos-style slider: thin bar thumb, the track filled from the neutral point to
// the value, double-tap to reset (input[type=range] + paintRange in editor.js).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:immich_mobile/editor_photos/model/js_compat.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_style.dart';

/// `formatValue` in editor.js: +NN / −NN / 0
String formatSliderValue(double v) => v == 0 ? '0' : '${v > 0 ? '+' : '−'}${jsRound(v.abs() * 100).toInt()}';

class EditorSlider extends StatelessWidget {
  const EditorSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = -1,
    this.max = 1,
    this.step = 0.01,
    this.neutral = 0,
    this.label,
    this.format,
    this.hueTrack = false,
    this.onChangeEnd,
  });

  final double value;
  final double min;
  final double max;
  final double step;

  /// Where the fill starts and what double-tap resets to
  final double neutral;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeEnd;
  final String? label;

  /// How values read out to accessibility services
  final String Function(double value)? format;

  /// A rainbow track instead of the fill (colour grading hues)
  final bool hueTrack;

  double _snap(double raw) {
    final steps = jsRound((raw - min) / step);
    final v = min + steps * step;
    // Remove float noise (0.30000000000000004) so values compare and store cleanly
    return double.parse(clampD(v, min, max).toStringAsFixed(6));
  }

  double _valueAt(double dx, double width) {
    final t = width <= 0 ? 0.0 : clampD(dx / width, 0, 1);
    return _snap(min + t * (max - min));
  }

  void _set(double v) {
    if (v != value) {
      onChanged(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bigStep = math.max(step, (max - min) / 20);
    final fmt = format ?? (double v) => v.toStringAsFixed(2);
    final up = _snap(math.min(max, value + bigStep));
    final down = _snap(math.max(min, value - bigStep));
    return Semantics(
      slider: true,
      label: label,
      value: fmt(value),
      increasedValue: fmt(up),
      decreasedValue: fmt(down),
      onIncrease: () => _set(up),
      onDecrease: () => _set(down),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              _set(_valueAt(details.localPosition.dx, width));
              onChangeEnd?.call();
            },
            onDoubleTap: () {
              _set(_snap(neutral));
              onChangeEnd?.call();
            },
            onHorizontalDragStart: (details) => _set(_valueAt(details.localPosition.dx, width)),
            onHorizontalDragUpdate: (details) => _set(_valueAt(details.localPosition.dx, width)),
            onHorizontalDragEnd: (_) => onChangeEnd?.call(),
            child: SizedBox(
              width: width,
              height: 30,
              child: CustomPaint(
                painter: _SliderPainter(value: value, min: min, max: max, neutral: neutral, hueTrack: hueTrack),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SliderPainter extends CustomPainter {
  _SliderPainter({
    required this.value,
    required this.min,
    required this.max,
    required this.neutral,
    required this.hueTrack,
  });

  final double value;
  final double min;
  final double max;
  final double neutral;
  final bool hueTrack;

  static final _hueColors = [for (var h = 0; h <= 360; h += 60) HSLColor.fromAHSL(1, h % 360, 0.8, 0.55).toColor()];

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final range = max - min;
    double xOf(double v) => range == 0 ? 0 : clampD((v - min) / range, 0, 1) * size.width;
    final track = RRect.fromLTRBR(0, cy - 4, size.width, cy + 4, const Radius.circular(4));
    if (hueTrack) {
      canvas.drawRRect(track, Paint()..shader = LinearGradient(colors: _hueColors).createShader(Offset.zero & size));
    } else {
      canvas.drawRRect(track, Paint()..color = EditorColors.track);
      final a = xOf(value);
      final b = xOf(neutral);
      final lo = math.min(a, b);
      final hi = math.max(a, b);
      if (hi > lo) {
        canvas.save();
        canvas.clipRRect(track);
        canvas.drawRect(Rect.fromLTRB(lo, cy - 4, hi, cy + 4), Paint()..color = EditorColors.accent);
        canvas.restore();
      }
    }
    final x = clampD(xOf(value), 2, size.width - 2);
    canvas.drawRRect(
      RRect.fromLTRBR(x - 2, cy - 11, x + 2, cy + 11, const Radius.circular(2)),
      Paint()..color = hueTrack ? EditorColors.text : EditorColors.accent,
    );
  }

  @override
  bool shouldRepaint(_SliderPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.min != min ||
      oldDelegate.max != max ||
      oldDelegate.neutral != neutral ||
      oldDelegate.hueTrack != hueTrack;
}

/// Label, value and slider (`.slider-row`); the label turns accent when off neutral
class SliderRow extends StatelessWidget {
  const SliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = -1,
    this.max = 1,
    this.step = 0.01,
    this.neutral = 0,
    this.format,
    this.hueTrack = false,
    this.showValue = true,
    this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final double step;
  final double neutral;
  final String Function(double value)? format;
  final bool hueTrack;
  final bool showValue;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final active = value != neutral;
    final text = (format ?? formatSliderValue)(value);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 14, color: active ? EditorColors.accent : EditorColors.text),
                ),
              ),
              if (showValue)
                Text(
                  text,
                  style: const TextStyle(
                    fontSize: 12,
                    color: EditorColors.muted,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
          EditorSlider(
            value: value,
            min: min,
            max: max,
            step: step,
            neutral: neutral,
            label: label,
            format: format ?? formatSliderValue,
            hueTrack: hueTrack,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ],
      ),
    );
  }
}
