// Loading photos for editing and encoding the result.
//
// Preview: Immich's "preview" derivative (≈1440 px), scaled to ≤ 1.6 MP like the web
// editor's worker. Export: the original file when Flutter can decode it, else Immich's
// full-size or preview derivative (HEIC/RAW the device cannot read). Originals larger
// than the GPU can hold in one texture are decoded on the CPU and uploaded per tile.
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:immich_mobile/editor_photos/data/immich_api.dart';
import 'package:immich_mobile/editor_photos/render/gpu_pipeline.dart';
import 'package:logging/logging.dart';

final _log = Logger('EditorPhotosSources');

const previewPixels = 1.6e6;

/// Decoded source plus where it came from ('original', 'fullsize' or 'preview')
class LoadedSource {
  final GpuSource source;
  final String from;

  const LoadedSource(this.source, this.from);
}

Future<GpuImageSource> loadPreviewSource(ImmichApi api, String assetId) async {
  final bytes = await api.thumbnail(assetId, 'preview');
  return decodeSource(bytes, maxPixels: previewPixels);
}

/// Full-resolution source for saving
Future<LoadedSource> loadFullSource(ImmichApi api, String assetId) async {
  try {
    final bytes = await api.original(assetId);
    return LoadedSource(await decodeFull(bytes), 'original');
  } catch (error) {
    _log.warning('Rendering $assetId from a derivative: $error');
  }
  for (final size in const ['fullsize', 'preview']) {
    try {
      final bytes = await api.thumbnail(assetId, size);
      return LoadedSource(await decodeFull(bytes), size == 'fullsize' ? 'fullsize' : 'preview');
    } catch (error) {
      _log.warning('No usable $size derivative for $assetId: $error');
    }
  }
  throw StateError('No usable source image');
}

/// Decodes at full resolution; falls back to a CPU decode with per-tile uploads when the
/// GPU decoder hands back a smaller image (texture size limit)
Future<GpuSource> decodeFull(Uint8List bytes) async {
  final source = await decodeSource(bytes);
  if (source.image.width >= source.width.round() && source.image.height >= source.height.round()) {
    return source;
  }
  _log.info('Decoded ${source.image.width}×${source.image.height} of ${source.width}×${source.height}: tiling');
  source.dispose();
  return CpuTiledSource.decode(bytes);
}

/// A source decoded on the CPU; tiles are uploaded on demand
class CpuTiledSource implements GpuSource {
  final Uint8List rgba;
  final int w;
  final int h;

  CpuTiledSource(this.rgba, this.w, this.h);

  static Future<CpuTiledSource> decode(Uint8List bytes) async {
    final (rgba, w, h) = await Isolate.run(() {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        throw StateError('Unsupported image');
      }
      final oriented = img.bakeOrientation(decoded);
      final rgbaImage = oriented.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
      return (rgbaImage.toUint8List(), rgbaImage.width, rgbaImage.height);
    });
    return CpuTiledSource(rgba, w, h);
  }

  @override
  double get width => w.toDouble();

  @override
  double get height => h.toDouble();

  @override
  Future<GpuSourceRegion> region(ui.Rect footprint) async {
    final x0 = math.max(0, footprint.left.floor());
    final y0 = math.max(0, footprint.top.floor());
    final x1 = math.min(w, footprint.right.ceil());
    final y1 = math.min(h, footprint.bottom.ceil());
    final rw = math.max(1, x1 - x0);
    final rh = math.max(1, y1 - y0);
    final out = Uint8List(rw * rh * 4);
    for (var y = 0; y < rh; y++) {
      final src = ((y0 + y) * w + x0) * 4;
      out.setRange(y * rw * 4, (y + 1) * rw * 4, rgba, src);
    }
    final image = await imageFromRgba(out, rw, rh);
    return GpuSourceRegion(image, x0.toDouble(), y0.toDouble(), 1, 1, transient: true);
  }

  @override
  void dispose() {}
}

/// Dates for the rendered JPEG: EXIF wall time, offset and ISO form (render.js exifDates)
class ExifDates {
  final String exif;
  final String offset;
  final String iso;

  const ExifDates(this.exif, this.offset, this.iso);

  static ExifDates? of(String? fileCreatedAt, String? localDateTime) {
    final instant = fileCreatedAt == null ? null : DateTime.tryParse(fileCreatedAt);
    if (instant == null) {
      return null;
    }
    final local = DateTime.tryParse(localDateTime ?? fileCreatedAt!);
    final offsetMinutes = local == null ? 0 : (local.difference(instant).inMilliseconds / 60000).round();
    final sign = offsetMinutes < 0 ? '-' : '+';
    final abs = offsetMinutes.abs();
    final wall = (local ?? instant).toUtc();
    String p(int v) => v.toString().padLeft(2, '0');
    final offset = '$sign${p(abs ~/ 60)}:${p(abs % 60)}';
    final date = '${wall.year.toString().padLeft(4, '0')}-${p(wall.month)}-${p(wall.day)}';
    final time = '${p(wall.hour)}:${p(wall.minute)}:${p(wall.second)}';
    return ExifDates('${date.replaceAll('-', ':')} $time', offset, '${date}T$time$offset');
  }
}

/// JPEG (quality 92, 4:4:4) with the camera and dates of the original, encoded off the UI isolate
Future<Uint8List> encodeJpeg(
  Uint8List rgba,
  int width,
  int height, {
  String? make,
  String? model,
  ExifDates? dates,
  int quality = 92,
}) {
  final transferable = TransferableTypedData.fromList([rgba]);
  return Isolate.run(() {
    final bytes = transferable.materialize();
    final image = img.Image.fromBytes(width: width, height: height, bytes: bytes, numChannels: 4);
    try {
      final ifd0 = image.exif.imageIfd;
      ifd0['Software'] = 'editor.photos';
      if (make != null) {
        ifd0['Make'] = make;
      }
      if (model != null) {
        ifd0['Model'] = model;
      }
      if (dates != null) {
        ifd0['DateTime'] = dates.exif;
        image.exif.exifIfd['DateTimeOriginal'] = dates.exif;
        image.exif.exifIfd['OffsetTimeOriginal'] = dates.offset;
      }
    } catch (_) {
      // EXIF is a nicety; Immich gets the date through the API as well
    }
    return img.encodeJpg(image, quality: quality, chroma: img.JpegChroma.yuv444);
  });
}
