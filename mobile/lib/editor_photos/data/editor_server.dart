// Client for the editor.photos server's mobile API. The server lives next to Immich:
// the Immich host prefixed with `editor.` (photos.example.com → editor.photos.example.com).
// Every call carries the app's own Immich access token as a bearer token; the server
// checks it against Immich.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/editor_photos/model/js_compat.dart';
import 'package:immich_mobile/editor_photos/render/cpu_image.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';

/// `https://photos.example.com/api` → `https://editor.photos.example.com`
Uri? editorServerFor(String? immichEndpoint) {
  if (immichEndpoint == null || immichEndpoint.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(immichEndpoint);
  if (uri == null || uri.host.isEmpty) {
    return null;
  }
  final ip = RegExp(r'^[\d.]+$|:').hasMatch(uri.host);
  if (ip || uri.host == 'localhost') {
    return null;
  }
  return Uri(scheme: uri.scheme, host: 'editor.${uri.host}', port: uri.hasPort ? uri.port : null);
}

class EditorServerException implements Exception {
  final int status;
  final String message;

  const EditorServerException(this.status, this.message);

  @override
  String toString() => 'editor.photos answered $status: $message';
}

/// A suggested edit for one of your photos
class Suggestion {
  final String id;
  final String assetId;
  final String name;
  final String why;
  final String summary;
  final Map<String, Object?> recipe;

  const Suggestion({
    required this.id,
    required this.assetId,
    required this.name,
    required this.why,
    required this.summary,
    required this.recipe,
  });

  factory Suggestion.fromJson(Map<String, Object?> json) => Suggestion(
    id: json['id']! as String,
    assetId: json['assetId']! as String,
    name: (json['name'] as String?) ?? 'Suggestion',
    why: (json['why'] as String?) ?? '',
    summary: (json['summary'] as String?) ?? '',
    recipe: (json['recipe'] as Map?)?.cast<String, Object?>() ?? const {},
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'assetId': assetId,
    'name': name,
    'why': why,
    'summary': summary,
    'recipe': recipe,
  };
}

class SuggestionBatch {
  final String? window;
  final String? text;
  final List<Suggestion> suggestions;

  const SuggestionBatch({this.window, this.text, this.suggestions = const []});

  factory SuggestionBatch.fromJson(Map<String, Object?> json) => SuggestionBatch(
    window: json['window'] as String?,
    text: json['text'] as String?,
    suggestions: [
      for (final s in (json['suggestions'] as List?) ?? const [])
        if (s is Map) Suggestion.fromJson(s.cast<String, Object?>()),
    ],
  );

  Map<String, Object?> toJson() => {
    'window': window,
    'text': text,
    'suggestions': [for (final s in suggestions) s.toJson()],
  };
}

/// What the server knows about a photo's masks: `{width, height, faces, kinds, coverage}`
class MaskInfo {
  final int width;
  final int height;
  final List<FaceBox> faces;
  final List<String> kinds;
  final Map<String, double> coverage;

  const MaskInfo({
    required this.width,
    required this.height,
    required this.faces,
    required this.kinds,
    required this.coverage,
  });

  factory MaskInfo.fromJson(Map<String, Object?> json) => MaskInfo(
    width: toD(json['width']).round(),
    height: toD(json['height']).round(),
    faces: [
      for (final f in (json['faces'] as List?) ?? const [])
        if (f is Map) FaceBox.fromJson(f.cast<String, Object?>()),
    ],
    kinds: [for (final k in (json['kinds'] as List?) ?? const []) k.toString()],
    coverage: {for (final e in ((json['coverage'] as Map?) ?? const {}).entries) e.key.toString(): toD(e.value)},
  );

  double coverageOf(String kind) => coverage[kind] ?? 0;
}

class EditorServer {
  final Uri base;
  final http.Client Function() _client;
  final String? Function() _token;

  EditorServer(this.base, {http.Client Function()? client, String? Function()? token})
    : _client = client ?? (() => NetworkRepository.client),
      _token = token ?? (() => Store.tryGet(StoreKey.accessToken));

  /// The server for the app's current Immich endpoint, or null if none can be derived
  static EditorServer? current() {
    final base = editorServerFor(Store.tryGet(StoreKey.serverEndpoint));
    return base == null ? null : EditorServer(base);
  }

  Uri _uri(String path) => base.replace(path: path);

  Future<http.Response> _send(String method, String path, {Object? body, Duration? timeout}) async {
    final request = http.Request(method, _uri(path));
    final token = _token();
    if (token != null) {
      request.headers['authorization'] = 'Bearer $token';
    }
    request.headers['accept'] = 'application/json, image/*';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final future = _client().send(request).then(http.Response.fromStream);
    return timeout == null ? future : future.timeout(timeout);
  }

  Future<Object?> _json(String method, String path, {Object? body}) async {
    final response = await _send(method, path, body: body, timeout: const Duration(seconds: 30));
    if (response.statusCode >= 400) {
      throw EditorServerException(response.statusCode, response.body);
    }
    return response.body.isEmpty ? null : jsonDecode(response.body);
  }

  /// True when the server answers `{"service":"editor-photos","apiVersion":1}`
  Future<bool> probe() async {
    try {
      final response = await _send('GET', '/api/mobile/info', timeout: const Duration(seconds: 8));
      if (response.statusCode != 200) {
        return false;
      }
      final json = jsonDecode(response.body);
      return json is Map && json['service'] == 'editor-photos' && json['apiVersion'] == 1;
    } catch (_) {
      return false;
    }
  }

  Future<SuggestionBatch> suggestions() async {
    final json = await _json('GET', '/api/mobile/suggestions');
    return json is Map ? SuggestionBatch.fromJson(json.cast<String, Object?>()) : const SuggestionBatch();
  }

  /// JPEG preview of a suggestion: [which] is 'before' or 'after'
  Future<Uint8List?> preview(String suggestionId, String which) async {
    final response = await _send(
      'GET',
      '/api/mobile/suggestions/${Uri.encodeComponent(suggestionId)}/$which',
      timeout: const Duration(seconds: 30),
    );
    return response.statusCode == 200 ? response.bodyBytes : null;
  }

  /// [action] is 'applied', 'tweaked' (with the recipe actually saved) or 'dismissed'
  Future<void> feedback(String suggestionId, String action, {Map<String, Object?>? recipe}) => _json(
    'POST',
    '/api/mobile/suggestions/${Uri.encodeComponent(suggestionId)}/feedback',
    body: {'action': action, 'recipe': ?recipe},
  );

  Future<MaskInfo> maskInfo(String assetId) async {
    final json = await _json('GET', '/api/mobile/assets/${Uri.encodeComponent(assetId)}/masks');
    return MaskInfo.fromJson((json! as Map).cast<String, Object?>());
  }

  /// Masks for the tools, decoded from the server's 8-bit grayscale PNGs
  Future<EditorMasks> masks(String assetId, MaskInfo info) async {
    final channels = <String, Float32List>{};
    var width = info.width;
    var height = info.height;
    for (final kind in info.kinds.where((k) => const {'sky', 'subject', 'depth'}.contains(k))) {
      final response = await _send(
        'GET',
        '/api/mobile/assets/${Uri.encodeComponent(assetId)}/masks/$kind.png',
        timeout: const Duration(seconds: 60),
      );
      if (response.statusCode != 200) {
        continue;
      }
      final (channel, w, h) = await _decodeGray(response.bodyBytes);
      if (channels.isNotEmpty && (w != width || h != height)) {
        continue;
      }
      width = w;
      height = h;
      channels[kind] = channel;
    }
    return EditorMasks(
      width: width,
      height: height,
      sky: channels['sky'],
      subject: channels['subject'],
      depth: channels['depth'],
      faces: info.faces,
    );
  }
}

/// First channel of a decoded image as 0..1 floats
Future<(Float32List, int, int)> _decodeGray(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  codec.dispose();
  final image = frame.image;
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
  final w = image.width;
  final h = image.height;
  image.dispose();
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final out = Float32List(w * h);
  for (var p = 0; p < out.length; p++) {
    out[p] = bytes[p * 4] / 255;
  }
  return (out, w, h);
}
