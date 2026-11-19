// GPU renderer for edit recipes: the pixel pipeline of the web editor as Flutter fragment
// shaders (shaders/editor_photos/*.frag), used for the live preview and for the
// full-resolution export.
//
// A render is a short chain of passes. `pipeline.frag` applies a range of stages per
// pixel; wherever a stage needs a blurred copy of an earlier state (local tone, clarity,
// dehaze, pop, blur tool, noise reduction, sharpening) the chain stops, the state is
// box-downsampled (`reduce.frag`) and blurred with three box passes (`box.frag`, the
// same 3× box blur as the JavaScript), and the next pass reads that "field".
//
// Export: the large-radius fields are computed once over the whole photo at preview
// resolution (they are smooth), then the full-resolution output is rendered in tiles
// that each read those fields; the small-radius fields (noise, sharpen) are computed per
// tile with a margin, so tiles join seamlessly and no texture exceeds [maxTile].
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:immich_mobile/editor_photos/model/advanced.dart';
import 'package:immich_mobile/editor_photos/model/geometry.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/render/cpu_pipeline.dart';
import 'package:immich_mobile/editor_photos/render/js_math.dart';

const _shaderDir = 'shaders/editor_photos';

/// Source pixels for a render. The texture may be smaller than the original (a preview)
/// or cover only part of it (a tile of a very large original), see [GpuSourceRegion].
abstract class GpuSource {
  /// Size of the original (upright) image in pixels: geometry is defined against it
  double get width;
  double get height;

  /// A texture covering at least [footprint] (original pixels)
  FutureOr<GpuSourceRegion> region(ui.Rect footprint);

  void dispose();
}

class GpuSourceRegion {
  final ui.Image image;

  /// Original-pixel position of the texture's top-left corner
  final double originX;
  final double originY;

  /// Texels per original pixel
  final double scaleX;
  final double scaleY;

  /// Rendered on the GPU (rather than decoded): row order may differ, see [GpuCaps]
  final bool renderTarget;

  /// Created for one tile; the renderer disposes it afterwards
  final bool transient;

  const GpuSourceRegion(
    this.image,
    this.originX,
    this.originY,
    this.scaleX,
    this.scaleY, {
    this.renderTarget = false,
    this.transient = false,
  });
}

/// One texture for the whole image (possibly downscaled)
class GpuImageSource implements GpuSource {
  final ui.Image image;
  @override
  final double width;
  @override
  final double height;
  final bool _owned;
  final bool _renderTarget;

  GpuImageSource(
    this.image, {
    double? originalWidth,
    double? originalHeight,
    bool owned = true,
    bool renderTarget = false,
  }) : width = originalWidth ?? image.width.toDouble(),
       height = originalHeight ?? image.height.toDouble(),
       _owned = owned, // ignore: prefer_initializing_formals
       _renderTarget = renderTarget; // ignore: prefer_initializing_formals

  @override
  GpuSourceRegion region(ui.Rect footprint) =>
      GpuSourceRegion(image, 0, 0, image.width / width, image.height / height, renderTarget: _renderTarget);

  @override
  void dispose() {
    if (_owned) {
      image.dispose();
    }
  }
}

/// Masks for the tools on the GPU: sky/subject/depth packed into r/g/b of one texture
/// (upright source orientation), plus CPU copies for values the renderer needs up front
class GpuMasks {
  final ui.Image texture;
  final EditorMasks cpu;

  const GpuMasks(this.texture, this.cpu);

  bool get hasSky => cpu.sky != null;
  bool get hasSubject => cpu.subject != null;
  bool get hasDepth => cpu.depth != null;

  /// Uploads [masks]; with [float] as 32-bit floats (exact), else as 8-bit like the PNGs
  static Future<GpuMasks> upload(EditorMasks masks, {bool float = false}) async {
    final n = masks.width * masks.height;
    if (float) {
      final rgba = Float32List(n * 4);
      for (var p = 0; p < n; p++) {
        rgba[p * 4] = masks.sky?[p] ?? 0;
        rgba[p * 4 + 1] = masks.subject?[p] ?? 0;
        rgba[p * 4 + 2] = masks.depth?[p] ?? 0;
        rgba[p * 4 + 3] = 1;
      }
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rgba.buffer.asUint8List(),
        masks.width,
        masks.height,
        ui.PixelFormat.rgbaFloat32,
        completer.complete,
        targetFormat: ui.TargetPixelFormat.rgbaFloat32,
      );
      return GpuMasks(await completer.future, masks);
    }
    final rgba = Uint8List(n * 4);
    int byte(Float32List? ch, int p) => ch == null ? 0 : (ch[p] * 255).round().clamp(0, 255);
    for (var p = 0; p < n; p++) {
      rgba[p * 4] = byte(masks.sky, p);
      rgba[p * 4 + 1] = byte(masks.subject, p);
      rgba[p * 4 + 2] = byte(masks.depth, p);
      rgba[p * 4 + 3] = 255;
    }
    return GpuMasks(await imageFromRgba(rgba, masks.width, masks.height), masks);
  }

  void dispose() => texture.dispose();
}

Future<ui.Image> imageFromRgba(Uint8List rgba, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

/// What the device's GPU supports, probed once
class GpuCaps {
  /// Render targets keep floats outside 0..1 (else states are stored offset and scaled)
  final bool floatTargets;

  /// Row order when sampling render-target / decoded textures in a shader is bottom-up
  final bool flipTargets;
  final bool flipDecoded;

  const GpuCaps({required this.floatTargets, required this.flipTargets, required this.flipDecoded});

  ui.TargetPixelFormat get stateFormat =>
      floatTargets ? ui.TargetPixelFormat.rgbaFloat32 : ui.TargetPixelFormat.dontCare;
  double get encScale => floatTargets ? 1 : 0.5;
  double get encBias => floatTargets ? 0 : 0.25;

  @override
  String toString() => 'GpuCaps(float: $floatTargets, flipTargets: $flipTargets, flipDecoded: $flipDecoded)';
}

enum _Field { base, clar, veil, pop, bl1, bl2, bl3, noise, sharp }

class _FieldTex {
  final ui.Image image;

  /// Output pixels (of the frame that uses it) per texel
  final double k;

  const _FieldTex(this.image, this.k);
}

/// The region a pass chain renders: [width]×[height] pixels at [originX]/[originY] of a
/// [fullWidth]×[fullHeight] output whose pixel centres map to the original via [affine]
class _Frame {
  final int width;
  final int height;
  final int originX;
  final int originY;
  final int fullWidth;
  final int fullHeight;
  final Affine affine;

  const _Frame(this.width, this.height, this.originX, this.originY, this.fullWidth, this.fullHeight, this.affine);

  double get diag => _hypot(fullWidth.toDouble(), fullHeight.toDouble());
}

double _hypot(double a, double b) => math.sqrt(a * a + b * b);

int _jsRoundI(double v) {
  final f = v.floorToDouble();
  return (v - f >= 0.5 ? f + 1 : f).toInt();
}

/// Recipe values that do not depend on the frame
class _Params {
  final Recipe recipe;
  final EffectiveAdjust eff;
  final Advanced adv;
  final GpuMasks? masks;

  /// Size of the original image (the coordinate system of the geometry and the masks)
  final double origW;
  final double origH;

  _Params(this.recipe, this.masks, this.origW, this.origH) : eff = EffectiveAdjust.of(recipe), adv = recipe.advanced;

  double a(String key) => eff.adjust[key]!;

  bool get localTone => a('shadows') != 0 || a('highlights') != 0 || a('hdr') != 0;
  bool get clarity => adv.clarity != 0;
  bool get dehaze => adv.dehaze != 0;
  bool get pop => a('pop') != 0;
  bool get blurTool => recipe.tools.blur.strength > 0 && (masks?.hasDepth ?? false);
  bool get noise => adv.noise != 0;
  bool get sharpen => adv.sharpen.amount != 0;
  bool get grain => adv.grain != 0;
  bool get usesMasks => masks != null && recipe.tools.any;

  /// Blur radius (pixels of a frame with this diagonal) of each field
  double radius(_Field f, double diag) {
    final scale = diag / 2500;
    final s0 = recipe.tools.blur.strength;
    return switch (f) {
      _Field.base => Cal.baseRadius * diag,
      _Field.clar => diag * 0.02,
      _Field.veil => diag * 0.015,
      _Field.pop => Cal.detailRadius * diag * 4,
      _Field.bl1 => math.max(1, 0.004 * diag * s0),
      _Field.bl2 => math.max(1, 0.011 * diag * s0),
      _Field.bl3 => math.max(1, 0.024 * diag * s0),
      _Field.noise => math.max(1, 1.5 * scale),
      _Field.sharp => math.max(1, adv.sharpen.radius * scale),
    };
  }
}

/// Stages (pipeline.frag numbering) and the fields they read, in order
const _deps = <(int, List<_Field>)>[
  (3, [_Field.base]),
  (4, [_Field.clar]),
  (5, [_Field.veil]),
  (7, [_Field.pop]),
  (12, [_Field.bl1, _Field.bl2, _Field.bl3]),
  (14, [_Field.noise]),
  (15, [_Field.sharp]),
];

const _globalFields = {_Field.base, _Field.clar, _Field.veil, _Field.pop, _Field.bl1, _Field.bl2, _Field.bl3};

class GpuRenderer {
  final ui.FragmentProgram _pipeline;
  final ui.FragmentProgram _reduce;
  final ui.FragmentProgram _box;
  final GpuCaps caps;
  final ui.Image _dummy;

  /// Largest tile (incl. margins) rendered at once during export
  final int maxTile;

  GpuRenderer._(this._pipeline, this._reduce, this._box, this.caps, this._dummy, this.maxTile);

  static Future<GpuRenderer>? _instance;

  /// Shared renderer (programs are loaded and the GPU probed once)
  static Future<GpuRenderer> instance() => _instance ??= create().catchError((Object e, StackTrace stack) {
    _instance = null;
    Error.throwWithStackTrace(e, stack);
  });

  static Future<GpuRenderer> create({int maxTile = 2048}) async {
    final programs = await Future.wait([
      ui.FragmentProgram.fromAsset('$_shaderDir/pipeline.frag'),
      ui.FragmentProgram.fromAsset('$_shaderDir/reduce.frag'),
      ui.FragmentProgram.fromAsset('$_shaderDir/box.frag'),
      ui.FragmentProgram.fromAsset('$_shaderDir/probe.frag'),
    ]);
    final dummy = await imageFromRgba(Uint8List.fromList([0, 0, 0, 255]), 1, 1);
    final caps = await _probe(programs[3]);
    return GpuRenderer._(programs[0], programs[1], programs[2], caps, dummy, maxTile);
  }

  static Future<GpuCaps> _probe(ui.FragmentProgram probe) async {
    Future<Float32List?> sample(ui.Image tex, double y, List<double> add, ui.TargetPixelFormat format) async {
      final shader = probe.fragmentShader()
        ..setFloat(0, 0.5)
        ..setFloat(1, y)
        ..setFloat(2, add[0])
        ..setFloat(3, add[1])
        ..setFloat(4, add[2])
        ..setFloat(5, add[3])
        ..setImageSampler(0, tex);
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawRect(
        const ui.Rect.fromLTWH(0, 0, 1, 1),
        ui.Paint()
          ..shader = shader
          ..blendMode = ui.BlendMode.src,
      );
      final picture = rec.endRecording();
      try {
        final image = picture.toImageSync(1, 1, targetFormat: format);
        final data = await image.toByteData(format: ui.ImageByteFormat.rawExtendedRgba128);
        image.dispose();
        return data?.buffer.asFloat32List();
      } catch (_) {
        return null;
      } finally {
        picture.dispose();
        shader.dispose();
      }
    }

    // Decoded texture: red on top, green below
    final decoded = await imageFromRgba(Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255]), 1, 2);
    // Render target: the same, drawn
    final rec = ui.PictureRecorder();
    ui.Canvas(rec)
      ..drawRect(const ui.Rect.fromLTWH(0, 0, 1, 1), ui.Paint()..color = const ui.Color(0xFFFF0000))
      ..drawRect(const ui.Rect.fromLTWH(0, 1, 1, 1), ui.Paint()..color = const ui.Color(0xFF00FF00));
    final pic = rec.endRecording();
    final target = pic.toImageSync(1, 2);
    pic.dispose();
    final top = await sample(decoded, 0.25, const [0, 0, 0, 0], ui.TargetPixelFormat.dontCare);
    final topTarget = await sample(target, 0.25, const [0, 0, 0, 0], ui.TargetPixelFormat.dontCare);
    final black = await imageFromRgba(Uint8List.fromList([0, 0, 0, 255]), 1, 1);
    final float = await sample(black, 0.5, const [1.25, -0.5, 0.123456, 0], ui.TargetPixelFormat.rgbaFloat32);
    decoded.dispose();
    target.dispose();
    black.dispose();
    final floatOk =
        float != null &&
        (float[0] - 1.25).abs() < 1e-4 &&
        (float[1] + 0.5).abs() < 1e-4 &&
        (float[2] - 0.123456).abs() < 1e-5;
    return GpuCaps(
      floatTargets: floatOk,
      flipDecoded: top != null && top[1] > top[0],
      flipTargets: topTarget != null && topTarget[1] > topTarget[0],
    );
  }

  // ---- Public entry points ------------------------------------------------------------

  /// Renders [recipe] for display: the whole image at [maxPixels] at most. With
  /// [toneOnly] the geometry is ignored (the crop tab draws rotation and crop itself).
  /// [floatOutput] returns the clamped float result instead of dithered 8-bit (tests).
  Future<ui.Image> _renderPreview(
    GpuSource source,
    Recipe recipe, {
    GpuMasks? masks,
    bool toneOnly = false,
    double maxPixels = double.infinity,
    bool floatOutput = false,
  }) async {
    final geometry = toneOnly ? Geometry() : recipe.geometry;
    final full = await source.region(ui.Rect.fromLTWH(0, 0, source.width, source.height));
    // Output size in texture pixels (the texture is the preview)
    final texW = full.image.width.toDouble();
    final texH = full.image.height.toDouble();
    final (w, h) = outputSize(geometry, texW, texH, maxPixels);
    final affine = _scaleAffine(
      outputAffine(geometry, texW, texH, w.toDouble(), h.toDouble()),
      1 / full.scaleX,
      1 / full.scaleY,
    );
    final frame = _Frame(w, h, 0, 0, w, h, affine);
    final params = _Params(recipe, masks, source.width, source.height);
    final keep = <ui.Image>[];
    try {
      final region = _prehalve(full, texW, texH, w, h, keep);
      return await _walk(
        frame,
        params,
        region: region,
        fields: {},
        local: _Field.values.toSet(),
        mode: floatOutput ? 2 : 1,
        keep: keep,
      );
    } finally {
      for (final image in keep) {
        image.dispose();
      }
    }
  }

  /// Full-resolution render as RGBA bytes ([width]×[height]). [proxy] is a small copy of
  /// the source used to compute the smooth fields (made from [source] when null).
  Future<(Uint8List, int, int)> _renderFull(
    GpuSource source,
    Recipe recipe, {
    GpuMasks? masks,
    GpuSource? proxy,
    double maxPixels = double.infinity,
    double fieldPixels = 2.4e6,
    void Function(double progress)? onProgress,
    bool floatOutput = false,
  }) async {
    final geometry = recipe.geometry;
    final (w, h) = outputSize(geometry, source.width, source.height, maxPixels);
    final params = _Params(recipe, masks, source.width, source.height);
    final keep = <ui.Image>[];
    final fieldKeep = <ui.Image>[];
    GpuSource? ownProxy;
    try {
      // 1. Smooth fields over the whole photo at reduced resolution
      final fields = <_Field, _FieldTex>{};
      final needsFields = params.localTone || params.clarity || params.dehaze || params.pop || params.blurTool;
      if (needsFields) {
        final fieldSource = proxy ?? (ownProxy = await _downscaled(source, fieldPixels));
        final scale = math.min(1.0, math.sqrt(fieldPixels / (w * h)));
        final fw = math.max(1, (w * scale).round());
        final fh = math.max(1, (h * scale).round());
        // The proxy covers the whole photo: express its scale against the full source
        final proxyRegion = await fieldSource.region(ui.Rect.fromLTWH(0, 0, fieldSource.width, fieldSource.height));
        final region = _prehalve(
          GpuSourceRegion(
            proxyRegion.image,
            0,
            0,
            proxyRegion.image.width / source.width,
            proxyRegion.image.height / source.height,
            renderTarget: proxyRegion.renderTarget,
          ),
          source.width,
          source.height,
          fw,
          fh,
          fieldKeep,
        );
        final affine = outputAffine(geometry, source.width, source.height, fw.toDouble(), fh.toDouble());
        final fieldFrame = _Frame(fw, fh, 0, 0, fw, fh, affine);
        await _walk(
          fieldFrame,
          params,
          region: region,
          fields: fields,
          local: _globalFields,
          mode: -1,
          keep: fieldKeep,
        );
        // Express the fields in full-output pixels
        final fx = w / fw;
        fields.updateAll((key, value) => _FieldTex(value.image, value.k * fx));
      }

      // 2. Tiles
      final out = Uint8List(w * h * 4);
      final affine = outputAffine(geometry, source.width, source.height, w.toDouble(), h.toDouble());
      final full = _Frame(w, h, 0, 0, w, h, affine);
      final margin = _localMargin(params, full.diag);
      final core = math.max(32, maxTile - 2 * margin);
      final floatOut = floatOutput ? Float32List(w * h * 4) : null;
      final tilesX = (w / core).ceil();
      final tilesY = (h / core).ceil();
      var done = 0;
      for (var ty = 0; ty < tilesY; ty++) {
        for (var tx = 0; tx < tilesX; tx++) {
          final cx0 = tx * core;
          final cy0 = ty * core;
          final cw = math.min(core, w - cx0);
          final ch = math.min(core, h - cy0);
          final x0 = math.max(0, cx0 - margin);
          final y0 = math.max(0, cy0 - margin);
          final x1 = math.min(w, cx0 + cw + margin);
          final y1 = math.min(h, cy0 + ch + margin);
          final frame = _Frame(x1 - x0, y1 - y0, x0, y0, w, h, affine);
          final tileKeep = <ui.Image>[];
          final sourceRegion = await source.region(_footprint(affine, x0, y0, x1, y1));
          if (sourceRegion.transient) {
            tileKeep.add(sourceRegion.image);
          }
          final region = _prehalve(sourceRegion, source.width, source.height, w, h, tileKeep);
          try {
            final image = await _walk(
              frame,
              params,
              region: region,
              fields: fields,
              local: const {_Field.noise, _Field.sharp},
              mode: floatOutput ? 2 : 1,
              keep: tileKeep,
              core: (cx0, cy0, cw, ch),
            );
            tileKeep.add(image);
            if (floatOut != null) {
              final data = (await image.toByteData(format: ui.ImageByteFormat.rawExtendedRgba128))!;
              final f = data.buffer.asFloat32List();
              for (var y = 0; y < ch; y++) {
                floatOut.setRange(((cy0 + y) * w + cx0) * 4, ((cy0 + y) * w + cx0 + cw) * 4, f, y * cw * 4);
              }
            } else {
              final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
              final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
              for (var y = 0; y < ch; y++) {
                out.setRange(((cy0 + y) * w + cx0) * 4, ((cy0 + y) * w + cx0 + cw) * 4, bytes, y * cw * 4);
              }
            }
          } finally {
            for (final image in tileKeep) {
              image.dispose();
            }
          }
          done++;
          onProgress?.call(done / (tilesX * tilesY));
        }
      }
      if (floatOut != null) {
        _lastFloat = floatOut;
      }
      return (out, w, h);
    } finally {
      for (final image in [...keep, ...fieldKeep]) {
        image.dispose();
      }
      ownProxy?.dispose();
    }
  }

  /// Float output of the last [_renderFull] with `floatOutput: true` (tests)
  Float32List? get lastFloatOutput => _lastFloat;
  Float32List? _lastFloat;

  // ---- The pass chain ---------------------------------------------------------------

  /// Runs the stages over [frame]. Fields in [local] are computed here (and stored in
  /// [fields]); others must already be in [fields]. Mode -1 stops once every local field
  /// is computed (the export's field pass). [core] limits the final output to a sub-rect.
  Future<ui.Image> _walk(
    _Frame frame,
    _Params p, {
    required GpuSourceRegion region,
    required Map<_Field, _FieldTex> fields,
    required Set<_Field> local,
    required int mode,
    required List<ui.Image> keep,
    (int, int, int, int)? core,
  }) async {
    // Fields computed here replace any from an earlier frame (tiles)
    fields.removeWhere((f, _) => local.contains(f));
    final grain = p.grain && mode >= 0 ? await _grainTexture(frame, core) : null;
    if (grain != null) {
      keep.add(grain);
    }
    ui.Image? state;
    var from = 0;
    final diag = frame.diag;
    for (final (stage, kinds) in _deps) {
      final active = kinds.where((f) => local.contains(f) && _fieldActive(p, f)).toList();
      if (active.isEmpty) {
        continue;
      }
      if (stage > from || state == null) {
        state = _pass(frame, p, region, state, from, stage, 0, fields, keep, null, null);
        keep.add(state);
      }
      from = stage;
      for (final f in active) {
        final isLocal = !_globalFields.contains(f);
        fields[f] = _field(state, frame, p.radius(f, diag), f == _Field.veil, keep, allowReduce: !isLocal);
      }
      if (mode < 0 && !local.any((f) => _fieldActive(p, f) && !fields.containsKey(f))) {
        return state;
      }
    }
    if (mode < 0) {
      return state ?? _dummy;
    }
    return _pass(frame, p, region, state, from, 19, mode, fields, keep, core, grain);
  }

  bool _fieldActive(_Params p, _Field f) => switch (f) {
    _Field.base => p.localTone,
    _Field.clar => p.clarity,
    _Field.veil => p.dehaze,
    _Field.pop => p.pop,
    _Field.bl1 || _Field.bl2 || _Field.bl3 => p.blurTool,
    _Field.noise => p.noise,
    _Field.sharp => p.sharpen,
  };

  /// Like applyGeometry() in pipeline.js: when the output is much smaller than the
  /// source, sample a source halved (2×2 box) as often as the JavaScript would
  GpuSourceRegion _prehalve(GpuSourceRegion region, double w0, double h0, int outW, int outH, List<ui.Image> keep) {
    final out = (outW * outH).toDouble();
    final ratio = math.min((w0 * h0) / out, (region.image.width * region.image.height) / out);
    var image = region.image;
    var scale = 1;
    while (ratio / (scale * scale) >= 4 && image.width > 2 && image.height > 2) {
      final shader = _reduce.fragmentShader();
      _setVec2(shader, 'uInSize', image.width.toDouble(), image.height.toDouble());
      final flip = (scale == 1 && !region.renderTarget) ? caps.flipDecoded : caps.flipTargets;
      _setVec4(shader, 'uParams', 2, 0, flip ? 1 : 0, 0);
      shader.getImageSampler('uIn').set(image);
      image = _draw(shader, image.width ~/ 2, image.height ~/ 2);
      keep.add(image);
      scale *= 2;
    }
    if (scale == 1) {
      return region;
    }
    return GpuSourceRegion(
      image,
      region.originX,
      region.originY,
      region.scaleX * image.width / region.image.width,
      region.scaleY * image.height / region.image.height,
      renderTarget: true,
    );
  }

  int _localMargin(_Params p, double diag) {
    var m = 0;
    if (p.noise) {
      m += 3 * math.max(1, _jsRoundI(p.radius(_Field.noise, diag)));
    }
    if (p.sharpen) {
      m += 3 * math.max(1, _jsRoundI(p.radius(_Field.sharp, diag)));
    }
    return m == 0 ? 0 : m + 2;
  }

  /// Blurred copy of [state] (or of its dark channel) with the 3× box blur of [radius]
  _FieldTex _field(
    ui.Image state,
    _Frame frame,
    double radius,
    bool darkChannel,
    List<ui.Image> keep, {
    required bool allowReduce,
  }) {
    final r = math.max(1, _jsRoundI(radius));
    final k = allowReduce && r > 16 ? (r / 10).round() : 1;
    var src = state;
    if (k > 1 || darkChannel) {
      final w = (state.width / k).ceil();
      final h = (state.height / k).ceil();
      final shader = _reduce.fragmentShader();
      _setVec2(shader, 'uInSize', state.width.toDouble(), state.height.toDouble());
      _setVec4(shader, 'uParams', k.toDouble(), darkChannel ? 1 : 0, caps.flipTargets ? 1 : 0, 0);
      shader.getImageSampler('uIn').set(state);
      src = _draw(shader, w, h);
      keep.add(src);
    }
    final rl = k > 1 ? math.max(1, _jsRoundI(radius / k)) : r;
    for (var pass = 0; pass < 3; pass++) {
      for (final (dx, dy) in const [(1.0, 0.0), (0.0, 1.0)]) {
        final shader = _box.fragmentShader();
        _setVec2(shader, 'uInSize', src.width.toDouble(), src.height.toDouble());
        _setVec4(shader, 'uParams', dx, dy, rl.toDouble(), caps.flipTargets ? 1 : 0);
        shader.getImageSampler('uIn').set(src);
        src = _draw(shader, src.width, src.height);
        keep.add(src);
      }
    }
    return _FieldTex(src, k.toDouble());
  }

  ui.Image _draw(ui.FragmentShader shader, int width, int height, {bool float = true}) {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()
        ..shader = shader
        ..blendMode = ui.BlendMode.src,
    );
    final picture = rec.endRecording();
    final image = picture.toImageSync(
      width,
      height,
      targetFormat: float ? caps.stateFormat : ui.TargetPixelFormat.dontCare,
    );
    picture.dispose();
    return image;
  }

  /// One pipeline pass: stages [from, to) over [frame] (or its [core]); mode 0 = state
  ui.Image _pass(
    _Frame frame,
    _Params p,
    GpuSourceRegion region,
    ui.Image? state,
    int from,
    int to,
    int mode,
    Map<_Field, _FieldTex> fields,
    List<ui.Image> keep,
    (int, int, int, int)? core,
    ui.Image? grain,
  ) {
    final s = _pipeline.fragmentShader();
    final outX = core?.$1 ?? frame.originX;
    final outY = core?.$2 ?? frame.originY;
    final outW = core?.$3 ?? frame.width;
    final outH = core?.$4 ?? frame.height;
    final inSize = state == null
        ? (region.image.width.toDouble(), region.image.height.toDouble())
        : (state.width.toDouble(), state.height.toDouble());
    _setVec2(s, 'uSize', outW.toDouble(), outH.toDouble());
    _setVec2(s, 'uOrigin', outX.toDouble(), outY.toDouble());
    _setVec2(s, 'uFull', frame.fullWidth.toDouble(), frame.fullHeight.toDouble());
    _setVec4(s, 'uRange', from.toDouble(), to.toDouble(), mode.toDouble(), state == null ? 1 : 0);
    _setVec4(
      s,
      'uIo',
      (outX - frame.originX).toDouble(),
      (outY - frame.originY).toDouble(),
      caps.encScale,
      caps.encBias,
    );
    final sourceFlip = region.renderTarget ? caps.flipTargets : caps.flipDecoded;
    _setVec4(s, 'uFlip', caps.flipTargets ? 1 : 0, caps.flipDecoded ? 1 : 0, sourceFlip ? 1 : 0, 0);
    final a = frame.affine;
    _setVec3(s, 'uAffX', a.a, a.b, a.c);
    _setVec3(s, 'uAffY', a.d, a.e, a.f);
    _setVec4(s, 'uSrcRect', region.originX, region.originY, region.scaleX, region.scaleY);
    final masks = p.masks;
    _setVec4(s, 'uSizes', inSize.$1, inSize.$2, p.origW, p.origH);

    _setAdjustUniforms(s, p);
    _setToolUniforms(s, p, frame);

    // Fields
    _FieldTex? fieldOf(_Field f) => fields[f];
    double kOf(_Field f) => fieldOf(f)?.k ?? 1;
    double wOf(_Field f) => (fieldOf(f)?.image.width ?? 1).toDouble();
    double hOf(_Field f) => (fieldOf(f)?.image.height ?? 1).toDouble();
    _setVec4(s, 'uFieldK', kOf(_Field.base), kOf(_Field.clar), kOf(_Field.veil), kOf(_Field.pop));
    _setVec4(s, 'uFieldK2', kOf(_Field.bl1), kOf(_Field.bl2), kOf(_Field.bl3), 0);
    _setVec4(s, 'uFieldSize0', wOf(_Field.base), hOf(_Field.base), wOf(_Field.clar), hOf(_Field.clar));
    _setVec4(s, 'uFieldSize1', wOf(_Field.veil), hOf(_Field.veil), wOf(_Field.pop), hOf(_Field.pop));
    _setVec4(s, 'uFieldSize2', wOf(_Field.bl1), hOf(_Field.bl1), wOf(_Field.bl2), hOf(_Field.bl2));
    _setVec4(
      s,
      'uFieldSize3',
      wOf(_Field.bl3),
      hOf(_Field.bl3),
      (masks?.cpu.width ?? 1).toDouble(),
      (masks?.cpu.height ?? 1).toDouble(),
    );

    s.getImageSampler('uIn').set(state ?? region.image);
    for (final (name, f) in const [
      ('uBase', _Field.base),
      ('uClar', _Field.clar),
      ('uVeil', _Field.veil),
      ('uPop', _Field.pop),
      ('uBl1', _Field.bl1),
      ('uBl2', _Field.bl2),
      ('uBl3', _Field.bl3),
      ('uNoise', _Field.noise),
      ('uSharp', _Field.sharp),
    ]) {
      s.getImageSampler(name).set(fields[f]?.image ?? _dummy);
    }
    s.getImageSampler('uMasks').set(masks?.texture ?? _dummy);
    s.getImageSampler('uCurves').set(_curves(p, keep));
    s.getImageSampler('uGrain').set(grain ?? _dummy);
    return _draw(s, outW, outH, float: mode != 1);
  }

  void _setAdjustUniforms(ui.FragmentShader s, _Params p) {
    final adjust = p.eff.adjust;
    double a(String key) => adjust[key]!;
    final warm = a('warmth') * Cal.warmth;
    final tint = a('tint') * Cal.tint;
    if (warm != 0 || tint != 0) {
      final gr = math.pow(1 + warm, 1 / 2.2).toDouble();
      final gg = math.pow(1 - tint, 1 / 2.2).toDouble();
      final gb = math.pow(1 - warm, 1 / 2.2).toDouble();
      final norm = 1 / (0.2126 * gr + 0.7152 * gg + 0.0722 * gb);
      _setVec4(s, 'uWb', gr * norm, gg * norm, gb * norm, 1);
    } else {
      _setVec4(s, 'uWb', 1, 1, 1, 0);
    }
    final adv = p.adv;
    final exposure = adv.exposure != 0 ? math.pow(2, adv.exposure / 2.2).toDouble() : 1.0;
    _setVec4(s, 'uLocal', a('shadows') * Cal.shadows, a('highlights') * Cal.highlights, a('hdr') * Cal.hdr, exposure);
    _setVec4(s, 'uClarHaze', adv.clarity, adv.dehaze * 0.85, p.clarity ? 1 : 0, p.dehaze ? 1 : 0);
    final b = a('brightness') * Cal.brightness;
    final c = a('contrast') * Cal.contrast;
    final wp = a('whitePoint') * Cal.whitePoint;
    final bp = a('blackPoint') * Cal.blackPoint;
    _setVec4(s, 'uTone', b, c, wp, bp);
    final toneActive = a('brightness') != 0 || a('contrast') != 0 || a('whitePoint') != 0 || a('blackPoint') != 0;
    final vib = a('pop') * Cal.popVibrance;
    _setVec4(s, 'uTone2', math.pow(2, -b).toDouble(), toneActive ? 1 : 0, a('pop') * Cal.pop, vib);
    final sat = a('saturation');
    final skin = a('skinTone') * Cal.skinTone;
    final blue = a('blueTone') * Cal.blueTone;
    final mono = p.eff.mono;
    final split = p.eff.split;
    _setVec4(s, 'uColour', sat > 0 ? sat * Cal.saturationUp : sat * Cal.saturationDown, skin, blue, mono);
    _setVec4(
      s,
      'uSplitS',
      split?.shadows[0] ?? 0,
      split?.shadows[1] ?? 0,
      split?.shadows[2] ?? 0,
      split == null ? 0 : (split.amount == 0 ? 1e-30 : split.amount),
    );
    final colourActive = sat != 0 || vib != 0 || skin != 0 || blue != 0 || mono != 0 || split != null;
    _setVec4(
      s,
      'uSplitH',
      split?.highlights[0] ?? 0,
      split?.highlights[1] ?? 0,
      split?.highlights[2] ?? 0,
      colourActive ? 1 : 0,
    );
    final lv = adv.levels;
    final span = math.max(1e-3, lv.inWhite - lv.inBlack);
    _setVec4(s, 'uLevels', lv.inBlack, span, lv.gamma, lv.outBlack);
    final master = adv.curves['rgb']!.isNotEmpty;
    _setVec4(s, 'uLevels2', lv.outWhite, adv.levelsActive ? 1 : 0, master ? 1 : 0, adv.curvesActive ? 1 : 0);
    _setVec4(
      s,
      'uCurveOn',
      adv.curves['r']!.isNotEmpty ? 1 : 0,
      adv.curves['g']!.isNotEmpty ? 1 : 0,
      adv.curves['b']!.isNotEmpty ? 1 : 0,
      master ? 1 : 0,
    );
    final hslOn = adv.hslActive ? 1.0 : 0.0;
    for (var i = 0; i < hslBands.length; i++) {
      final band = adv.hsl[hslBands[i].$1]!;
      _setVec4(s, 'uHsl$i', band.h, band.s, band.l, i == 0 ? hslOn : 0);
    }
    final grading = adv.grading;
    final tints = [
      for (final r in gradingRegions)
        () {
          final region = grading.regions[r]!;
          final rgb = _hslToRgb(region.hue, 1, 0.5);
          final lum = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
          return [for (final v in rgb) (v - lum) * region.sat * 0.18];
        }(),
    ];
    _setVec4(s, 'uGrade0', tints[0][0], tints[0][1], tints[0][2], adv.gradingActive ? 1 : 0);
    _setVec4(s, 'uGrade1', tints[1][0], tints[1][1], tints[1][2], grading.balance * 0.25);
    _setVec4(s, 'uGrade2', tints[2][0], tints[2][1], tints[2][2], 0.15 + grading.blending * 0.35);
    _setVec4(s, 'uFinish', a('vignette') * Cal.vignette, adv.noise, adv.sharpen.amount, adv.grain);
    final v = adv.vignette;
    _setVec4(s, 'uShape', v.amount, (v.roundness + 1) / 2, 0.2 + v.midpoint * 0.8, 0.05 + v.feather * 0.9);
  }

  void _setToolUniforms(ui.FragmentShader s, _Params p, _Frame frame) {
    final masks = p.masks;
    final t = p.recipe.tools;
    final use = p.usesMasks;
    _setVec4(
      s,
      'uMaskOn',
      masks?.hasSky == true ? 1 : 0,
      masks?.hasSubject == true ? 1 : 0,
      masks?.hasDepth == true ? 1 : 0,
      use ? 1 : 0,
    );
    final look = skyLooks[t.sky.palette] ?? skyLooks['vivid']!;
    _setVec4(s, 'uSky', t.sky.strength, look.tint, look.lum, look.sat);
    _setVec4(s, 'uSky2', look.contrast, look.scene != null ? 1 : 0, 0, 0);
    _setVec4(s, 'uSkyTop', look.top[0], look.top[1], look.top[2], 0);
    _setVec4(s, 'uSkyBottom', look.bottom[0], look.bottom[1], look.bottom[2], 0);
    final scene = look.scene ?? const [1.0, 1.0, 1.0];
    _setVec4(s, 'uSkyScene', scene[0], scene[1], scene[2], 0);
    final focusDepth = use && p.blurTool ? _focusDepth(p, frame) : 0.0;
    _setVec4(s, 'uFocus', t.colorFocus, p.blurTool ? t.blur.strength : 0, focusDepth, 0);
    final faces = use && t.portraitLight.strength > 0 ? _faces(p, frame) : const <(double, double, double)>[];
    _setVec4(s, 'uLight', t.portraitLight.strength, faces.length.toDouble(), 0, 0);
    for (var i = 0; i < 8; i++) {
      final f = i < faces.length ? faces[i] : null;
      _setVec4(s, 'uFace$i', f?.$1 ?? 0, f?.$2 ?? 0, f?.$3 ?? 0, 0);
    }
  }

  /// Faces in full-output pixels: (cx, cy, radius) of the light, like applyTools
  List<(double, double, double)> _faces(_Params p, _Frame frame) {
    final masks = p.masks!;
    final w = frame.fullWidth.toDouble();
    final h = frame.fullHeight.toDouble();
    final aff = frame.affine;
    final (ox, oy) = aff.apply(0.5, 0.5);
    final (ex0, ex1) = aff.apply(1.5, 0.5);
    final (ey0, ey1) = aff.apply(0.5, 1.5);
    final a = ex0 - ox;
    final b = ey0 - ox;
    final c = ex1 - oy;
    final d = ey1 - oy;
    var det = a * d - b * c;
    if (det == 0) {
      det = 1;
    }
    final scale = math.sqrt(det.abs()) == 0 ? 1 : math.sqrt(det.abs());
    final w0 = p.origW;
    final h0 = p.origH;
    final lx = p.recipe.tools.portraitLight.x - 0.5;
    final ly = p.recipe.tools.portraitLight.y - 0.5;
    final out = <(double, double, double)>[];
    for (final f in masks.cpu.faces) {
      final x = (f.x + f.w / 2) * w0 - ox;
      final y = (f.y + f.h / 2) * h0 - oy;
      final cx = (d * x - b * y) / det;
      final cy = (-c * x + a * y) / det;
      final size = math.max(f.w * w0, f.h * h0) / scale;
      final fx = cx / w - size / 2 / w;
      final fy = cy / h - size / 2 / h;
      final fw = size / w;
      final fh = size / h;
      if (!(fx + fw > 0 && fy + fh > 0 && fx < 1 && fy < 1)) {
        continue;
      }
      final s = math.max(fw * w, fh * h);
      out.add(((fx + fw / 2) * w + lx * s * 0.9, (fy + fh / 2) * h + ly * s * 0.9, s * 1.4));
      if (out.length == 8) {
        break;
      }
    }
    return out;
  }

  /// Depth under the blur focus point, from the CPU copy of the depth mask
  double _focusDepth(_Params p, _Frame frame) {
    final masks = p.masks!.cpu;
    final depth = masks.depth!;
    final t = p.recipe.tools.blur;
    final w = frame.fullWidth;
    final h = frame.fullHeight;
    final fx = math.min(w - 1, math.max(0, _jsRoundI(t.focusX * w)));
    final fy = math.min(h - 1, math.max(0, _jsRoundI(t.focusY * h)));
    final (ox, oy) = frame.affine.apply(fx + 0.5, fy + 0.5);
    final mw = masks.width;
    final mh = masks.height;
    final x = math.min(mw - 1.0, math.max(0.0, (ox / p.origW) * mw - 0.5));
    final y = math.min(mh - 1.0, math.max(0.0, (oy / p.origH) * mh - 0.5));
    final x0 = x.floor();
    final y0 = y.floor();
    final x1 = math.min(mw - 1, x0 + 1);
    final y1 = math.min(mh - 1, y0 + 1);
    final ax = x - x0;
    final ay = y - y0;
    final top = depth[y0 * mw + x0] + (depth[y0 * mw + x1] - depth[y0 * mw + x0]) * ax;
    final bottom = depth[y1 * mw + x0] + (depth[y1 * mw + x1] - depth[y1 * mw + x0]) * ax;
    return top + (bottom - top) * ay;
  }

  final _curveCache = <String, ui.Image>{};

  /// Curves as a 1025×4 texture (rows r, g, b, master), 16 bits per value in r/g
  ui.Image _curves(_Params p, List<ui.Image> keep) {
    final adv = p.adv;
    if (!adv.curvesActive) {
      return _dummy;
    }
    final key = [for (final c in curveChannels) adv.curves[c]].toString();
    final cached = _curveCache[key];
    if (cached != null) {
      return cached;
    }
    // Synchronous upload is not available; curves are prepared by [prepare]
    return _dummy;
  }

  /// Uploads textures a recipe needs before rendering (curves); call before render*
  Future<void> prepare(Recipe recipe) async {
    final adv = recipe.advanced;
    if (!adv.curvesActive) {
      return;
    }
    final key = [for (final c in curveChannels) adv.curves[c]].toString();
    if (_curveCache.containsKey(key)) {
      return;
    }
    final rgba = Uint8List(1025 * 4 * 4);
    final rows = ['r', 'g', 'b', 'rgb'];
    for (var row = 0; row < 4; row++) {
      final points = adv.curves[rows[row]]!;
      final lut = points.isEmpty ? null : curveLut(points);
      for (var i = 0; i <= 1024; i++) {
        final v = lut == null ? i / 1024 : lut[i];
        final q = (v.clamp(0.0, 1.0) * 65535).round();
        final o = (row * 1025 + i) * 4;
        rgba[o] = q >> 8;
        rgba[o + 1] = q & 255;
        rgba[o + 3] = 255;
      }
    }
    if (_curveCache.length >= 16) {
      // Forget the oldest; not disposed here because a render may still sample it (the
      // garbage collector releases it once no picture references it)
      _curveCache.remove(_curveCache.keys.first);
    }
    _curveCache[key] = await imageFromRgba(rgba, 1025, 4);
  }

  /// Per-pixel grain hash for the pixels this frame outputs (16 bits in r/g)
  Future<ui.Image> _grainTexture(_Frame frame, (int, int, int, int)? core) {
    final x0 = core?.$1 ?? frame.originX;
    final y0 = core?.$2 ?? frame.originY;
    final w = core?.$3 ?? frame.width;
    final h = core?.$4 ?? frame.height;
    final scale = frame.diag / 2500;
    final size = math.max(1, _jsRoundI(scale * 1.5));
    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      final gy = (y0 + y) ~/ size;
      for (var x = 0; x < w; x++) {
        final gx = (x0 + x) ~/ size;
        final n = grainHash(gx, gy);
        final q = (n * 65536).floor().clamp(0, 65535);
        final o = (y * w + x) * 4;
        rgba[o] = q >> 8;
        rgba[o + 1] = q & 255;
        rgba[o + 3] = 255;
      }
    }
    return imageFromRgba(rgba, w, h);
  }

  /// Original-pixel bounding box of an output rectangle (plus a little for bilinear)
  ui.Rect _footprint(Affine a, int x0, int y0, int x1, int y1) {
    final corners = [
      a.apply(x0.toDouble(), y0.toDouble()),
      a.apply(x1.toDouble(), y0.toDouble()),
      a.apply(x0.toDouble(), y1.toDouble()),
      a.apply(x1.toDouble(), y1.toDouble()),
    ];
    final xs = corners.map((c) => c.$1);
    final ys = corners.map((c) => c.$2);
    return ui.Rect.fromLTRB(
      xs.reduce(math.min) - 2,
      ys.reduce(math.min) - 2,
      xs.reduce(math.max) + 2,
      ys.reduce(math.max) + 2,
    );
  }

  /// A copy of [source] with at most [pixels] pixels (for the field pass)
  Future<GpuSource> _downscaled(GpuSource source, double pixels) async {
    final scale = math.min(1.0, math.sqrt(pixels / (source.width * source.height)));
    final w = math.max(1, (source.width * scale).round());
    final h = math.max(1, (source.height * scale).round());
    final region = await source.region(ui.Rect.fromLTWH(0, 0, source.width, source.height));
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    final src = region.image;
    canvas.drawImageRect(
      src,
      ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
      ui.Rect.fromLTWH(
        -region.originX * scale,
        -region.originY * scale,
        src.width / region.scaleX * scale,
        src.height / region.scaleY * scale,
      ),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = rec.endRecording();
    final image = picture.toImageSync(w, h, targetFormat: caps.stateFormat);
    picture.dispose();
    return GpuImageSource(image, originalWidth: source.width, originalHeight: source.height, renderTarget: true);
  }

  /// Renders [recipe] for display: the whole image, at most [maxPixels]. With [toneOnly]
  /// the geometry is ignored (the crop tab draws rotation and crop itself).
  /// [floatOutput] returns the clamped float result instead of dithered 8-bit (tests).
  Future<ui.Image> preview(
    GpuSource source,
    Recipe recipe, {
    GpuMasks? masks,
    bool toneOnly = false,
    double maxPixels = double.infinity,
    bool floatOutput = false,
  }) async {
    await prepare(recipe);
    return _renderPreview(
      source,
      recipe,
      masks: masks,
      toneOnly: toneOnly,
      maxPixels: maxPixels,
      floatOutput: floatOutput,
    );
  }

  /// Full-resolution render as RGBA bytes. [proxy] is a small copy of the source used for
  /// the smooth fields (made from [source] when null).
  Future<(Uint8List, int, int)> full(
    GpuSource source,
    Recipe recipe, {
    GpuMasks? masks,
    GpuSource? proxy,
    double maxPixels = double.infinity,
    void Function(double progress)? onProgress,
    bool floatOutput = false,
  }) async {
    await prepare(recipe);
    return _renderFull(
      source,
      recipe,
      masks: masks,
      proxy: proxy,
      maxPixels: maxPixels,
      onProgress: onProgress,
      floatOutput: floatOutput,
    );
  }
}

Affine _scaleAffine(Affine a, double kx, double ky) =>
    Affine(a.a * kx, a.b * kx, a.c * kx, a.d * ky, a.e * ky, a.f * ky);

/// The grain hash of advanced.js for cell (gx, gy), in [0, 1)
double grainHash(int gx, int gy) {
  var h = (gx * 374761393 + gy * 668265263).toSigned(32);
  h = imul(h ^ ((h & 0xFFFFFFFF) >> 13), 1274126177);
  return ((h ^ ((h & 0xFFFFFFFF) >> 16)) & 0xFFFFFFFF) / 4294967296;
}

List<double> _hslToRgb(double h, double s, double l) {
  if (s == 0) {
    return [l, l, l];
  }
  final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  final p = 2 * l - q;
  double f(double t0) {
    final t = t0 - t0.floorToDouble();
    if (t < 1 / 6) {
      return p + (q - p) * 6 * t;
    }
    if (t < 1 / 2) {
      return q;
    }
    if (t < 2 / 3) {
      return p + (q - p) * (2 / 3 - t) * 6;
    }
    return p;
  }

  final hh = h / 360;
  return [f(hh + 1 / 3), f(hh), f(hh - 1 / 3)];
}

void _setVec2(ui.FragmentShader s, String name, double x, double y) {
  try {
    s.getUniformVec2(name).set(x, y);
  } catch (_) {
    // optimised away by the shader compiler
  }
}

void _setVec3(ui.FragmentShader s, String name, double x, double y, double z) {
  try {
    s.getUniformVec3(name).set(x, y, z);
  } catch (_) {
    // optimised away by the shader compiler
  }
}

void _setVec4(ui.FragmentShader s, String name, double x, double y, double z, double w) {
  try {
    s.getUniformVec4(name).set(x, y, z, w);
  } catch (_) {
    // optimised away by the shader compiler
  }
}

/// Decodes encoded image bytes into a GPU source (at most [maxPixels])
Future<GpuImageSource> decodeSource(Uint8List bytes, {double? maxPixels}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final w = descriptor.width;
  final h = descriptor.height;
  int? tw;
  int? th;
  if (maxPixels != null && w * h > maxPixels) {
    final s = math.sqrt(maxPixels / (w * h));
    tw = math.max(1, (w * s).round());
    th = math.max(1, (h * s).round());
  }
  final codec = await descriptor.instantiateCodec(targetWidth: tw, targetHeight: th);
  final frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return GpuImageSource(frame.image, originalWidth: w.toDouble(), originalHeight: h.toDouble());
}
