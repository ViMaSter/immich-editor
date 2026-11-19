// The stage outside the crop tab: the rendered preview fitted with padding (draw() in
// editor.js), optionally reporting taps in output-image coordinates (blur focus).
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Where [imageSize] lands when fitted (contain) into [size] minus [padding]
Rect fitImageRect(Size size, Size imageSize, double padding) {
  final boxW = math.max(10.0, size.width - 2 * padding);
  final boxH = math.max(10.0, size.height - 2 * padding);
  final s = math.min(boxW / imageSize.width, boxH / imageSize.height);
  final w = imageSize.width * s;
  final h = imageSize.height * s;
  return Rect.fromLTWH(padding + (boxW - w) / 2, padding + (boxH - h) / 2, w, h);
}

class PreviewStage extends StatelessWidget {
  const PreviewStage({super.key, required this.image, required this.padding, this.onTapImage, this.focus});

  final ui.Image? image;
  final double padding;

  /// Tap on the photo at (x, y), both 0..1 of the rendered image
  final void Function(double x, double y)? onTapImage;

  /// A focus marker at (x, y) in 0..1 of the image (blur)
  final Offset? focus;

  @override
  Widget build(BuildContext context) {
    final img = image;
    if (img == null) {
      return const Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final rect = fitImageRect(size, Size(img.width.toDouble(), img.height.toDouble()), padding);
        final onTap = onTapImage;
        final paint = CustomPaint(size: size, painter: _PreviewPainter(img, rect, focus));
        if (onTap == null) {
          return paint;
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final x = (details.localPosition.dx - rect.left) / rect.width;
            final y = (details.localPosition.dy - rect.top) / rect.height;
            if (x >= 0 && x <= 1 && y >= 0 && y <= 1) {
              onTap(x, y);
            }
          },
          child: paint,
        );
      },
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.image, this.rect, this.focus);

  final ui.Image image;
  final Rect rect;
  final Offset? focus;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      rect,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final f = focus;
    if (f != null) {
      final c = Offset(rect.left + f.dx * rect.width, rect.top + f.dy * rect.height);
      canvas.drawCircle(
        c,
        14,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = const Color(0x66000000),
      );
      canvas.drawCircle(
        c,
        14,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(_PreviewPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.rect != rect || oldDelegate.focus != focus;
}
