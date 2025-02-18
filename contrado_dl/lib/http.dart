import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:contrado_dl/common.dart';
import 'package:http/http.dart';

extension BaseRequestExtensions on BaseRequest {
  /// Copies a [BaseRequest], subscribes to the original and forwards its
  /// request body to the new one.
  BaseRequest copyWith({
    Stream<List<int>>? body,
    int? contentLength,
    bool keepContentLength = true,
    bool? followRedirects,
    Map<String, String>? headers,
    Map<String, String>? extraHeaders,
    int? maxRedirects,
    bool? persistentConnection,
  }) {
    final request = StreamedRequest(method, url)
      ..contentLength =
          contentLength ?? (keepContentLength ? this.contentLength : null)
      ..followRedirects = followRedirects ?? this.followRedirects
      ..headers.addAll(headers ?? this.headers)
      ..maxRedirects = maxRedirects ?? this.maxRedirects
      ..persistentConnection =
          persistentConnection ?? this.persistentConnection;

    if (extraHeaders != null) {
      request.headers.addAll(extraHeaders);
    }

    // Assume the caller is responsible for draining the request if a body is
    // provided. We can't copy the internal StreamController of StreamedRequest,
    // so just finalize the original and pipe data to the new one.
    (body ?? finalize()).listen(
      request.sink.add,
      onError: request.sink.addError,
      onDone: request.sink.close,
      cancelOnError: true,
    );

    return request;
  }
}

extension StreamedResponseExtensions on StreamedResponse {
  StreamedResponse copyWith({
    Stream<List<int>>? stream,
    int? statusCode,
    int? contentLength,
    bool keepContentLength = true,
    BaseRequest? request,
    bool keepRequest = true,
    Map<String, String>? headers,
    Map<String, String>? extraHeaders,
    bool keepHeaders = true,
    bool? isRedirect,
    bool keepIsRedirect = true,
    bool? persistentConnection,
    bool keepPersistentConnection = true,
    String? reasonPhrase,
    bool keepReasonPhrase = true,
  }) {
    return StreamedResponse(
      stream ?? this.stream,
      statusCode ?? this.statusCode,
      contentLength:
          contentLength ?? (keepContentLength ? this.contentLength : null),
      request: request ?? (keepRequest ? this.request : null),
      headers: {
        ...headers ?? (keepHeaders ? this.headers : const {}),
        if (extraHeaders != null) ...extraHeaders,
      },
      isRedirect: isRedirect ?? (keepIsRedirect && this.isRedirect),
      persistentConnection: persistentConnection ??
          (!keepPersistentConnection || this.persistentConnection),
      reasonPhrase:
          reasonPhrase ?? (keepReasonPhrase ? this.reasonPhrase : null),
    );
  }
}

/// Copies [BaseRequest]s, useful for implementing custom HTTP clients /
/// interceptors.
///
/// This is required because request body streams are single-subscription, to
/// copy request body streams we use a [StreamSplitter], this splitter
/// guarantees each resulting stream receives the same events as the original.
///
/// After the last call to [copyRequest] you should also call [close], this
/// prevents the entire request body from buffering in memory.
abstract class RequestCopier {
  factory RequestCopier({
    required BaseRequest original,
  }) = _RequestCopierImpl;

  const RequestCopier._();

  /// Returns an optionally modified copy of the request that can be sent to
  /// other clients, inspected, or retried.
  BaseRequest copyRequest({
    int? contentLength,
    bool? followRedirects,
    Map<String, String>? headers,
    int? maxRedirects,
    bool? persistentConnection,
  });

  /// Similar to [copyRequest] but only copies the request body.
  Stream<List<int>> copyRequestBody();

  /// Closes this request copier, signalling that there will be no more calls to
  /// [copyRequest] or [copyRequestBody].
  void close();
}

class _Sentinel {
  const _Sentinel();
}

const _sentinel = _Sentinel();

class _RequestCopierImpl extends RequestCopier {
  _RequestCopierImpl({required this.original})
      : splitter = StreamSplitter(original.finalize()),
        super._();

  final BaseRequest original;
  final StreamSplitter<List<int>> splitter;

  @override
  BaseRequest copyRequest({
    Object? contentLength = _sentinel,
    bool? followRedirects,
    Map<String, String>? headers,
    int? maxRedirects,
    bool? persistentConnection,
  }) {
    final request = StreamedRequest(original.method, original.url)
      ..contentLength = contentLength == _sentinel
          ? original.contentLength
          : contentLength as int?
      ..followRedirects = followRedirects ?? original.followRedirects
      ..headers.addAll(headers ?? original.headers)
      ..maxRedirects = maxRedirects ?? original.maxRedirects
      ..persistentConnection =
          persistentConnection ?? original.persistentConnection;

    copyRequestBody().listen(
      request.sink.add,
      onError: request.sink.addError,
      onDone: request.sink.close,
      cancelOnError: true,
    );

    return request;
  }

  @override
  Stream<List<int>> copyRequestBody() {
    return splitter.split();
  }

  @override
  void close() {
    splitter.close();
  }
}

class HttpException implements Exception {
  const HttpException({
    this.uri,
    required this.statusCode,
    required this.body,
  });

  factory HttpException.fromResponse(BaseResponse response) {
    // package:http responses are either a Response (body is known) or
    // StreamedResponse (body is streamed asynchronously), we can't read the
    // response body from a StreamedResponse because something else is probably
    // already listening to it.
    final body = response is Response ? response.body : '';
    return HttpException(
      uri: response.request?.url,
      statusCode: response.statusCode,
      body: body.isEmpty ? null : body,
    );
  }

  static void ensureSuccess(BaseResponse response) {
    if (response.statusCode ~/ 100 != 2) {
      throw HttpException.fromResponse(response);
    }
  }

  final Uri? uri;
  final int statusCode;
  final String? body;

  static String _tryPrettifyJson(String body) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
    } catch (exception) {
      return body;
    }
  }

  @override
  String toString() {
    return 'HttpException: Error $statusCode${uri == null ? '' : ' from $uri'}'
        '${body == null ? '' : ':\n${_tryPrettifyJson(body!)}'}';
  }
}

class AllowIncompleteClient extends BaseClient {
  AllowIncompleteClient({required this.innerClient});

  final Client innerClient;

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    final response = await innerClient.send(request);
    return response.copyWith(
      stream: response.stream.handleError((Object e) {
        if (e is ClientException &&
            e.message == 'Connection closed while receiving data') {
          stderr.writeln('Connection closed prematurely, ignoring');
          return;
        }
        // `e` is opaque so we don't want to assume it's an Exception or
        // an Error.
        // ignore: only_throw_errors
        throw e;
      }),
    );
  }
}

extension UriExtensions on Uri {
  Uri append({
    String path = '',
    Map<String, Object?> queryParameters = const <String, Object?>{},
    String? fragment,
  }) {
    final strQueryParameters = <String, Object>{
      for (final entry in queryParameters.entries)
        if (entry.value is Iterable)
          entry.key: (entry.value as Iterable).map((Object? e) => e.toString())
        else
          entry.key: '${entry.value}',
    };
    return Uri(
      scheme: scheme,
      userInfo: userInfo,
      host: host,
      port: port,
      pathSegments: [
        ...pathSegments,
        ...path.split('/'),
      ],
      queryParameters: strQueryParameters.isEmpty ? null : strQueryParameters,
      fragment: fragment,
    );
  }
}

final httpCacheDir = cacheDir.childDirectory('http');

final client = CachingHttpClient(Client(), httpCacheDir);

class CachingHttpClient extends BaseClient {
  CachingHttpClient(this.baseClient, this.directory);

  final Client baseClient;
  final Directory directory;

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    if (request.method != 'GET') {
      return baseClient.send(request);
    }
    final bodyFile = httpCacheDir.childFile('${request.url.hashCode}.dat');
    final jsonFile = httpCacheDir.childFile('${request.url.hashCode}.json');

    if (jsonFile.existsSync() && bodyFile.existsSync()) {
      print('HIT: ${request.url}');
      final data = json.decode(jsonFile.readAsStringSync());
      return StreamedResponse(
        bodyFile.openRead(),
        data['statusCode'] as int,
        contentLength: data['contentLength'] as int?,
        request: request,
        headers:
            (data['headers'] as Map<String, dynamic>).cast<String, String>(),
        reasonPhrase: data['reasonPhrase'] as String?,
      );
    }

    print('MISS: ${request.url}');
    final response = await baseClient.send(request);

    if (!httpCacheDir.existsSync()) {
      httpCacheDir.createSync(recursive: true);
    }
    final bodySink = bodyFile.openWrite();
    final splitter = StreamSplitter(response.stream);
    splitter.split().listen(
      bodySink.add,
      onError: bodySink.addError,
      onDone: () {
        bodySink.close();
        jsonFile.writeAsStringSync(jsonEncode({
          'statusCode': response.statusCode,
          'contentLength': response.contentLength,
          'headers': response.headers,
          'reasonPhrase': response.reasonPhrase,
        }));
      },
      cancelOnError: true,
    );
    final responseStream = splitter.split();
    splitter.close();
    return response.copyWith(
      stream: responseStream,
    );
  }
}
