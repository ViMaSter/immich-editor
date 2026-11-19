// The crop tab's stage: the tone-only preview drawn rotated and scaled behind an
// axis-aligned frame, with dimming, grid and corner handles (drawCrop in editor.js), and
// the pointer handling for panning and corner drags.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:immich_mobile/editor_photos/ui/editor/crop_controller.dart';

const _deg = math.pi / 180;

class CropStage extends StatefulWidget {
  const CropStage({super.key, required this.controller, required this.image, required this.padding});

  final CropController controller;

  /// Tone-only render of the whole, unrotated photo (null while it renders)
  final ui.Image? image;

  /// Space between the stage edge and the area the frame may use
  final double padding;

  @override
  State<CropStage> createState() => _CropStageState();
}

class _CropStageState extends State<CropStage> with TickerProviderStateMixin {
  static const _refitDelay = Duration(milliseconds: 800);
  static const _refitDuration = Duration(milliseconds: 260);

  late final AnimationController _fit = AnimationController(vsync: this, duration: _refitDuration)
    ..addListener(_onFitTick);
  late final Ticker _edge = createTicker(_onEdgeTick);
  FitAnimation? _animation;
  Timer? _refitTimer;
  int? _pointer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
  }

  @override
  void didUpdateWidget(CropStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
      _stopAll();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _refitTimer?.cancel();
    _fit.dispose();
    _edge.dispose();
    super.dispose();
  }

  void _stopAll() {
    _refitTimer?.cancel();
    _fit.stop();
    _animation = null;
    if (_edge.isActive) {
      _edge.stop();
    }
    _pointer = null;
  }

  void _onController() {
    final animation = widget.controller.takeAnimation();
    if (animation != null) {
      _animation = animation;
      unawaited(_fit.forward(from: 0));
    }
  }

  void _onFitTick() {
    final animation = _animation;
    if (animation != null) {
      // 1 - (1 - t)³ like editor.js
      widget.controller.applyAnimation(animation, Curves.easeOutCubic.transform(_fit.value));
    }
  }

  void _finishAnimation() {
    final animation = _animation;
    if (_fit.isAnimating && animation != null) {
      _fit.stop();
      widget.controller.applyAnimation(animation, 1);
    }
    _animation = null;
  }

  void _onEdgeTick(Duration _) {
    final c = widget.controller;
    if (c.drag == null || !c.cornerDragUpdate()) {
      _edge.stop();
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_pointer != null) {
      return;
    }
    _refitTimer?.cancel();
    _finishAnimation();
    if (widget.controller.startDrag(event.localPosition.dx, event.localPosition.dy)) {
      _pointer = event.pointer;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) {
      return;
    }
    final grow = widget.controller.moveDrag(event.localPosition.dx, event.localPosition.dy);
    if (grow && !_edge.isActive) {
      unawaited(_edge.start());
    }
  }

  void _onPointerEnd(PointerEvent event) {
    if (event.pointer != _pointer) {
      return;
    }
    _pointer = null;
    if (_edge.isActive) {
      _edge.stop();
    }
    if (widget.controller.endDrag()) {
      _refitTimer?.cancel();
      _refitTimer = Timer(_refitDelay, () {
        if (mounted && widget.controller.drag == null) {
          widget.controller.fit(animate: true);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final pad = widget.padding;
        widget.controller.layout(
          ScreenRect(
            pad,
            pad,
            math.max(10, constraints.maxWidth - 2 * pad),
            math.max(10, constraints.maxHeight - 2 * pad),
          ),
        );
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerEnd,
          onPointerCancel: _onPointerEnd,
          child: CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: CropPainter(widget.controller, widget.image),
          ),
        );
      },
    );
  }
}

class CropPainter extends CustomPainter {
  CropPainter(this.controller, this.image) : super(repaint: controller);

  final CropController controller;
  final ui.Image? image;

  @override
  void paint(Canvas canvas, Size size) {
    final c = controller;
    final a = c.anchor;
    final f = c.frame;
    if (a == null || f == null) {
      return;
    }
    final g = c.geometry;
    final img = image;
    if (img != null) {
      canvas.save();
      canvas.clipRect(Offset.zero & size);
      canvas.translate(a.sx, a.sy);
      canvas.rotate(g.angle * _deg);
      canvas.scale(a.scale);
      canvas.translate(-a.ix, -a.iy);
      // drawOriented: the preview is unrotated, 90° steps are clockwise
      final pw = c.sourceWidth;
      final ph = c.sourceHeight;
      switch (g.rotate90) {
        case 1:
          canvas.translate(ph, 0);
          canvas.rotate(math.pi / 2);
        case 2:
          canvas.translate(pw, ph);
          canvas.rotate(math.pi);
        case 3:
          canvas.translate(0, pw);
          canvas.rotate(-math.pi / 2);
      }
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromLTWH(0, 0, pw, ph),
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
    }
    final frameRect = Rect.fromLTWH(f.x, f.y, f.w, f.h);
    // Dim everything outside the frame
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(frameRect),
      Paint()..color = const Color(0x9E000000),
    );
    // Grid: thirds normally, a fine grid while straightening
    final n = c.fineGrid ? 9 : 3;
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: c.fineGrid ? 0.45 : 0.35)
      ..strokeWidth = 1;
    for (var i = 1; i < n; i++) {
      final x = f.x + f.w * i / n;
      final y = f.y + f.h * i / n;
      canvas.drawLine(Offset(x, f.y), Offset(x, f.bottom), grid);
      canvas.drawLine(Offset(f.x, y), Offset(f.right, y), grid);
    }
    canvas.drawRect(
      frameRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.9),
    );
    // Corner handles
    final handle = Paint()..color = Colors.white;
    for (final (x, y) in f.corners) {
      canvas.drawCircle(Offset(x, y), 7, handle);
    }
  }

  @override
  bool shouldRepaint(CropPainter oldDelegate) => oldDelegate.controller != controller || oldDelegate.image != image;
}
