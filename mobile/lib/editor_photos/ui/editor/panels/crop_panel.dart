// Crop tab panel: the aspect ratio presets (renderCropPanel / aspectIcon in editor.js).
import 'package:flutter/material.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_style.dart';

class CropPanel extends StatelessWidget {
  const CropPanel({super.key, required this.aspect, required this.originalRatio, required this.onAspect});

  /// Selected aspect id
  final String aspect;

  /// Width / height of the photo as oriented now ("Original")
  final double originalRatio;
  final ValueChanged<String> onAspect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Aspect Ratio'),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 420 ? 3 : 2;
            final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
            return Wrap(
              spacing: 10,
              runSpacing: 14,
              children: [
                for (final (id, label, ratio) in aspects)
                  SizedBox(
                    width: width,
                    child: _AspectButton(
                      label: label,
                      ratio: id == 'original' ? originalRatio : ratio ?? 1,
                      free: id == 'free',
                      selected: aspect == id,
                      onTap: () => onAspect(id),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _AspectButton extends StatelessWidget {
  const _AspectButton({
    required this.label,
    required this.ratio,
    required this.free,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final double ratio;
  final bool free;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final w = ratio >= 1 ? 18.0 : 18 * ratio;
    final h = ratio >= 1 ? 18 / ratio : 18.0;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        borderRadius: const BorderRadius.all(Radius.circular(26)),
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? EditorColors.accent : EditorColors.panel2,
              ),
              child: CustomPaint(
                size: Size(w + 4, h + 4),
                painter: _AspectIconPainter(
                  color: selected ? EditorColors.accentText : EditorColors.text,
                  dashed: free,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 14, color: EditorColors.text)),
            ),
          ],
        ),
      ),
    );
  }
}

class _AspectIconPainter extends CustomPainter {
  _AspectIconPainter({required this.color, required this.dashed});

  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final rect = (Offset.zero & size).deflate(1);
    if (!dashed) {
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)), paint);
      return;
    }
    const dash = 3.0;
    void dashedLine(Offset a, Offset b) {
      final length = (b - a).distance;
      final dir = (b - a) / length;
      for (var t = 0.0; t < length; t += dash * 2) {
        final end = t + dash > length ? length : t + dash;
        canvas.drawLine(a + dir * t, a + dir * end, paint);
      }
    }

    dashedLine(rect.topLeft, rect.topRight);
    dashedLine(rect.topRight, rect.bottomRight);
    dashedLine(rect.bottomRight, rect.bottomLeft);
    dashedLine(rect.bottomLeft, rect.topLeft);
  }

  @override
  bool shouldRepaint(_AspectIconPainter oldDelegate) => oldDelegate.color != color || oldDelegate.dashed != dashed;
}
