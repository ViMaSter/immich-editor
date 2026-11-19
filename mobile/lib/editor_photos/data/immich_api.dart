// The few Immich API calls the editor needs (versions, metadata, stacks, upload), sent
// through the app's authenticated HTTP client (the native client adds the session).
// Raw JSON instead of the generated DTOs: recipes in metadata contain nulls and nested
// lists that the generated `Map<String, Object>` models do not round-trip.
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';

class ImmichApiException implements Exception {
  final int status;
  final String message;

  const ImmichApiException(this.status, this.message);

  @override
  String toString() => 'Immich answered $status: $message';
}

typedef Json = Map<String, Object?>;

class ImmichApi {
  final http.Client Function() _client;
  final String Function() _endpoint;

  ImmichApi({http.Client Function()? client, String Function()? endpoint})
    : _client = client ?? (() => NetworkRepository.client),
      _endpoint = endpoint ?? (() => Store.get(StoreKey.serverEndpoint));

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = _endpoint().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  Future<http.Response> _send(String method, String path, {Object? body, Map<String, String>? query}) async {
    final request = http.Request(method, _uri(path, query));
    request.headers['accept'] = 'application/json';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final streamed = await _client().send(request);
    return http.Response.fromStream(streamed);
  }

  Future<Object?> _json(String method, String path, {Object? body, Map<String, String>? query}) async {
    final response = await _send(method, path, body: body, query: query);
    if (response.statusCode >= 400) {
      throw ImmichApiException(response.statusCode, response.body);
    }
    if (response.body.isEmpty) {
      return null;
    }
    return jsonDecode(response.body);
  }

  String _id(String id) => Uri.encodeComponent(id);

  Future<Json> asset(String id) async => (await _json('GET', '/assets/${_id(id)}'))! as Json;

  /// Metadata of an asset as key → value
  Future<Map<String, Object?>> metadata(String id) async {
    final items = await _json('GET', '/assets/${_id(id)}/metadata');
    return {
      if (items is List)
        for (final item in items.whereType<Map>()) item['key'] as String: item['value'],
    };
  }

  Future<void> setMetadata(String id, String key, Object? value) => _json(
    'PUT',
    '/assets/${_id(id)}/metadata',
    body: {
      'items': [
        {'key': key, 'value': value},
      ],
    },
  );

  Future<void> deleteMetadata(String id, String key) async {
    final response = await _send('DELETE', '/assets/${_id(id)}/metadata/${_id(key)}');
    if (response.statusCode >= 400 && response.statusCode != 400 && response.statusCode != 404) {
      throw ImmichApiException(response.statusCode, response.body);
    }
  }

  Future<Json> stack(String id) async => (await _json('GET', '/stacks/${_id(id)}'))! as Json;

  /// The first asset becomes the primary; an existing stack whose primary is listed merges in
  Future<Json?> createStack(List<String> assetIds) async =>
      await _json('POST', '/stacks', body: {'assetIds': assetIds}) as Json?;

  Future<void> setStackPrimary(String stackId, String primaryAssetId) =>
      _json('PUT', '/stacks/${_id(stackId)}', body: {'primaryAssetId': primaryAssetId});

  Future<void> deleteStack(String stackId) async {
    final response = await _send('DELETE', '/stacks/${_id(stackId)}');
    if (response.statusCode >= 400 && response.statusCode != 404) {
      throw ImmichApiException(response.statusCode, response.body);
    }
  }

  Future<void> removeFromStack(String stackId, String assetId) async {
    final response = await _send('DELETE', '/stacks/${_id(stackId)}/assets/${_id(assetId)}');
    if (response.statusCode >= 400 && response.statusCode != 404) {
      throw ImmichApiException(response.statusCode, response.body);
    }
  }

  Future<Uint8List> _bytes(String path, [Map<String, String>? query]) async {
    final request = http.Request('GET', _uri(path, query))..headers['accept'] = '*/*';
    final response = await http.Response.fromStream(await _client().send(request));
    if (response.statusCode >= 400) {
      throw ImmichApiException(response.statusCode, 'download failed');
    }
    return response.bodyBytes;
  }

  /// The original file (JPEG, HEIC, DNG, …)
  Future<Uint8List> original(String id) => _bytes('/assets/${_id(id)}/original');

  /// Immich's derivatives: 'thumbnail', 'preview' (~1440 px JPEG/WebP), 'fullsize'
  Future<Uint8List> thumbnail(String id, String size) => _bytes('/assets/${_id(id)}/thumbnail', {'size': size});

  String thumbnailUrl(String id, {String size = 'thumbnail'}) =>
      _uri('/assets/${_id(id)}/thumbnail', {'size': size}).toString();

  /// Multipart upload; the filename field precedes the file part (http.MultipartRequest
  /// always writes fields before files) so Immich checks the right extension
  Future<Json> upload({
    required Uint8List bytes,
    required String filename,
    required String fileCreatedAt,
    required String fileModifiedAt,
    List<Json>? metadata,
    String contentType = 'image/jpeg',
  }) async {
    final request = http.MultipartRequest('POST', _uri('/assets'))
      ..headers['accept'] = 'application/json'
      ..fields['filename'] = filename
      ..fields['fileCreatedAt'] = fileCreatedAt
      ..fields['fileModifiedAt'] = fileModifiedAt;
    if (metadata != null) {
      request.fields['metadata'] = jsonEncode(metadata);
    }
    request.files.add(http.MultipartFile.fromBytes('assetData', bytes, filename: filename));
    final response = await http.Response.fromStream(await _client().send(request));
    if (response.statusCode >= 400) {
      throw ImmichApiException(response.statusCode, response.body);
    }
    return jsonDecode(response.body) as Json;
  }

  Future<void> updateAsset(String id, Json fields) => _json('PUT', '/assets/${_id(id)}', body: fields);

  Future<void> copyAsset(Json body) => _json('PUT', '/assets/copy', body: body);

  /// Moves assets to Immich's trash (recoverable); never force-deletes
  Future<void> trash(List<String> ids) => _json('DELETE', '/assets', body: {'ids': ids, 'force': false});
}
