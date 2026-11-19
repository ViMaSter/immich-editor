import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/editor_photos/data/editor_server.dart';
import 'package:immich_mobile/editor_photos/data/edits_service.dart';
import 'package:immich_mobile/editor_photos/data/immich_api.dart';
import 'package:immich_mobile/editor_photos/editor_session.dart';
import 'package:immich_mobile/editor_photos/model/auto.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/render/cpu_image.dart';
import 'package:immich_mobile/editor_photos/render/gpu_pipeline.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_page.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_slider.dart';

/// A session without network or GPU: renders hand out copies of one test image
class _FakeSession extends EditorSession {
  _FakeSession(this.image, {super.server, super.suggestion})
    : super(
        assetId: 'asset-1',
        // Thumbnails fail (404): the versions dialog shows placeholders
        api: ImmichApi(
          endpoint: () => 'http://localhost',
          client: () => MockClient((_) async => http.Response('not found', 404)),
        ),
      );

  final ui.Image image;
  final renders = <(Recipe, bool, double)>[];
  final saved = <(Recipe, bool)>[];
  bool disposed = false;

  @override
  Future<ui.Image> render(Recipe recipe, {bool toneOnly = false, double maxPixels = double.infinity}) async {
    renders.add((recipe, toneOnly, maxPixels));
    return image.clone();
  }

  @override
  Future<SaveResult> save(Recipe recipe, {bool replace = false, StepReporter? onStep}) async {
    saved.add((recipe, replace));
    onStep?.call('Rendering', 0.5);
    return SaveResult(
      editId: 'edit-1',
      renderedAssetId: 'asset-2',
      width: 160,
      height: 100,
      from: 'original',
      replaced: replace,
    );
  }

  ToolMasks? fakeMasks;
  final actions = <String>[];

  EditContext _with({String? shown, List<EditVersion>? edits}) {
    final c = context!;
    return EditContext(
      original: c.original,
      editable: c.editable,
      stackId: c.stackId,
      shownEditId: shown,
      recipe: c.recipe,
      edits: edits ?? c.edits,
    );
  }

  @override
  Future<void> show(String? editId) async {
    actions.add('show $editId');
    context = _with(shown: editId);
  }

  @override
  Future<void> discard(String editId) async {
    actions.add('discard $editId');
    final left = editId == 'all' ? <EditVersion>[] : context!.edits.where((e) => e.id != editId).toList();
    context = _with(shown: null, edits: left);
  }

  @override
  Future<ToolMasks?> masks() async => loadedMasks = fakeMasks;

  @override
  void dispose() => disposed = true;
}

const _stats = PhotoStats(
  p01: 0.08,
  p05: 0.12,
  p25: 0.2,
  p50: 0.38,
  p75: 0.6,
  p95: 0.85,
  p99: 0.9,
  clippedHigh: 0.02,
  clippedLow: 0,
  saturation: 0.15,
  castRG: 0.01,
  castYB: 0.03,
);

Future<_FakeSession> _session(WidgetTester tester, {EditorServer? server, Suggestion? suggestion}) async {
  final image = (await tester.runAsync(() => createTestImage(width: 160, height: 100)))!;
  return _FakeSession(image, server: server, suggestion: suggestion)
    ..context = EditContext(
      original: const OriginalInfo(id: 'asset-1', fileName: 'photo.jpg', type: 'IMAGE'),
      editable: true,
      stackId: null,
      shownEditId: null,
      recipe: Recipe.defaults(),
      edits: const [],
    )
    ..preview = GpuImageSource(image, owned: false)
    ..stats = _stats;
}

/// Opens the editor from a home screen; returns the route's result holder
Future<List<Object?>> _open(WidgetTester tester, EditorSession session) async {
  final results = <Object?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final result = await Navigator.of(
                context,
              ).push(MaterialPageRoute<Object?>(builder: (_) => EditorPhotosPage(session: session)));
              results.add(result);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    WidgetController.hitTestWarningShouldBeFatal = true;
  });

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('edits, asks before discarding, crops and saves', (tester) async {
    await phone(tester);
    final session = await _session(tester);
    final results = await _open(tester, session);

    // Starts in Adjust (no suggestions); the first render is the full preview
    expect(find.text('Brightness'), findsOneWidget);
    expect(session.renders, isNotEmpty);
    expect(session.renders.first.$2, isFalse);
    FilledButton save() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
    expect(save().onPressed, isNull);

    // Tap the right half of the Brightness slider
    final slider = find.byType(EditorSlider).at(1);
    await tester.tapAt(tester.getCenter(slider) + const Offset(60, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(save().onPressed, isNotNull);
    expect(find.textContaining('+'), findsWidgets);

    // Closing asks first
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsNothing);

    // Suggestions tab offers the automatic edits
    await tester.tap(find.text('Suggestions'));
    await tester.pumpAndSettle();
    expect(find.text('Enhance'), findsOneWidget);
    await tester.tap(find.text('Warm'));
    await tester.pumpAndSettle();

    // Crop: tone-only renders, ruler, aspect presets
    await tester.tap(find.text('Crop'));
    await tester.pumpAndSettle();
    expect(session.renders.last.$2, isTrue);
    expect(find.text('0°'), findsOneWidget);
    await tester.ensureVisible(find.text('Square'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Square'));
    await tester.pumpAndSettle();

    // Filters render one thumbnail per filter
    final before = session.renders.length;
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    expect(session.renders.where((r) => r.$3 < double.infinity).length, greaterThan(10));
    expect(session.renders.length, greaterThan(before));
    await tester.tap(find.text('Vivid'));
    await tester.pumpAndSettle();
    expect(find.text('Vivid strength'), findsOneWidget);

    // Advanced opens with Light expanded
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('Exposure'), findsOneWidget);
    await tester.ensureVisible(find.text('Curves'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Curves'));
    await tester.pumpAndSettle();
    expect(find.text('Reset curve'), findsOneWidget);

    // Save pops with the result
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(session.saved, hasLength(1));
    final recipe = session.saved.single.$1;
    expect(recipe.adjust['brightness'], greaterThan(0));
    expect(recipe.adjust['warmth'], greaterThan(0));
    expect(recipe.filterId, 'vivid');
    expect(recipe.geometry.aspect, 'square');
    expect(recipe.geometry.crop, isNotNull);
    expect(results.single, isA<SaveResult>());
    expect(session.disposed, isTrue);

    session.image.dispose();
  });

  testWidgets('wide layout puts the panel at the side; back closes without changes', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = await _session(tester);
    final results = await _open(tester, session);
    expect(find.text('Save & replace original'), findsOneWidget);
    expect(find.text('Versions'), findsNothing);
    final route = ModalRoute.of(tester.element(find.byType(EditorPhotosPage)))!;
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(route.isActive, isFalse);
    expect(results, [null]);
    expect(session.saved, isEmpty);
    expect(session.disposed, isTrue);
    session.image.dispose();
  });

  testWidgets('small phone: suggestion, tools with masks, blur focus by tapping the photo', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const suggestion = Suggestion(
      id: 's1',
      assetId: 'asset-1',
      name: 'Deep blue sky',
      why: 'The sky looks washed out',
      summary: 'Saturation +0.40',
      recipe: {
        'adjust': {'saturation': 0.4},
      },
    );
    final session = await _session(tester, server: EditorServer(Uri.parse('http://localhost')), suggestion: suggestion);
    session.fakeMasks = ToolMasks(
      const MaskInfo(
        width: 16,
        height: 10,
        faces: [FaceBox(x: 0.4, y: 0.3, w: 0.2, h: 0.3)],
        kinds: ['sky', 'subject', 'depth'],
        coverage: {'sky': 0.3, 'subject': 0.2},
      ),
      GpuMasks(
        session.image,
        EditorMasks(width: 16, height: 10, sky: Float32List(160), subject: Float32List(160), depth: Float32List(160)),
      ),
    );
    await _open(tester, session);

    // Opened from a suggestion: starts in Suggestions and counts as unsaved
    expect(find.text('Suggested for this photo'), findsOneWidget);
    expect(find.text('Why: The sky looks washed out'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed, isNotNull);

    await tester.tap(find.text('Tools'));
    await tester.pumpAndSettle();
    expect(find.text('Sky'), findsOneWidget);
    expect(find.text('Color focus'), findsWidgets);
    expect(find.text('Portrait light'), findsOneWidget);
    expect(find.text('Blur'), findsOneWidget);
    expect(find.textContaining('Not available'), findsNothing);

    await tester.tap(find.text('Ember'));
    await tester.pumpAndSettle();
    final stage = find.byType(EditorPhotosPage);
    // Tap the middle of the photo: sets the blur focus and a default strength
    await tester.tapAt(tester.getCenter(stage) - const Offset(0, 150));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(session.disposed, isTrue);

    final recipe = session.renders.last.$1;
    expect(recipe.tools.sky.palette, 'ember');
    expect(recipe.tools.sky.strength, 0.7);
    expect(recipe.tools.blur.strength, 0.6);
    expect(recipe.tools.blur.focusX, closeTo(0.5, 0.05));
    session.image.dispose();
  });

  testWidgets('versions: show and discard', (tester) async {
    await phone(tester);
    final session = await _session(tester);
    session.context = EditContext(
      original: const OriginalInfo(id: 'asset-1', fileName: 'photo.jpg', type: 'IMAGE'),
      editable: true,
      stackId: 'stack-1',
      shownEditId: null,
      recipe: Recipe.defaults(),
      edits: const [
        EditVersion(id: 'e1', createdAt: null, source: 'suggestion', renderedAssetId: 'r1', summary: 'Pop +0.20'),
        EditVersion(id: 'e2', createdAt: null, source: 'manual', renderedAssetId: 'r2', summary: 'Crop'),
      ],
    );
    await _open(tester, session);
    await tester.tap(find.byTooltip('Versions'));
    await tester.pumpAndSettle();
    expect(find.text('Original · shown'), findsOneWidget);
    expect(find.text('Edit 1 · suggestion'), findsOneWidget);
    expect(find.text('Edit 2'), findsOneWidget);
    expect(find.text('Pop +0.20'), findsOneWidget);

    await tester.tap(find.text('Show this').first);
    await tester.pumpAndSettle();
    expect(session.actions, ['show e1']);
    expect(find.text('Edit 1 · shown · suggestion'), findsOneWidget);

    await tester.tap(find.text('Discard all edits'));
    await tester.pumpAndSettle();
    expect(session.actions.last, 'discard all');
    expect(find.text('Versions'), findsNothing, reason: 'closes when no edits are left');
    expect(find.byTooltip('Versions'), findsNothing);
    session.image.dispose();
  });
}
