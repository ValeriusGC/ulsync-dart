/// Reconnect loop for one live Server-Sent Events subscription.
///
/// Not exported. A dropped TCP connection, a silence-watchdog firing, and
/// a JWT `exp` approaching are handled here so the outward [Stream] of
/// [LiveMessage]s stays open until [stop] or a non-retryable failure.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../protocol/envelope.dart';
import '../protocol/errors.dart';
import '../protocol/sse.dart';
import 'exceptions.dart';
import 'jwt_expiry.dart';
import 'sync_transport.dart';

/// Why the body reader stopped.
enum _BodyEnd {
  /// Server closed the stream or the client cancelled it as a drop.
  dropped,

  /// No byte arrived within the silence timeout.
  silence,

  /// JWT `exp` timer fired; reconnect without backoff.
  exp,

  /// Bytes could not be parsed; outward stream must complete with an error.
  protocol,
}

/// Owns the reconnect loop behind one outward live stream.
final class LiveSession {
  /// Creates a session bound to [_controller].
  LiveSession({
    required this._client,
    required this._liveUri,
    required this._tokenProvider,
    required this._appliedSince,
    required this._controller,
    required this._pushPullTimeout,
    required this._silenceTimeout,
    required this._reopenBeforeExpiry,
    required this._unreadableExpInterval,
    required this._reconnectDelay,
    required this._origin,
    required this._isTransportClosed,
    required this._onStopped,
    this.onConnectionState,
  });

  /// Shared HTTP client; not owned (the transport closes it).
  final http.Client _client;

  /// Builds `GET /v1/sync/pull?since=…&live=sse` from the engine cursor.
  final Uri Function(int since) _liveUri;

  /// Called before every header attempt, including the one 401 retry.
  final Future<String?> Function() _tokenProvider;

  /// Engine callback: applied cursor, never last-seen.
  final int Function() _appliedSince;

  /// Outward stream. Not broadcast; a second listener is a Dart error.
  final StreamController<LiveMessage> _controller;

  /// Timeout for live **headers** only; the body has no overall deadline.
  final Duration _pushPullTimeout;

  /// Watchdog: any body byte resets it. Carrier NAT otherwise holds a
  /// half-open socket that TCP will not notice for minutes.
  final Duration _silenceTimeout;

  /// Reopen this long before JWT `exp`, not after.
  final Duration _reopenBeforeExpiry;

  /// Fallback when `exp` cannot be read: do not spin, do not wait forever.
  final Duration _unreadableExpInterval;

  /// Pause after a failed live try. EventSource: a few seconds, does not grow.
  final Duration _reconnectDelay;

  /// Application-contour origin sent as `Ulsync-Origin` on every live open.
  final String _origin;

  /// True after the transport has been closed.
  final bool Function() _isTransportClosed;

  /// Clears the transport's live slot; must be idempotent.
  final void Function() _onStopped;

  /// Engine callback for drop/restore. `null` in tests that only watch
  /// [LiveMessage]. JWT `exp` reopen does not call this.
  final void Function(LiveConnectionState state)? onConnectionState;

  /// Set by [stop] and by a terminal failure.
  bool _stopped = false;

  /// Completes early when [stop] interrupts a backoff sleep.
  Completer<void>? _sleepGate;

  /// Completes when the current body should be abandoned.
  Completer<_BodyEnd>? _bodyGate;

  /// When true, the next [_waitThenRetry] returns immediately.
  ///
  /// Set by [nudge] so a wake-up does not sit on [kReconnectInterval]
  /// after dropping a stale socket.
  bool _skipBackoff = false;

  /// Live body subscription; cancelled on silence, exp, or [stop].
  StreamSubscription<String>? _bodySubscription;

  /// Fires when no body byte arrives within the silence timeout.
  Timer? _silenceTimer;

  /// Fires at `exp - reopenBefore`, or after the unreadable-exp interval.
  Timer? _expTimer;

  /// Protocol error to deliver on the outward stream, if any.
  Object? _protocolError;

  /// Stack paired with the protocol error.
  StackTrace? _protocolStack;

  /// Runs the reconnect loop until cancelled, closed, or a terminal error.
  Future<void> run() async {
    try {
      await _loop();
    } catch (e, st) {
      if (!_controller.isClosed) {
        _controller.addError(e, st);
      }
    } finally {
      _silenceTimer?.cancel();
      _expTimer?.cancel();
      if (!_controller.isClosed) {
        await _controller.close();
      }
      _onStopped();
    }
  }

  /// Drops the current body or backoff so the loop opens a new socket now.
  ///
  /// Does not set [_stopped]: the reconnect loop keeps running. Emits
  /// [LiveConnectionState.lost] so the engine catch-up runs after the
  /// next 2xx open. No-op after [stop] or transport [close].
  void nudge() {
    if (_halted) {
      return;
    }
    _skipBackoff = true;
    _emitConnection(LiveConnectionState.lost);
    _wakeSleep();
    final bodyGate = _bodyGate;
    if (bodyGate != null && !bodyGate.isCompleted) {
      bodyGate.complete(_BodyEnd.dropped);
    }
    unawaited(_cancelBody());
  }

  /// Aborts HTTP, timers, and backoff sleep. Safe to call more than once.
  Future<void> stop() async {
    _stopped = true;
    _wakeSleep();
    final bodyGate = _bodyGate;
    if (bodyGate != null && !bodyGate.isCompleted) {
      bodyGate.complete(_BodyEnd.dropped);
    }
    _silenceTimer?.cancel();
    _expTimer?.cancel();
    await _cancelBody();
  }

  /// True when the loop must not open another connection.
  bool get _halted => _stopped || _isTransportClosed() || _controller.isClosed;

  Future<void> _loop() async {
    while (!_halted) {
      final token = await _tokenProvider();
      if (_halted) {
        return;
      }
      if (token == null || token.trim().isEmpty) {
        _fail(const UlsyncUnauthorized('Missing or empty bearer token'));
        return;
      }

      var workingToken = token;
      var retried401 = false;

      headerAttempt:
      while (!_halted) {
        final uri = _liveUri(_appliedSince());
        late final http.StreamedResponse streamed;
        try {
          final request = http.Request('GET', uri);
          request.headers['Authorization'] = 'Bearer $workingToken';
          request.headers['Accept'] = 'text/event-stream';
          request.headers['Ulsync-Origin'] = _origin;
          streamed = await _client.send(request).timeout(_pushPullTimeout);
        } on TimeoutException {
          if (_halted) {
            return;
          }
          _emitConnection(LiveConnectionState.lost);
          await _waitThenRetry();
          break headerAttempt;
        } on http.ClientException {
          if (_halted) {
            return;
          }
          _emitConnection(LiveConnectionState.lost);
          await _waitThenRetry();
          break headerAttempt;
        } catch (e) {
          if (_halted) {
            return;
          }
          if (e is UlsyncTransportException || e is UlsyncProtocolException) {
            _fail(e);
            return;
          }
          _emitConnection(LiveConnectionState.lost);
          await _waitThenRetry();
          break headerAttempt;
        }

        final status = streamed.statusCode;
        if (status == 401) {
          if (!retried401) {
            retried401 = true;
            await _drain(streamed);
            final retryToken = await _tokenProvider();
            if (_halted) {
              return;
            }
            if (retryToken == null || retryToken.trim().isEmpty) {
              _fail(const UlsyncUnauthorized('Missing or empty bearer token'));
              return;
            }
            workingToken = retryToken;
            continue headerAttempt;
          }
          final body = await _readBody(streamed);
          _fail(
            UlsyncUnauthorized(
              'Unauthorized',
              statusCode: 401,
              bodySnippet: clipBodySnippet(body),
            ),
          );
          return;
        }

        if (status >= 400 && status < 500) {
          final body = await _readBody(streamed);
          _fail(
            UlsyncRequestRejected(
              'Request rejected',
              statusCode: status,
              bodySnippet: clipBodySnippet(body),
            ),
          );
          return;
        }

        if (status < 200 || status >= 300) {
          await _drain(streamed);
          if (_halted) {
            return;
          }
          _emitConnection(LiveConnectionState.lost);
          await _waitThenRetry();
          break headerAttempt;
        }

        _emitConnection(LiveConnectionState.restored);
        final end = await _consumeBody(streamed, workingToken);
        if (_halted) {
          return;
        }
        switch (end) {
          case _BodyEnd.protocol:
            _fail(
              _protocolError ??
                  const UlsyncProtocolException('Live feed parse failed'),
              _protocolStack,
            );
            return;
          case _BodyEnd.exp:
            // Token is about to expire; open a new stream now.
            break headerAttempt;
          case _BodyEnd.dropped:
          case _BodyEnd.silence:
            if (!_halted) {
              _emitConnection(LiveConnectionState.lost);
            }
            await _waitThenRetry();
            break headerAttempt;
        }
      }
    }
  }

  /// Reads SSE lines until the body ends, silence fires, or `exp` fires.
  Future<_BodyEnd> _consumeBody(
    http.StreamedResponse response,
    String token,
  ) async {
    _protocolError = null;
    _protocolStack = null;
    final ended = Completer<_BodyEnd>();
    _bodyGate = ended;

    void finish(_BodyEnd reason) {
      if (!ended.isCompleted) {
        ended.complete(reason);
      }
      unawaited(_cancelBody());
    }

    void resetSilence() {
      _silenceTimer?.cancel();
      _silenceTimer = Timer(_silenceTimeout, () => finish(_BodyEnd.silence));
    }

    // Any raw byte, including a truncated UTF-8 chunk, proves the pipe is
    // live. Resetting only on a parsed event would miss a slow frame.
    resetSilence();
    _expTimer?.cancel();
    _expTimer = Timer(_reopenDelay(token), () => finish(_BodyEnd.exp));

    final parser = LiveFeedParser();
    final lines = response.stream
        .map((chunk) {
          resetSilence();
          return chunk;
        })
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    final sub = lines.listen(
      (line) {
        try {
          for (final item in parser.addLine(line)) {
            _dispatch(item);
          }
        } catch (e, st) {
          _protocolError = e;
          _protocolStack = st;
          finish(_BodyEnd.protocol);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (error is FormatException) {
          _protocolError = UlsyncProtocolException(
            'Live feed is not valid UTF-8',
          );
          _protocolStack = stack;
          finish(_BodyEnd.protocol);
        } else {
          finish(_BodyEnd.dropped);
        }
      },
      onDone: () => finish(_BodyEnd.dropped),
      cancelOnError: true,
    );
    _bodySubscription = sub;

    try {
      return await ended.future;
    } finally {
      if (identical(_bodyGate, ended)) {
        _bodyGate = null;
      }
      _silenceTimer?.cancel();
      _expTimer?.cancel();
      await _cancelBody();
    }
  }

  /// Maps one parser item onto the outward stream.
  void _dispatch(LiveFeedItem item) {
    if (_controller.isClosed) {
      return;
    }
    switch (item) {
      case LiveFeedHeartbeat():
        _controller.add(const LiveHeartbeat());
      case LiveFeedEvent(:final name, :final data):
        switch (name) {
          case 'envelope':
            _controller.add(LiveEnvelope(_parseEnvelope(data)));
          case 'cursor':
            _controller.add(LiveCursor(_parseCursor(data)));
          default:
            throw UlsyncProtocolException(
              'Unknown live event name: $name',
              field: 'event',
            );
        }
    }
  }

  Envelope _parseEnvelope(String data) {
    return Envelope.fromJson(_decodeObject(data, 'data'));
  }

  int _parseCursor(String data) {
    final map = _decodeObject(data, 'next_cursor');
    final value = map['next_cursor'];
    if (value is! int) {
      throw UlsyncProtocolException(
        'next_cursor must be an integer',
        field: 'next_cursor',
      );
    }
    return value;
  }

  Map<String, Object?> _decodeObject(String text, String field) {
    late final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw UlsyncProtocolException(
        'Live event data is not JSON',
        field: field,
      );
    }
    if (decoded is! Map) {
      throw UlsyncProtocolException(
        'Live event data is not an object',
        field: field,
      );
    }
    return Map<String, Object?>.from(decoded);
  }

  Duration _reopenDelay(String token) {
    return durationUntilReopen(
      exp: readJwtExpiry(token),
      now: DateTime.now().toUtc(),
      reopenBefore: _reopenBeforeExpiry,
      unreadableInterval: _unreadableExpInterval,
    );
  }

  /// EventSource: wait a few seconds, then try again. The wait does not grow.
  Future<void> _waitThenRetry() async {
    if (_halted) {
      return;
    }
    if (_skipBackoff) {
      _skipBackoff = false;
      return;
    }
    await _sleep(_reconnectDelay);
  }

  Future<void> _sleep(Duration delay) async {
    if (_halted || delay <= Duration.zero) {
      return;
    }
    final gate = Completer<void>();
    _sleepGate = gate;
    final timer = Timer(delay, () {
      if (!gate.isCompleted) {
        gate.complete();
      }
    });
    try {
      await gate.future;
    } finally {
      timer.cancel();
      if (identical(_sleepGate, gate)) {
        _sleepGate = null;
      }
    }
  }

  void _wakeSleep() {
    final gate = _sleepGate;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  Future<void> _cancelBody() async {
    final sub = _bodySubscription;
    _bodySubscription = null;
    await sub?.cancel();
  }

  void _fail(Object error, [StackTrace? stack]) {
    _stopped = true;
    if (!_controller.isClosed) {
      _controller.addError(error, stack);
    }
  }

  /// Forwards [state] to the engine. No-op when the callback is unset.
  void _emitConnection(LiveConnectionState state) {
    onConnectionState?.call(state);
  }

  Future<void> _drain(http.StreamedResponse response) async {
    try {
      await response.stream.drain<void>();
    } catch (_) {}
  }

  Future<String> _readBody(http.StreamedResponse response) async {
    try {
      return await response.stream.bytesToString();
    } catch (_) {
      return '';
    }
  }
}
