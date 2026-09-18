/// HTTP implementation of [SyncTransport] with one shared HTTP client.
///
/// Keep-alive needs that single client: a new client per request would
/// handshake TCP and TLS every few minutes. Token is read before every
/// request because the application may have rotated it. Kit packing
/// (**indivisible**, **complete** record kits) happens in the engine
/// before [push] and after [pull]; this type posts and parses bytes.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../protocol/envelope.dart';
import '../protocol/errors.dart';
import '../protocol/origin.dart';
import 'exceptions.dart';
import 'live_session.dart';
import 'sync_transport.dart';

/// Deadline for push and pull **headers**.
///
/// 30 seconds covers a slow mobile round trip without waiting for the OS
/// TCP timeout. Live open uses [kReconnectInterval] wait after a failed
/// try; headers themselves use [kLiveHeaderTimeout].
const Duration kPushPullTimeout = Duration(seconds: 30);

/// How long to wait for live **headers** before giving up this try.
///
/// If the server is down, do not sit 30 seconds on one socket. Fail this
/// try and knock again after [kReconnectInterval].
const Duration kLiveHeaderTimeout = Duration(seconds: 5);

/// Pause between live tries when the connection is down.
///
/// Same as EventSource in the browser (WHATWG: a few seconds; Chrome ~3s):
/// first try is immediate; if it fails, wait 3 seconds and try again.
/// The wait does **not** grow.
const Duration kReconnectInterval = Duration(seconds: 3);

/// Silence watchdog for the live body.
///
/// Three times the server `live_heartbeat` of 15 seconds (`ulsync-server`
/// `config.example.yaml`). Carrier NAT closes idle TCP without RST; a
/// server `: ping` that nobody watches leaves the client on a dead pipe.
const Duration kSilenceTimeout = Duration(seconds: 45);

/// Reopen the live feed this long **before** JWT `exp`.
///
/// The server checks the token at stream open and does not tear the socket
/// down at expiry. Reopening after `exp` would leave a silent feed and
/// nothing in the log would look like an error.
const Duration kReopenBeforeExpiry = Duration(seconds: 60);

/// Reopen interval when JWT `exp` cannot be read.
///
/// Immediate reopen would spin; waiting forever would miss rotation.
const Duration kUnreadableExpInterval = Duration(minutes: 30);

/// HTTP transport to one ulsync server URL.
///
/// Sends `Ulsync-Origin` on every `/v1/sync/*` request. The value is the
/// constructor [origin], never minted here.
final class HttpSyncTransport
    implements SyncTransport, SyncDiffTransport, SyncHelloTransport {
  /// Creates a transport that talks to [baseUrl] with [origin].
  ///
  /// [baseUrl] is a server URL such as `http://127.0.0.1:8080` or
  /// `http://10.0.2.2:8080`. A path prefix such as `/api` is not supported:
  /// paths are always `/v1/sync/hello`, `/v1/sync/push`, `/v1/sync/pull`,
  /// and `/v1/sync/diff`. [origin] is the application contour (SPEC
  /// section 1.5), not [baseUrl].
  HttpSyncTransport({
    required this.baseUrl,
    required String origin,
    required this.tokenProvider,
    this.pushPullTimeout = kPushPullTimeout,
    this.liveHeaderTimeout = kLiveHeaderTimeout,
    this.silenceTimeout = kSilenceTimeout,
    this.reconnectInterval = kReconnectInterval,
    this.reopenBeforeExpiry = kReopenBeforeExpiry,
    this.unreadableExpInterval = kUnreadableExpInterval,
  }) : origin = requireUlsyncOrigin(origin),
       _client = http.Client();

  /// Server URL; path is ignored.
  final Uri baseUrl;

  /// Application-contour origin sent as `Ulsync-Origin` on every request.
  final String origin;

  /// Called before every HTTP request, including the one 401 retry.
  ///
  /// `null` or a blank string becomes [UlsyncUnauthorized] without a
  /// network call.
  final Future<String?> Function() tokenProvider;

  /// Deadline for push and pull headers. See [kPushPullTimeout].
  final Duration pushPullTimeout;

  /// Deadline for live open headers. See [kLiveHeaderTimeout].
  final Duration liveHeaderTimeout;

  /// Live-body silence watchdog. See [kSilenceTimeout].
  final Duration silenceTimeout;

  /// Pause between live tries. See [kReconnectInterval].
  final Duration reconnectInterval;

  /// How long before JWT `exp` to reopen. See [kReopenBeforeExpiry].
  final Duration reopenBeforeExpiry;

  /// Fallback when `exp` is unreadable. See [kUnreadableExpInterval].
  final Duration unreadableExpInterval;

  /// One client for the lifetime of this object (HTTP keep-alive).
  final http.Client _client;

  /// Set by [close]; repeated [close] is a no-op.
  bool _closed = false;

  /// Active live session, if any. One at a time.
  LiveSession? _liveSession;

  @override
  Future<List<PushResult>> push(List<Envelope> envelopes) async {
    _ensureOpen();
    final body = jsonEncode({
      'envelopes': envelopes.map((e) => e.toJson()).toList(),
    });
    final response = await _sendWithAuthRetry((token) {
      final request = http.Request('POST', _pushUri());
      request.headers['Authorization'] = 'Bearer $token';
      request.headers['Content-Type'] = 'application/json';
      request.headers['Accept'] = 'application/json';
      request.headers['Ulsync-Origin'] = origin;
      request.body = body;
      return request;
    });
    _throwIfHttpError(response);
    return _parsePushResults(response.body);
  }

  @override
  Future<PullPage> pull({required int since, int? limit}) async {
    _ensureOpen();
    final query = <String, String>{'since': '$since'};
    if (limit != null) {
      query['limit'] = '$limit';
    }
    final response = await _sendWithAuthRetry((token) {
      final request = http.Request('GET', _pullUri(query));
      request.headers['Authorization'] = 'Bearer $token';
      request.headers['Accept'] = 'application/json';
      request.headers['Ulsync-Origin'] = origin;
      return request;
    });
    _throwIfHttpError(response);
    return _parsePullPage(response.body);
  }

  /// POSTs `/v1/sync/diff`. HTTP 404 and 405 mean the route is absent.
  ///
  /// Those two statuses return `null` (check unavailable). Any other
  /// non-success is an exception, the same policy as [push] and [pull]. An
  /// empty [probes] list is not sent: SPEC section 3.4 rejects empty `items`
  /// with 400, and «nothing to report» is an empty result list instead.
  @override
  Future<List<DiffVerdict>?> diff(List<DiffProbe> probes) async {
    _ensureOpen();
    if (probes.isEmpty) {
      return const [];
    }
    final body = jsonEncode({'items': probes.map((p) => p.toJson()).toList()});
    final response = await _sendWithAuthRetry((token) {
      final request = http.Request('POST', _diffUri());
      request.headers['Authorization'] = 'Bearer $token';
      request.headers['Content-Type'] = 'application/json';
      request.headers['Accept'] = 'application/json';
      request.headers['Ulsync-Origin'] = origin;
      request.body = body;
      return request;
    });
    final status = response.statusCode;
    if (status == 404 || status == 405) {
      return null;
    }
    _throwIfHttpError(response);
    return _parseDiffVerdicts(response.body);
  }

  /// GETs `/v1/sync/hello`. HTTP 404 and 405 mean the endpoint is absent.
  ///
  /// Null is «unavailable», not a mismatch: an old server cannot refuse a
  /// foreign application. HTTP `409` is [OriginMismatchException] with both
  /// origins from the body. Other failures match [push] and [pull].
  @override
  Future<HelloResult?> hello(String origin) async {
    _ensureOpen();
    final response = await _sendWithAuthRetry((token) {
      final request = http.Request('GET', _helloUri());
      request.headers['Authorization'] = 'Bearer $token';
      request.headers['Accept'] = 'application/json';
      request.headers['Ulsync-Origin'] = origin;
      return request;
    });
    final status = response.statusCode;
    if (status == 404 || status == 405) {
      return null;
    }
    if (status == 409) {
      throw _parseOriginMismatch(response.body);
    }
    _throwIfHttpError(response);
    return HelloResult.fromJson(_decodeObject(response.body, 'origin'));
  }

  /// Opens the live SSE feed.
  ///
  /// Only one live stream at a time; a second call throws [StateError]
  /// until the first subscription is cancelled. A dropped TCP connection
  /// does not complete the returned stream.
  @override
  Stream<LiveMessage> live({
    required int Function() appliedSince,
    void Function(LiveConnectionState state)? onConnectionState,
  }) {
    _ensureOpen();
    if (_liveSession != null) {
      throw StateError('HttpSyncTransport already has a live stream');
    }
    late final LiveSession session;
    final controller = StreamController<LiveMessage>(
      onListen: () {
        unawaited(session.run());
      },
      onCancel: () async {
        await session.stop();
      },
    );
    session = LiveSession(
      client: _client,
      liveUri: (int since) => _pullUri({'since': '$since', 'live': 'sse'}),
      tokenProvider: tokenProvider,
      appliedSince: appliedSince,
      controller: controller,
      pushPullTimeout: liveHeaderTimeout,
      silenceTimeout: silenceTimeout,
      reopenBeforeExpiry: reopenBeforeExpiry,
      unreadableExpInterval: unreadableExpInterval,
      reconnectDelay: reconnectInterval,
      origin: origin,
      isTransportClosed: () => _closed,
      onStopped: () {
        if (identical(_liveSession, session)) {
          _liveSession = null;
        }
      },
      onConnectionState: onConnectionState,
    );
    _liveSession = session;
    return controller.stream;
  }

  /// Drops the active live body if any. See [SyncTransport.pokeLive].
  @override
  Future<void> pokeLive() async {
    _ensureOpen();
    _liveSession?.nudge();
  }

  /// Cancels the live stream and closes the HTTP client.
  ///
  /// A second call is a no-op. Later [push], [pull], or [live] throw
  /// [StateError] with a `closed` message, not a raw client exception.
  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    final session = _liveSession;
    _liveSession = null;
    await session?.stop();
    _client.close();
  }

  /// Throws [StateError] when [close] has already run.
  void _ensureOpen() {
    if (_closed) {
      throw StateError('HttpSyncTransport is closed');
    }
  }

  Uri _pushUri() => baseUrl.replace(path: '/v1/sync/push');

  Uri _pullUri(Map<String, String> query) =>
      baseUrl.replace(path: '/v1/sync/pull', queryParameters: query);

  Uri _diffUri() => baseUrl.replace(path: '/v1/sync/diff');

  Uri _helloUri() => baseUrl.replace(path: '/v1/sync/hello');

  /// Reads a non-empty token or throws [UlsyncUnauthorized] without I/O.
  Future<String> _requireToken() async {
    final token = await tokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const UlsyncUnauthorized('Missing or empty bearer token');
    }
    return token;
  }

  /// Sends [build] once, retries exactly one 401 with a fresh token.
  Future<http.Response> _sendWithAuthRetry(
    http.Request Function(String token) build,
  ) async {
    var retried401 = false;
    while (true) {
      final token = await _requireToken();
      final response = await _sendOnce(build(token));
      if (response.statusCode == 401 && !retried401) {
        retried401 = true;
        continue;
      }
      return response;
    }
  }

  Future<http.Response> _sendOnce(http.Request request) async {
    try {
      final streamed = await _client.send(request).timeout(pushPullTimeout);
      return await http.Response.fromStream(streamed).timeout(pushPullTimeout);
    } on TimeoutException {
      throw UlsyncNetworkException('Timed out talking to $baseUrl');
    } on http.ClientException catch (e) {
      throw UlsyncNetworkException('Connection failed: $e');
    } on UlsyncTransportException {
      rethrow;
    } on UlsyncProtocolException {
      rethrow;
    } on StateError {
      rethrow;
    } catch (e) {
      throw UlsyncNetworkException('Connection failed: $e');
    }
  }

  /// Maps a completed HTTP status onto a typed failure, or returns on 2xx.
  void _throwIfHttpError(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      return;
    }
    final snippet = clipBodySnippet(response.body);
    if (status == 401) {
      throw UlsyncUnauthorized(
        'Unauthorized',
        statusCode: 401,
        bodySnippet: snippet,
      );
    }
    if (status >= 500) {
      throw UlsyncServerException(
        'Server error',
        statusCode: status,
        bodySnippet: snippet,
      );
    }
    if (status >= 400) {
      throw UlsyncRequestRejected(
        'Request rejected',
        statusCode: status,
        bodySnippet: snippet,
      );
    }
    throw UlsyncServerException(
      'Unexpected status',
      statusCode: status,
      bodySnippet: snippet,
    );
  }

  List<PushResult> _parsePushResults(String body) {
    final map = _decodeObject(body, 'results');
    final raw = map['results'];
    if (raw is! List) {
      throw const UlsyncProtocolException(
        'Push response missing results list',
        field: 'results',
      );
    }
    final results = <PushResult>[];
    for (final item in raw) {
      if (item is! Map) {
        throw const UlsyncProtocolException(
          'Push result row is not an object',
          field: 'results',
        );
      }
      final row = Map<String, Object?>.from(item);
      final id = row['id'];
      final part = row['part'];
      final applied = row['applied'];
      if (id is! String) {
        throw const UlsyncProtocolException(
          'Push result id must be a string',
          field: 'id',
        );
      }
      if (part is! String) {
        throw const UlsyncProtocolException(
          'Push result part must be a string',
          field: 'part',
        );
      }
      if (applied is! bool) {
        throw const UlsyncProtocolException(
          'Push result applied must be a boolean',
          field: 'applied',
        );
      }
      results.add(PushResult(id: id, part: part, applied: applied));
    }
    return results;
  }

  PullPage _parsePullPage(String body) {
    final map = _decodeObject(body, 'envelopes');
    final raw = map['envelopes'];
    if (raw == null) {
      throw const UlsyncProtocolException(
        'Pull response missing envelopes',
        field: 'envelopes',
      );
    }
    if (raw is! List) {
      throw const UlsyncProtocolException(
        'Pull envelopes is not a list',
        field: 'envelopes',
      );
    }
    final envelopes = <Envelope>[];
    for (final item in raw) {
      if (item is! Map) {
        throw const UlsyncProtocolException(
          'Pull envelope is not an object',
          field: 'envelopes',
        );
      }
      envelopes.add(Envelope.fromJson(Map<String, Object?>.from(item)));
    }
    final cursor = map['next_cursor'];
    if (cursor is! int) {
      throw const UlsyncProtocolException(
        'next_cursor must be an integer',
        field: 'next_cursor',
      );
    }
    return PullPage(envelopes: envelopes, nextCursor: cursor);
  }

  /// Parses SPEC section 3.4 `missing` and `stale` arrays. Both must be lists,
  /// never omitted and never JSON `null`.
  List<DiffVerdict> _parseDiffVerdicts(String body) {
    final map = _decodeObject(body, 'missing');
    final missing = _requireObjectList(map, 'missing');
    final stale = _requireObjectList(map, 'stale');
    return [
      for (final row in missing) DiffVerdict.fromJson(row, DiffGap.missing),
      for (final row in stale) DiffVerdict.fromJson(row, DiffGap.stale),
    ];
  }

  List<Map<String, Object?>> _requireObjectList(
    Map<String, Object?> map,
    String field,
  ) {
    final raw = map[field];
    if (raw == null) {
      throw UlsyncProtocolException(
        'Diff response missing $field',
        field: field,
      );
    }
    if (raw is! List) {
      throw UlsyncProtocolException('Diff $field is not a list', field: field);
    }
    final rows = <Map<String, Object?>>[];
    for (final item in raw) {
      if (item is! Map) {
        throw UlsyncProtocolException(
          'Diff $field row is not an object',
          field: field,
        );
      }
      rows.add(Map<String, Object?>.from(item));
    }
    return rows;
  }

  Map<String, Object?> _decodeObject(String text, String field) {
    late final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw UlsyncProtocolException('Response is not JSON', field: field);
    }
    if (decoded is! Map) {
      throw UlsyncProtocolException(
        'Response JSON is not an object',
        field: field,
      );
    }
    return Map<String, Object?>.from(decoded);
  }

  /// Parses SPEC section 3.5 `409` `origin_mismatch` body.
  OriginMismatchException _parseOriginMismatch(String body) {
    final map = _decodeObject(body, 'store_origin');
    final store = map['store_origin'];
    final request = map['request_origin'];
    if (store is! String || store.isEmpty) {
      throw const UlsyncProtocolException(
        'Expected non-empty string for field: store_origin',
        field: 'store_origin',
      );
    }
    if (request is! String || request.isEmpty) {
      throw const UlsyncProtocolException(
        'Expected non-empty string for field: request_origin',
        field: 'request_origin',
      );
    }
    return OriginMismatchException(storeOrigin: store, requestOrigin: request);
  }
}
