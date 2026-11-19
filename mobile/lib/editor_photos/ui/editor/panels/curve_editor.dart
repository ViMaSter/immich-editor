// Tone curve editor (the curves canvas in advanced-panel.js): tap to add a point, drag to
// move it between its neighbours, double-tap a point to remove it; at most 16 points.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/editor_photos/model/advanced.dart';
import 'package:immich_mobile/editor_photos/model/js_compat.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_style.dart';

const curveColours = {'rgb': Color(0xFFE3E3E8), 'r': Color(0xFFFF6B6B), 'g': Color(0xFF69DB7C), 'b': Color(0xFF74C0FC)};

const maxCurvePoints = 16;

class CurveEditor extends StatefulWidget {
  const CurveEditor({super.key, required this.curves, required this.channel, required this.onChanged});

  /// The recipe's curves, edited in place
  final Map<String, List<List<double>>> curves;
  final String channel;
  final VoidCallback onChanged;

  @override
  State<CurveEditor> createState() => _CurveEditorState();
}

class _CurveEditorState extends State<CurveEditor> {
  /// Grab radius in curve units (editor.js uses 0.04 with a mouse; fingers need more)
  static const _reach = 0.06;
  static const _doubleTapTime = Duration(milliseconds: 300);

  int? _pointer;
  int _dragging = -1;
  Offset? _lastTapAt;
  Duration? _lastTapTime;
  Offset? _downAt;
  bool _moved = false;

  List<List<double>> get _points => widget.curves[widget.channel]!;

  List<double> _pos(Offset local, double size) => [clampD(local.dx / size, 0, 1), clampD(1 - local.dy / size, 0, 1)];

  int _nearest(List<double> p) {
    var best = -1;
    var bestDistance = _reach;
    final pts = _points;
    for (var i = 0; i < pts.length; i++) {
      final d = math.sqrt(math.pow(pts[i][0] - p[0], 2) + math.pow(pts[i][1] - p[1], 2));
      if (d < bestDistance) {
        best = i;
        bestDistance = d;
      }
    }
    return best;
  }

  void _down(PointerDownEvent event, double size) {
    if (_pointer != null) {
      return;
    }
    _pointer = event.pointer;
    _downAt = event.localPosition;
    _moved = false;
    final p = _pos(event.localPosition, size);
    final lastAt = _lastTapAt;
    final lastTime = _lastTapTime;
    if (lastAt != null &&
        lastTime != null &&
        event.timeStamp - lastTime < _doubleTapTime &&
        (lastAt - event.localPosition).distance < _reach * size) {
      // Double-tap: remove the point under the finger
      _lastTapAt = null;
      _dragging = -1;
      final i = _nearest(p);
      if (i >= 0) {
        setState(() => _points.removeAt(i));
        widget.onChanged();
      }
      return;
    }
    final pts = _points;
    _dragging = _nearest(p);
    if (_dragging < 0 && pts.length < maxCurvePoints) {
      pts.add(p);
      pts.sort((a, b) => a[0].compareTo(b[0]));
      _dragging = pts.indexWhere((q) => identical(q, p));
    }
    setState(() {});
    widget.onChanged();
  }

  void _move(PointerMoveEvent event, double size) {
    if (event.pointer != _pointer) {
      return;
    }
    final start = _downAt;
    if (start != null && (event.localPosition - start).distance > kTouchSlop / 2) {
      _moved = true;
    }
    if (_dragging < 0) {
      return;
    }
    final pts = _points;
    final p = _pos(event.localPosition, size);
    final lo = _dragging > 0 ? pts[_dragging - 1][0] + 0.01 : 0.0;
    final hi = _dragging < pts.length - 1 ? pts[_dragging + 1][0] - 0.01 : 1.0;
    pts[_dragging] = [math.min(hi, math.max(lo, p[0])), p[1]];
    setState(() {});
    widget.onChanged();
  }

  void _up(PointerEvent event) {
    if (event.pointer != _pointer) {
      return;
    }
    _pointer = null;
    _dragging = -1;
    if (_moved || event is PointerCancelEvent) {
      _lastTapAt = null;
      _lastTapTime = null;
    } else {
      _lastTapAt = event.localPosition;
      _lastTapTime = event.timeStamp;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.maxWidth;
          // Claim the pointers so dragging a point does not scroll the panel
          return RawGestureDetector(
            gestures: {
              EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                EagerGestureRecognizer.new,
                (_) {},
              ),
            },
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) => _down(e, size),
              onPointerMove: (e) => _move(e, size),
              onPointerUp: _up,
              onPointerCancel: _up,
              child: Semantics(
                label: 'Tone curve (${widget.channel})',
                child: ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(10)),
                  child: CustomPaint(
                    size: Size.square(size),
                    painter: _CurvePainter(
                      curves: widget.curves,
                      channel: widget.channel,
                      signature: _signature(widget.curves),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

String _signature(Map<String, List<List<double>>> curves) => [for (final c in curveChannels) curves[c]].toString();

class _CurvePainter extends CustomPainter {
  _CurvePainter({required this.curves, required this.channel, required this.signature});

  final Map<String, List<List<double>>> curves;
  final String channel;

  /// Points as text: the curves are edited in place, so compare by value
  final String signature;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    canvas.drawRect(Offset.zero & size, Paint()..color = EditorColors.curveBackground);
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      canvas.drawLine(Offset(s * i / 4, 0), Offset(s * i / 4, s), grid);
      canvas.drawLine(Offset(0, s * i / 4), Offset(s, s * i / 4), grid);
    }
    canvas.drawLine(
      Offset(0, s),
      Offset(s, 0),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..strokeWidth = 1,
    );
    for (final ch in curveChannels) {
      final points = curves[ch]!;
      if (ch != channel && points.isEmpty) {
        continue;
      }
      final lut = curveLut(points);
      final path = Path();
      for (var k = 0; k <= 1024; k += 4) {
        final x = k / 1024 * s;
        final y = s - lut[k] * s;
        if (k == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ch == channel ? 2 : 1.4
          ..color = curveColours[ch]!.withValues(alpha: ch == channel ? 1 : 0.35),
      );
    }
    final dot = Paint()..color = curveColours[channel]!;
    for (final p in curves[channel]!) {
      canvas.drawCircle(Offset(p[0] * s, s - p[1] * s), 6, dot);
    }
  }

  @override
  bool shouldRepaint(_CurvePainter oldDelegate) => oldDelegate.signature != signature || oldDelegate.channel != channel;
}
