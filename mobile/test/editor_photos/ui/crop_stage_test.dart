import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/editor_photos/model/geometry.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/ui/editor/crop_controller.dart';
import 'package:immich_mobile/editor_photos/ui/editor/crop_stage.dart';
import 'package:immich_mobile/editor_photos/ui/editor/rotation_ruler.dart';

void main() {
  Future<CropController> pumpStage(WidgetTester tester, Geometry geometry) async {
    final c = CropController(geometry: geometry, sourceWidth: 1600, sourceHeight: 1000);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 400, height: 400, child: CropStage(controller: c, image: null, padding: 20)),
        ),
      ),
    );
    return c;
  }

  testWidgets('holding a corner at the stage edge keeps growing, then the frame re-fits', (tester) async {
    final g = Geometry(angle: 5, crop: const CropRect(cx: 0.5, cy: 0.5, w: 0.3, h: 0.3));
    final c = await pumpStage(tester, g);
    final f = c.frame!;
    final gesture = await tester.startGesture(Offset(f.right, f.bottom));
    expect(c.drag?.hit, 3);
    // Past the box edge (box = 20..380)
    await gesture.moveTo(const Offset(392, 392));
    final w1 = c.rect.w;
    final scale1 = c.anchor!.scale;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(c.rect.w, greaterThan(w1), reason: 'keeps growing while the finger rests at the edge');
    expect(c.anchor!.scale, lessThan(scale1), reason: 'zooms out');
    expect(fitsInside(c.rect, 1600, 1000, 5), isTrue);
    await gesture.up();
    expect(c.needsRefit, isTrue);
    expect(g.crop, isNotNull);

    // Re-fits 0.8 s later, animated over 260 ms
    await tester.pump(const Duration(milliseconds: 700));
    expect(c.needsRefit, isTrue);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 100));
    final mid = c.frame!;
    await tester.pumpAndSettle();
    final (target, anchor) = c.fitTarget();
    expect(c.frame, target);
    expect(c.anchor!.scale, closeTo(anchor.scale, 1e-9));
    expect(mid == target, isFalse, reason: 'animated, not jumped');
  });

  testWidgets('a pan moves the image without re-fitting', (tester) async {
    final g = Geometry(crop: const CropRect(cx: 0.5, cy: 0.5, w: 0.5, h: 0.5));
    final c = await pumpStage(tester, g);
    final f = c.frame!;
    final cx0 = c.rect.cx;
    final gesture = await tester.startGesture(Offset(f.cx, f.cy));
    await gesture.moveBy(const Offset(-40, 0));
    await gesture.up();
    expect(c.rect.cx, greaterThan(cx0));
    expect(c.frame, f);
    await tester.pump(const Duration(seconds: 2));
    expect(c.frame, f);
  });

  testWidgets('the ruler turns drags into angles', (tester) async {
    final angles = <double>[];
    var ended = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            child: RotationRuler(angle: 0, onChanged: angles.add, onEnd: () => ended++),
          ),
        ),
      ),
    );
    expect(find.text('0°'), findsOneWidget);
    final gesture = await tester.startGesture(tester.getCenter(find.byType(RotationRuler)) + const Offset(40, 10));
    await gesture.moveBy(const Offset(-20, 0));
    await gesture.up();
    expect(angles.last, closeTo(20 / rulerPxPerDegree, 1e-9));
    expect(ended, 1);
    expect(formatAngle(-4.7), '-4.7°');
    expect(formatAngle(12), '12°');
    expect(maxAngle, 45);
  });
}
