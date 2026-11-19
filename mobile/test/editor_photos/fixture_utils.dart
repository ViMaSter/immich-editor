// Loaders for the fixtures written by fixtures/generate.mjs (format documented there).
// Shared by the CPU pipeline tests and the GPU shader tests.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/editor_photos/model/js_compat.dart';
import 'package:immich_mobile/editor_photos/render/cpu_pipeline.dart';

/// Relative to the package root (the working directory of `flutter test`)
const fixturesDir = 'test/editor_photos/fixtures';

Object? readFixtureJson(String path) => jsonDecode(File('$fixturesDir/$path').readAsStringSync());

Uint8List readFixtureBytes(String path) => File('$fixturesDir/$path').readAsBytesSync();

/// Raw little-endian Float32 values
Float32List readFixtureF32(String path) {
  final bytes = readFixtureBytes(path);
  final view = ByteData.sublistView(bytes);
  final out = Float32List(bytes.length ~/ 4);
  for (var i = 0; i < out.length; i++) {
    out[i] = view.getFloat32(i * 4, Endian.little);
  }
  return out;
}

class PipelineCase {
  final String name;
  final Map<String, Object?> recipe;
  final bool masks;
  final double maxPixels;
  final double? sourceWidth;
  final double? sourceHeight;
  final int width;
  final int height;
  final String file;
  final List<FaceBox>? faces;
  final String? rgba8;
  final String? rgb8;

  const PipelineCase({
    required this.name,
    required this.recipe,
    required this.masks,
    required this.maxPixels,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.width,
    required this.height,
    required this.file,
    this.faces,
    this.rgba8,
    this.rgb8,
  });

  factory PipelineCase.fromJson(Map<String, Object?> json) => PipelineCase(
    name: json['name']! as String,
    recipe: json['recipe']! as Map<String, Object?>,
    masks: json['masks']! as bool,
    maxPixels: json['maxPixels'] == null ? double.infinity : toD(json['maxPixels']),
    sourceWidth: json['sourceWidth'] == null ? null : toD(json['sourceWidth']),
    sourceHeight: json['sourceHeight'] == null ? null : toD(json['sourceHeight']),
    width: json['width']! as int,
    height: json['height']! as int,
    file: json['file']! as String,
    faces: (json['faces'] as List?)?.map((f) => FaceBox.fromJson(f as Map<String, Object?>)).toList(),
    rgba8: json['rgba8'] as String?,
    rgb8: json['rgb8'] as String?,
  );

  /// The JavaScript render() output (Float32, clamped, before 8-bit conversion)
  RgbImage expected() => RgbImage(width, height, readFixtureF32('pipeline/$file'));
}

class PipelineFixtures {
  final RgbImage source;
  final EditorMasks masks;
  final List<PipelineCase> cases;

  const PipelineFixtures(this.source, this.masks, this.cases);

  factory PipelineFixtures.load() {
    final json = readFixtureJson('pipeline/cases.json')! as Map<String, Object?>;
    final src = json['source']! as Map<String, Object?>;
    final m = json['masks']! as Map<String, Object?>;
    return PipelineFixtures(
      RgbImage(src['width']! as int, src['height']! as int, readFixtureF32('pipeline/${src['file']}')),
      EditorMasks(
        width: m['width']! as int,
        height: m['height']! as int,
        sky: readFixtureF32('pipeline/${m['sky']}'),
        subject: readFixtureF32('pipeline/${m['subject']}'),
        depth: readFixtureF32('pipeline/${m['depth']}'),
        faces: [for (final f in m['faces']! as List) FaceBox.fromJson(f as Map<String, Object?>)],
      ),
      [for (final c in json['cases']! as List) PipelineCase.fromJson(c as Map<String, Object?>)],
    );
  }
}

/// Max and mean absolute difference, and how many values differ at all
({double max, double mean, int differing}) diffStats(Float32List a, Float32List b) {
  if (a.length != b.length) {
    throw ArgumentError('length ${a.length} != ${b.length}');
  }
  var max = 0.0;
  var sum = 0.0;
  var differing = 0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d.isNaN) {
      return (max: double.nan, mean: double.nan, differing: a.length);
    }
    if (d != 0) {
      differing++;
    }
    max = math.max(max, d);
    sum += d;
  }
  return (max: max, mean: a.isEmpty ? 0 : sum / a.length, differing: differing);
}
