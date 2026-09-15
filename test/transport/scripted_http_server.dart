/// Scripted `HttpServer` for transport tests: real bytes, not a fake client.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One recorded inbound HTTP request.
final class RecordedRequest {
  /// Creates a snapshot of one request.
  const RecordedRequest({
    required this.method,
    required this.path,
    required this.query,
    required this.authorization,
    required this.ulsyncOrigin,
    required this.body,
    required this.receivedAt,
  });

  /// HTTP method, upper case (`GET`, `POST`).
  final String method;

  /// Path without query, for example `/v1/sync/push`.
  final String path;

  /// Query parameters as sent.
  final Map<String, String> query;

  /// Raw `Authorization` header, or `null` if omitted.
  final String? authorization;

  /// Raw `Ulsync-Origin` header, or `null` if omitted.
  final String? ulsyncOrigin;

  /// UTF-8 body; empty for GET.
  final String body;

  /// Wall-clock time when the server accepted the request.
  final DateTime receivedAt;
}

/// One canned reply, selected by connection index.
final class ScriptedReply {
  /// JSON response with [status] and [body].
  const ScriptedReply.json({
    required this.status,
    required this.body,
    this.headers = const {},
    this.path,
  }) : chunks = const [],
       closeAfter = null,
       holdOpen = false,
       drop = false,
       sse = false;

  /// Server-Sent Events: write [chunks], then optionally hold or close.
  const ScriptedReply.sse({
    this.chunks = const [],
    this.closeAfter,
    this.holdOpen = false,
    this.path,
  }) : status = 200,
       body = '',
       headers = const {},
       drop = false,
       sse = true;

  /// Destroy the socket before an HTTP response. Client sees a network error.
  const ScriptedReply.drop({this.path})
    : status = 0,
      body = '',
      headers = const {},
      chunks = const [],
      closeAfter = null,
      holdOpen = false,
      drop = true,
      sse = false;

  /// HTTP status for JSON replies; 200 for SSE.
  final int status;

  /// JSON body. Ignored for SSE and drop.
  final String body;

  /// Extra JSON response headers.
  final Map<String, String> headers;

  /// SSE chunks written as-is (caller includes newlines).
  final List<String> chunks;

  /// After writing [chunks], wait this long then close. Ignored if [holdOpen].
  final Duration? closeAfter;

  /// Keep the response open until the client disconnects or the server closes.
  final bool holdOpen;

  /// When true, no HTTP response is written.
  final bool drop;

  /// When true, the reply is `text/event-stream`, even with an empty body.
  final bool sse;

  /// When set, this reply is used only for that request path and does not
  /// consume the sequential queue. `GET /v1/sync/hello` without a matching
  /// reply is `404`, so existing push/pull scripts keep working against a
  /// current client that always hellos first (old-server behaviour).
  final String? path;

  /// Writes this reply onto [request].
  Future<void> apply(HttpRequest request) async {
    if (drop) {
      final socket = await request.response.detachSocket();
      socket.destroy();
      return;
    }

    if (sse) {
      request.response.statusCode = 200;
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        'text/event-stream',
      );
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.bufferOutput = false;
      for (final chunk in chunks) {
        request.response.write(chunk);
        try {
          await request.response.flush();
        } catch (_) {
          return;
        }
      }
      if (holdOpen) {
        if (chunks.isEmpty) {
          // Headers are not flushed until a write or detach. Detach so the
          // client sees 200 with an empty body and the socket stays open.
          final socket = await request.response.detachSocket();
          try {
            await socket.done;
          } catch (_) {
          } finally {
            socket.destroy();
          }
          return;
        }
        try {
          await request.response.done;
        } catch (_) {}
        return;
      }
      final wait = closeAfter;
      if (wait != null) {
        await Future<void>.delayed(wait);
      }
      try {
        await request.response.close();
      } catch (_) {}
      return;
    }

    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    for (final entry in headers.entries) {
      request.response.headers.set(entry.key, entry.value);
    }
    request.response.write(body);
    await request.response.close();
  }
}

/// Binds `127.0.0.1:0` and serves [replies] in connection order.
final class ScriptedHttpServer {
  ScriptedHttpServer._(this._server, this._replies);

  final HttpServer _server;
  final List<ScriptedReply> _replies;
  final List<RecordedRequest> _requests = [];
  final Map<int, Completer<void>> _waiters = {};
  final Set<int> _usedReplyIndexes = {};

  /// Origin for `HttpSyncTransport.baseUrl`.
  Uri get baseUrl =>
      Uri(scheme: 'http', host: _server.address.address, port: _server.port);

  /// Requests received so far, in order.
  List<RecordedRequest> get requests => List.unmodifiable(_requests);

  /// Number of HTTP connections accepted.
  int get requestCount => _requests.length;

  /// Binds a loopback server that plays [replies] in order.
  static Future<ScriptedHttpServer> start(List<ScriptedReply> replies) async {
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final scripted = ScriptedHttpServer._(httpServer, replies);
    scripted._listen();
    return scripted;
  }

  /// Completes when at least [count] requests have been accepted.
  Future<void> waitForRequests(
    int count, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (_requests.length >= count) {
      return;
    }
    final completer = _waiters.putIfAbsent(count, Completer<void>.new);
    await completer.future.timeout(timeout);
  }

  /// Closes the listener; in-flight SSE holds are aborted.
  Future<void> close() => _server.close(force: true);

  /// Path-tagged replies first; untagged sequential otherwise.
  ///
  /// Unscripted `GET /v1/sync/hello` is `404` and does not consume push/pull
  /// replies, matching an old server that lacks the endpoint.
  ScriptedReply _pickReply(String path) {
    for (var i = 0; i < _replies.length; i++) {
      if (_usedReplyIndexes.contains(i)) {
        continue;
      }
      if (_replies[i].path == path) {
        _usedReplyIndexes.add(i);
        return _replies[i];
      }
    }
    if (path == '/v1/sync/hello') {
      return const ScriptedReply.json(status: 404, body: 'not found');
    }
    for (var i = 0; i < _replies.length; i++) {
      if (_usedReplyIndexes.contains(i)) {
        continue;
      }
      if (_replies[i].path == null) {
        _usedReplyIndexes.add(i);
        return _replies[i];
      }
    }
    return const ScriptedReply.json(status: 500, body: '{}');
  }

  void _listen() {
    _server.listen((request) {
      unawaited(_handle(request));
    });
  }

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final recorded = RecordedRequest(
      method: request.method,
      path: request.uri.path,
      query: request.uri.queryParameters,
      authorization: request.headers.value(HttpHeaders.authorizationHeader),
      ulsyncOrigin: request.headers.value('Ulsync-Origin'),
      body: body,
      receivedAt: DateTime.now(),
    );
    _requests.add(recorded);
    final waiter = _waiters[_requests.length];
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }

    final reply = _pickReply(request.uri.path);
    try {
      await reply.apply(request);
    } catch (_) {
      // Client abort during SSE is expected.
    }
  }
}
