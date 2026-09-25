import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/sources/data/source_list_fetcher.dart';

/// Adapts the app-wide [DioHttpClient] to the [SourceHttpGet] signature used
/// by [SourceListFetcher].
///
/// * Uses the client's automatic proxy detection: when the core is running the
///   request goes through the tunnel first (`PROXY localhost:mixed-port; DIRECT`), otherwise directly.
/// * Enforces the caller's [Duration] with a [CancelToken] so a hanging mirror
///   cannot keep a socket open beyond the budget.
/// * Never logs response bodies.
SourceHttpGet sourceHttpGetFromDio(DioHttpClient client) {
  return (Uri url, {required Duration timeout}) async {
    final cancelToken = CancelToken();
    final timer = Timer(timeout, () => cancelToken.cancel('timeout'));
    try {
      final response = await client.get<Object?>(url.toString(), cancelToken: cancelToken);
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        throw HttpStatusException(status);
      }
      final data = response.data;
      // Dio decodes `application/json` bodies eagerly; the envelope survives
      // re-serialisation because the signature covers the base64 payload
      // bytes, not the envelope text.
      if (data is String) return data;
      if (data is Map<String, Object?>) return jsonEncode(data);
      if (data is List<int>) return utf8.decode(data);
      throw const FormatException('unexpected response body type');
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout) {
        throw TimeoutException('timeout', timeout);
      }
      final status = e.response?.statusCode;
      if (status != null) throw HttpStatusException(status);
      throw HttpTransportException(e.type.name);
    } finally {
      timer.cancel();
    }
  };
}

class HttpStatusException implements Exception {
  const HttpStatusException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'http $statusCode';
}

class HttpTransportException implements Exception {
  const HttpTransportException(this.kind);

  final String kind;

  @override
  String toString() => 'network error ($kind)';
}
