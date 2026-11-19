// The rotation ruler below the photo in the crop tab (updateRuler and the ruler drag in
// editor.js): drag the tape left or right; ticks every degree, labels every 15°.
import 'package:flutter/material.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_style.dart';

const rulerPxPerDegree = 4.0;

/// "0°", "-4.7°", "12°": whole degrees without a decimal, else one decimal
String formatAngle(double angle) =>
    angle == angle.roundToDouble() ? '${angle.round()}°' : '${angle.toStringAsFixed(1)}°';

class RotationRuler extends StatefulWidget {
  const RotationRuler({super.key, required this.angle, required this.onChanged, required this.onEnd, this.onEditExact});

  final double angle;

  /// The new (unrounded) angle while dragging; the controller rounds and snaps it
  final ValueChanged<double> onChanged;

  /// The drag ended (`endStraighten`)
  final VoidCallback onEnd;

  /// Double-tap on the value: type an exact angle
  final VoidCallback? onEditExact;

  @override
  State<RotationRuler> createState() => _RotationRulerState();
}

class _RotationRulerState extends State<RotationRuler> {
  int? _pointer;
  double _startX = 0;
  double _startAngle = 0;

  void _down(PointerDownEvent event) {
    if (_pointer != null) {
      return;
    }
    _pointer = event.pointer;
    _startX = event.position.dx;
    _startAngle = widget.angle;
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) {
      return;
    }
    final dx = event.position.dx - _startX;
    // Smooth drag (no whole-degree steps)
    widget.onChanged(_startAngle - dx / rulerPxPerDegree);
  }

  void _end(PointerEvent event) {
    if (event.pointer != _pointer) {
      return;
    }
    _pointer = null;
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    final angle = widget.angle;
    final text = formatAngle(angle);
    return Semantics(
      slider: true,
      label: 'Rotation angle',
      value: text,
      increasedValue: formatAngle((angle + 1).clamp(-maxAngle, maxAngle)),
      decreasedValue: formatAngle((angle - 1).clamp(-maxAngle, maxAngle)),
      onIncrease: () {
        widget.onChanged(angle + 1);
        widget.onEnd();
      },
      onDecrease: () {
        widget.onChanged(angle - 1);
        widget.onEnd();
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _end,
        onPointerCancel: _end,
        child: SizedBox(
          height: 62,
          child: Stack(
            children: [
              Positioned.fill(child: CustomPaint(painter: _RulerPainter(angle))),
              Positioned(
                top: 2,
                left: 0,
                right: 0,
                child: Center(
                  child: GestureDetector(
                    onDoubleTap: widget.onEditExact,
                    child: ColoredBox(
                      color: EditorColors.stage,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          text,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: EditorColors.text,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter(this.angle);

  final double angle;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.width / 2;
    final h = size.height;
    final tick = Paint()..color = Colors.white.withValues(alpha: 0.55);
    final faded = Paint()..color = Colors.white.withValues(alpha: 0.55 * 0.3);
    for (var deg = -90; deg <= 90; deg++) {
      final x = mid + (deg - angle) * rulerPxPerDegree;
      if (x < -20 || x > size.width + 20) {
        continue;
      }
      final major = deg % 15 == 0;
      final outside = deg.abs() > maxAngle;
      final paint = outside ? faded : tick;
      canvas.drawRect(Rect.fromLTWH(x - 0.5, major ? h - 16 : h - 9, 1, major ? 10 : 4), paint);
      if (major && (x - mid).abs() > 18) {
        final label = TextPainter(
          text: TextSpan(
            text: '$deg°',
            style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: outside ? 0.55 * 0.3 : 0.55)),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(canvas, Offset(x - label.width / 2, h - 22 - label.height));
        label.dispose();
      }
    }
    // Centre marker
    canvas.drawPath(
      Path()
        ..moveTo(mid - 5, h - 1)
        ..lineTo(mid + 5, h - 1)
        ..lineTo(mid, h - 8)
        ..close(),
      Paint()..color = const Color(0xFFADCBFA),
    );
  }

  @override
  bool shouldRepaint(_RulerPainter oldDelegate) => oldDelegate.angle != angle;
}
