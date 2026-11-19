// The save/replace/show/discard flow against a fake Immich (port of test/edits.test.js
// of the web app). Rendering runs through the real GPU pipeline.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:immich_mobile/editor_photos/data/edits_service.dart';
import 'package:immich_mobile/editor_photos/data/immich_api.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/render/gpu_pipeline.dart';

/// Just enough of Immich's API: assets, metadata, stacks, uploads, copy and trash
class FakeImmich {
  final assets = <String, Map<String, Object?>>{};
  final metadata = <String, Map<String, Object?>>{};
  final stacks = <String, ({String primary, List<String> members})>{};
  final uploads = <String, Uint8List>{};
  final copies = <Map<String, Object?>>[];
  final requests = <String>[];
  late final Uint8List jpeg;
  var _next = 0;

  FakeImmich() {
    final image = img.Image(width: 64, height: 48);
    for (var y = 0; y < 48; y++) {
      for (var x = 0; x < 64; x++) {
        image.setPixelRgb(x, y, x * 4, y * 5, 128);
      }
    }
    jpeg = img.encodeJpg(image, quality: 95);
  }

  String addPhoto() {
    final id = _uuid();
    assets[id] = {
      'id': id,
      'type': 'IMAGE',
      'originalFileName': 'IMG_$_next.HEIC',
      'fileCreatedAt': '2026-05-01T12:00:00.000Z',
      'fileModifiedAt': '2026-05-01T12:00:00.000Z',
      'localDateTime': '2026-05-01T14:00:00.000Z',
      'width': 64,
      'height': 48,
      'exifInfo': {'make': 'Google', 'model': 'Pixel 9', 'latitude': 53.55, 'longitude': 9.99},
      'isTrashed': false,
    };
    return id;
  }

  String _uuid() => '00000000-0000-4000-8000-${(_next++).toString().padLeft(12, '0')}';

  String? stackOf(String assetId) => stacks.entries.where((e) => e.value.members.contains(assetId)).firstOrNull?.key;

  Map<String, Object?> _asset(String id) {
    final a = Map<String, Object?>.of(assets[id]!);
    final s = stackOf(id);
    if (s != null) {
      a['stack'] = {'id': s, 'primaryAssetId': stacks[s]!.primary, 'assetCount': stacks[s]!.members.length};
    }
    return a;
  }

  http.Response _ok(Object? body, [int status = 200]) =>
      http.Response(body == null ? '' : jsonEncode(body), status, headers: {'content-type': 'application/json'});

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path.replaceFirst('/api', '');
    final method = request.method;
    requests.add('$method $path');
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    Object? body() => request.body.isEmpty ? null : jsonDecode(request.body);

    if (parts.first == 'assets') {
      if (parts.length == 1 && method == 'POST') {
        return _upload(request);
      }
      if (parts.length == 1 && method == 'DELETE') {
        for (final id in ((body()! as Map)['ids'] as List).cast<String>()) {
          assets[id]!['isTrashed'] = true;
        }
        return _ok(null, 204);
      }
      if (parts[1] == 'copy') {
        copies.add((body()! as Map).cast<String, Object?>());
        return _ok(null, 204);
      }
      final id = parts[1];
      if (!assets.containsKey(id)) {
        return _ok({'message': 'not found'}, 404);
      }
      if (parts.length == 2 && method == 'GET') {
        return _ok(_asset(id));
      }
      if (parts.length == 2 && method == 'PUT') {
        assets[id]!.addAll((body()! as Map).cast<String, Object?>());
        return _ok(_asset(id));
      }
      if (parts[2] == 'metadata') {
        final meta = metadata.putIfAbsent(id, () => {});
        if (method == 'GET') {
          return _ok([
            for (final e in meta.entries) {'key': e.key, 'value': e.value, 'updatedAt': '2026-01-01T00:00:00Z'},
          ]);
        }
        if (method == 'PUT') {
          for (final item in ((body()! as Map)['items'] as List).cast<Map>()) {
            meta[item['key'] as String] = item['value'];
          }
          return _ok([]);
        }
        if (method == 'DELETE') {
          return meta.remove(parts[3]) == null ? _ok(null, 404) : _ok(null, 204);
        }
      }
      if (parts[2] == 'original' || parts[2] == 'thumbnail') {
        return http.Response.bytes(jpeg, 200, headers: {'content-type': 'image/jpeg'});
      }
    }
    if (parts.first == 'stacks') {
      if (parts.length == 1 && method == 'POST') {
        final ids = ((body()! as Map)['assetIds'] as List).cast<String>();
        // Stacks of listed assets merge into one; the first asset becomes the primary
        final members = <String>{};
        for (final id in ids) {
          final existing = stackOf(id);
          if (existing != null) {
            members.addAll(stacks.remove(existing)!.members);
          }
          members.add(id);
        }
        final id = _uuid();
        stacks[id] = (primary: ids.first, members: members.toList());
        return _ok({'id': id, 'primaryAssetId': ids.first, 'assets': []}, 201);
      }
      final id = parts[1];
      final stack = stacks[id];
      if (stack == null) {
        return _ok(null, 404);
      }
      if (parts.length == 2 && method == 'GET') {
        return _ok({
          'id': id,
          'primaryAssetId': stack.primary,
          'assets': [for (final m in stack.members) _asset(m)..remove('stack')],
        });
      }
      if (parts.length == 2 && method == 'PUT') {
        stacks[id] = (primary: (body()! as Map)['primaryAssetId'] as String, members: stack.members);
        return _ok({'id': id});
      }
      if (parts.length == 2 && method == 'DELETE') {
        stacks.remove(id);
        return _ok(null, 204);
      }
      if (parts.length == 4 && method == 'DELETE') {
        stacks[id] = (primary: stack.primary, members: stack.members.where((m) => m != parts[3]).toList());
        return _ok(null, 204);
      }
    }
    return _ok({'message': 'unhandled $method $path'}, 500);
  }

  http.Response _upload(http.Request request) {
    final bytes = request.bodyBytes;
    final text = latin1.decode(bytes);
    final filenameAt = text.indexOf('name="filename"');
    final fileAt = text.indexOf('name="assetData"');
    expect(filenameAt, greaterThanOrEqualTo(0));
    expect(filenameAt, lessThan(fileAt), reason: 'filename must precede the file part');
    String field(String name) {
      final m = RegExp('name="$name"\r\n\r\n([^\r]*)\r\n').firstMatch(text)!;
      return utf8.decode(latin1.encode(m.group(1)!));
    }

    final id = _uuid();
    final start = text.indexOf('\r\n\r\n', fileAt) + 4;
    final end = text.indexOf('\r\n--', start);
    uploads[id] = Uint8List.fromList(bytes.sublist(start, end));
    assets[id] = {
      'id': id,
      'type': 'IMAGE',
      'originalFileName': field('filename'),
      'fileCreatedAt': field('fileCreatedAt'),
      'isTrashed': false,
    };
    for (final item in (jsonDecode(field('metadata')) as List).cast<Map>()) {
      metadata.putIfAbsent(id, () => {})[item['key'] as String] = item['value'];
    }
    return _ok({'id': id, 'status': 'created'}, 201);
  }
}

void main() {
  final fake = FakeImmich();
  final api = ImmichApi(client: () => MockClient(fake.handle), endpoint: () => 'https://photos.example/api');
  GpuRenderer? renderer;
  final service = EditsService(api: api, renderer: () async => renderer ??= await GpuRenderer.create());
  final recipe = Recipe.fromJson({
    'geometry': {'angle': 2.5},
    'adjust': {'contrast': 0.3, 'pop': 0.2},
  });
  List<Object?> editsOf(String id) => ((fake.metadata[id]?['editor-photos'] as Map?)?['edits'] as List?) ?? const [];

  testWidgets('save, versions, show, discard and replace', (tester) async {
    await tester.runAsync(() async {
      final photo = fake.addPhoto();

      // An unedited photo starts from an empty recipe
      final empty = await service.context(photo);
      expect(empty.original.id, photo);
      expect(empty.edits, isEmpty);
      expect(empty.recipe.isIdentity, isTrue);

      // Saving renders, uploads, stacks the new version on top and records the edit
      final first = await service.save(photo, recipe);
      final rendered = fake.assets[first.renderedAssetId]!;
      expect(rendered['originalFileName'], matches(RegExp(r'^IMG_\d+-edit-1\.jpg$')));
      expect(rendered['dateTimeOriginal'], '2026-05-01T14:00:00+02:00');
      expect(rendered['latitude'], 53.55);
      final jpeg = img.decodeJpg(fake.uploads[first.renderedAssetId]!)!;
      expect(jpeg.width, first.width);
      expect(jpeg.exif.exifIfd['DateTimeOriginal']?.toString(), '2026:05:01 14:00:00');
      expect((fake.metadata[first.renderedAssetId]!['editor-photos-render']! as Map)['originalId'], photo);
      final stackId = fake.stackOf(photo)!;
      expect(fake.stacks[stackId]!.primary, first.renderedAssetId);
      expect(editsOf(photo), hasLength(1));
      expect(((editsOf(photo).first! as Map)['recipe']! as Map)['geometry'], containsPair('angle', 2.5));
      expect(
        fake.copies.any(
          (c) =>
              c['sourceId'] == photo &&
              c['targetId'] == first.renderedAssetId &&
              c['albums'] == true &&
              c['stack'] == false,
        ),
        isTrue,
      );

      // Opening a rendered version edits its original, starting from the shown recipe
      final viaVersion = await service.context(first.renderedAssetId);
      expect(viaVersion.original.id, photo);
      expect(viaVersion.shownEditId, first.editId);
      expect(viaVersion.recipe.adjust['contrast'], 0.3);

      // A second save merges into the same stack and becomes the shown version
      final second = await service.save(photo, recipe.copy()..filterId = 'mono', source: 'suggestion');
      final merged = fake.stackOf(photo)!;
      expect(fake.stacks[merged]!.primary, second.renderedAssetId);
      expect(fake.stacks[merged]!.members, hasLength(3));
      expect((editsOf(photo)[1]! as Map)['source'], 'suggestion');
      expect(fake.assets[second.renderedAssetId]!['originalFileName'], matches(RegExp(r'^IMG_\d+-edit-2\.jpg$')));

      // Switching the shown version moves the stack primary
      await service.show(photo, first.editId);
      expect(fake.stacks[fake.stackOf(photo)]!.primary, first.renderedAssetId);
      await service.show(photo, null);
      expect(fake.stacks[fake.stackOf(photo)]!.primary, photo);

      // Discarding the shown version hands over to the newest remaining one
      await service.show(photo, first.editId);
      await service.discard(photo, first.editId);
      expect(fake.assets[first.renderedAssetId]!['isTrashed'], isTrue);
      expect(fake.stacks[fake.stackOf(photo)]!.primary, second.renderedAssetId);
      expect(fake.stacks[fake.stackOf(photo)]!.members, isNot(contains(first.renderedAssetId)));
      expect(editsOf(photo), hasLength(1));

      // Discarding all edits dissolves the stack and removes the metadata
      await service.discard(photo, 'all');
      expect(fake.stackOf(photo), isNull);
      expect(fake.assets[second.renderedAssetId]!['isTrashed'], isTrue);
      expect(fake.metadata[photo]!.containsKey('editor-photos'), isFalse);
      expect(fake.assets[photo]!['isTrashed'], isFalse, reason: 'the original is never trashed');

      // Empty edits and unknown versions are refused
      await expectLater(service.save(photo, Recipe.defaults()), throwsA(isA<EditsException>()));
      await expectLater(service.discard(photo, 'nope'), throwsA(isA<EditsException>()));

      // Apply & replace: the edit takes the original's place, the original goes to the trash
      final other = fake.addPhoto();
      final replaced = await service.save(other, recipe, replace: true);
      expect(replaced.replaced, isTrue);
      expect(fake.assets[other]!['isTrashed'], isTrue);
      expect(fake.stackOf(replaced.renderedAssetId), isNull, reason: 'no stack left with only the new photo');
      final history = editsOf(replaced.renderedAssetId);
      expect((history.last! as Map)['replacedOriginalId'], other);
      final ctx = await service.context(replaced.renderedAssetId);
      expect(ctx.original.id, replaced.renderedAssetId, reason: 'the new photo is its own original now');
    });
  });
}
