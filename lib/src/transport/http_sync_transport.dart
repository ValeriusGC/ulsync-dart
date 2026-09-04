/// HTTP implementation of [SyncTransport] with one shared HTTP client.
///
/// Keep-alive needs that single client: a new client per request would
/// handshake TCP and TLS every few minutes. Token is read before every
/// request because the application may have rotated it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../protocol/envelope.dart';
import '../protocol/errors.dart';
import 'exceptions.dart';
import 'live_session.dart';
import 'sync_transport.dart';

/// Deadline for push, pull, and live **headers**.
///
/// 30 seconds covers a slow mobile round trip without waiting for the OS
/// TCP timeout. The live **body** has no deadline; [kSilenceTimeout]
/// watches it instead.
const Duration kPushPullTimeout = Duration(seconds: 30);

/// Silence watchdog for the live body.
///
/// Three times the server `live_heartbeat` of 15 seconds (`ulsync-server`
/// `config.example.yaml`). Carrier NAT closes idle TCP without RST; a
/// server `: ping` that nobody watches leaves the client on a dead pipe.
const Duration kSilenceTimeout = Duration(seconds: 45);

/// First reconnect delay after a dropped live stream.
///
/// The first open does not wait. Only reconnects back off.
const Duration kReconnectInitial = Duration(seconds: 1);

/// Ceiling of the backoff **base** before jitter is added.
///
/// Capping the *total* (base + jitter) at 30s would squeeze jitter to zero
/// at the ceiling and recreate the thundering herd that jitter prevents.
const Duration kReconnectCap = Duration(seconds: 30);

/// A live connection shorter than this does not reset backoff.
///
/// Otherwise a connect-and-drop loop would look like success.
const Duration kStableConnection = Duration(minutes: 1);

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

/// Full jitter on top of a capped base: delay is `[base, 2*base)`, and the
/// base itself never exceeds [kReconnectCap].
///
/// Capping the *total* at 30s would squeeze jitter to zero at the ceiling
/// and recreate the thundering herd the jitter exists to prevent. After a
/// server restart every device would otherwise reconnect in the same
/// millisecond.
Duration addFullJitter(Duration base, Random random) {
  final ms = base.inMilliseconds;
  if (ms <= 0) {
    return Duration.zero;
  }
  return Duration(milliseconds: ms + random.nextInt(ms + 1));
}

/// Backoff base for [failedAttempt] (0 = first reconnect).
///
/// Doubles [initial] until [cap]. The cap applies to the base; jitter is
/// added on top by [addFullJitter].
Duration nextBackoff(int failedAttempt, Duration initial, Duration cap) {
  var ms = initial.inMilliseconds;
  for (var i = 0; i < failedAttempt; i++) {
    ms *= 2;
    if (ms >= cap.inMilliseconds) {
      return cap;
    }
  }
  if (ms > cap.inMilliseconds) {
    return cap;
  }
  return Duration(milliseconds: ms);
}

/// HTTP transport to one ulsync origin.
final class HttpSyncTransport implements SyncTransport {
  /// Creates a transport that talks to [baseUrl].
  ///
  /// [baseUrl] is an origin such as `http://127.0.0.1:8080` or
  /// `http://10.0.2.2:8080`. A path prefix such as `/api` is not supported:
  /// paths are always `/v1/sync/push` and `/v1/sync/pull`.
  ///
  /// [addJitter] defaults to [addFullJitter]. Tests that need order-of-
  /// magnitude delays pass `(base, _) => base` to disable the random addend.
  HttpSyncTransport({
    required this.baseUrl,
    required this.tokenProvider,
    this.pushPullTimeout = kPushPullTimeout,
    this.silenceTimeout = kSilenceTimeout,
    this.reconnectInitial = kReconnectInitial,
    this.reconnectCap = kReconnectCap,
    this.stableConnection = kStableConnection,
    this.reopenBeforeExpiry = kReopenBeforeExpiry,
    this.unreadableExpInterval = kUnreadableExpInterval,
    Random? random,
    Duration Function(Duration base, Random random)? addJitter,
  }) : _random = random ?? Random(),
       _addJitter = addJitter ?? addFullJitter,
       _client = http.Client();

  /// Origin of the sync server; path is ignored.
  final Uri baseUrl;

  /// Called before every HTTP request, including the one 401 retry.
  ///
  /// `null` or a blank string becomes [UlsyncUnauthorized] without a
  /// network call.
  final Future<String?> Function() tokenProvider;

  /// Deadline for push, pull, and live headers. See [kPushPullTimeout].
  final Duration pushPullTimeout;

  /// Live-body silence watchdog. See [kSilenceTimeout].
  final Duration silenceTimeout;

  /// First reconnect delay. See [kReconnectInitial].
  final Duration reconnectInitial;

  /// Backoff base ceiling. See [kReconnectCap].
  final Duration reconnectCap;

  /// Minimum live duration that resets backoff. See [kStableConnection].
  final Duration stableConnection;

  /// How long before JWT `exp` to reopen. See [kReopenBeforeExpiry].
  final Duration reopenBeforeExpiry;

  /// Fallback when `exp` is unreadable. See [kUnreadableExpInterval].
  final Duration unreadableExpInterval;

  /// Random source for jitter; injectable so tests can pass a seeded instance.
  final Random _random;

  /// Jitter function; production uses [addFullJitter].
  final Duration Function(Duration base, Random random) _addJitter;

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
      return request;
    });
    _throwIfHttpError(response);
    return _parsePullPage(response.body);
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
      pushPullTimeout: pushPullTimeout,
      silenceTimeout: silenceTimeout,
      stableConnection: stableConnection,
      reopenBeforeExpiry: reopenBeforeExpiry,
      unreadableExpInterval: unreadableExpInterval,
      backoffDelay: (int failedAttempt) => _addJitter(
        nextBackoff(failedAttempt, reconnectInitial, reconnectCap),
        _random,
      ),
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
}
