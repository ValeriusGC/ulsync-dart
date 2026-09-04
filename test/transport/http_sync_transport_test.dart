@TestOn('vm')
/// Transport tests against a real `dart:io` [HttpServer], not a fake client.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync/src/transport/jwt_expiry.dart';
import 'package:ulsync/ulsync.dart';

import 'json_map.dart';
import 'scripted_http_server.dart';

/// Reason when the protocol submodule was not initialized.
const _submoduleHint = 'git submodule update --init';

/// Identity jitter so backoff tests can check order of magnitude.
Duration _noJitter(Duration base, Random _) => base;

String _fixture(String relative) {
  final path = 'protocol/fixtures/$relative';
  expect(File(path).existsSync(), isTrue, reason: _submoduleHint);
  return File(path).readAsStringSync();
}

Envelope _minimalEnvelope() =>
    Envelope.fromJson(decodeJsonMap(_fixture('envelope/minimal.json')));

Map<String, Object?> _pageEnvelope({int serverSeq = 1}) {
  final page = decodeJsonMap(_fixture('pull/response_page.json'));
  final raw = page['envelopes']! as List;
  final map = Map<String, Object?>.from(raw.first as Map);
  map['server_seq'] = serverSeq;
  return map;
}

String _sseEvent(String name, String data) => 'event: $name\ndata: $data\n\n';

String _ssePing() => ': ping\n\n';

String _mintJwt({int? expSeconds}) {
  String encode(String text) =>
      base64Url.encode(utf8.encode(text)).replaceAll('=', '');
  final header = encode('{"alg":"none","typ":"JWT"}');
  final payload = <String, Object?>{'sub': 'alice'};
  if (expSeconds != null) {
    payload['exp'] = expSeconds;
  }
  return '$header.${encode(jsonEncode(payload))}.sig';
}

Future<ScriptedHttpServer> _bind(List<ScriptedReply> replies) async {
  final server = await ScriptedHttpServer.start(replies);
  addTearDown(server.close);
  return server;
}

HttpSyncTransport _transport(
  ScriptedHttpServer server, {
  Future<String?> Function()? tokenProvider,
  Duration? pushPullTimeout,
  Duration? silenceTimeout,
  Duration? reconnectInitial,
  Duration? reconnectCap,
  Duration? stableConnection,
  Duration? reopenBeforeExpiry,
  Duration? unreadableExpInterval,
  Duration Function(Duration base, Random random)? addJitter,
}) {
  final transport = HttpSyncTransport(
    baseUrl: server.baseUrl,
    tokenProvider: tokenProvider ?? () async => 'token',
    pushPullTimeout: pushPullTimeout ?? const Duration(seconds: 5),
    silenceTimeout: silenceTimeout ?? const Duration(seconds: 30),
    reconnectInitial: reconnectInitial ?? const Duration(milliseconds: 20),
    reconnectCap: reconnectCap ?? const Duration(milliseconds: 200),
    stableConnection: stableConnection ?? const Duration(seconds: 30),
    reopenBeforeExpiry: reopenBeforeExpiry ?? const Duration(hours: 1),
    unreadableExpInterval: unreadableExpInterval ?? const Duration(hours: 1),
    addJitter: addJitter ?? _noJitter,
  );
  addTearDown(transport.close);
  return transport;
}

final class _LiveProbe {
  _LiveProbe(this.subscription);

  final StreamSubscription<LiveMessage> subscription;
  final List<LiveMessage> messages = [];
  Object? error;
  var done = false;

  static _LiveProbe listen(Stream<LiveMessage> stream) {
    late final _LiveProbe probe;
    final sub = stream.listen(
      (message) => probe.messages.add(message),
      onError: (Object e, StackTrace _) => probe.error = e,
      onDone: () => probe.done = true,
    );
    probe = _LiveProbe(sub);
    return probe;
  }

  Future<void> waitForMessages(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (messages.length < count) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'timed out waiting for $count live messages, got ${messages.length}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

void main() {
  test(
    'push sends the expected body and returns applied: false without throwing',
    () async {
      final server = await _bind([
        ScriptedReply.json(
          status: 200,
          body: _fixture('push/response_rejected.json'),
        ),
      ]);
      final transport = _transport(server);
      final results = await transport.push([_minimalEnvelope()]);
      expect(results, [isA<PushResult>()]);
      expect(results.single.applied, isFalse);
      expect(results.single.id, _minimalEnvelope().id);
      expect(server.requestCount, 1);
      final recorded = server.requests.single;
      expect(recorded.method, 'POST');
      expect(recorded.path, '/v1/sync/push');
      final body = decodeJsonMap(recorded.body);
      expect(body.containsKey('envelopes'), isTrue);
      final envelopes = body['envelopes']! as List;
      expect(envelopes, hasLength(1));
      final first = Map<String, Object?>.from(envelopes.first as Map);
      expect(first['id'], _minimalEnvelope().id);
      expect(first['part'], 'full');
    },
  );

  test('pull passes since and limit in the query and returns the server '
      'next_cursor on an empty page', () async {
    final server = await _bind([
      const ScriptedReply.json(
        status: 200,
        body: '{"envelopes":[],"next_cursor":42}',
      ),
      ScriptedReply.json(
        status: 200,
        body: _fixture('pull/response_page.json'),
      ),
    ]);
    final transport = _transport(server);
    final empty = await transport.pull(since: 7);
    expect(empty.envelopes, isEmpty);
    expect(empty.nextCursor, 42);
    expect(server.requests[0].query['since'], '7');
    expect(server.requests[0].query.containsKey('limit'), isFalse);

    final page = await transport.pull(since: 0, limit: 10);
    expect(page.envelopes, hasLength(1));
    expect(page.nextCursor, 1);
    expect(server.requests[1].query['since'], '0');
    expect(server.requests[1].query['limit'], '10');
  });

  test(
    'Authorization Bearer is sent and tokenProvider is called on every request',
    () async {
      var calls = 0;
      final tokens = ['first-token', 'second-token'];
      final server = await _bind([
        ScriptedReply.json(
          status: 200,
          body: _fixture('push/response_applied.json'),
        ),
        const ScriptedReply.json(
          status: 200,
          body: '{"envelopes":[],"next_cursor":0}',
        ),
      ]);
      final transport = _transport(
        server,
        tokenProvider: () async => tokens[calls++],
      );
      await transport.push([_minimalEnvelope()]);
      await transport.pull(since: 0);
      expect(calls, 2);
      expect(server.requests[0].authorization, 'Bearer first-token');
      expect(server.requests[1].authorization, 'Bearer second-token');
    },
  );

  test(
    'empty token throws UlsyncUnauthorized without contacting the server',
    () async {
      final server = await _bind(const []);
      final nullTransport = _transport(server, tokenProvider: () async => null);
      await expectLater(
        nullTransport.push([_minimalEnvelope()]),
        throwsA(
          isA<UlsyncUnauthorized>().having(
            (e) => e.statusCode,
            'statusCode',
            isNull,
          ),
        ),
      );
      final blankTransport = _transport(
        server,
        tokenProvider: () async => '  ',
      );
      await expectLater(
        blankTransport.pull(since: 0),
        throwsA(isA<UlsyncUnauthorized>()),
      );
      expect(server.requestCount, 0);
    },
  );

  test('401 is retried once with a fresh token and then succeeds', () async {
    var calls = 0;
    final server = await _bind([
      const ScriptedReply.json(status: 401, body: '{"error":"unauthorized"}'),
      ScriptedReply.json(
        status: 200,
        body: _fixture('push/response_applied.json'),
      ),
    ]);
    final transport = _transport(
      server,
      tokenProvider: () async => calls++ == 0 ? 'stale' : 'fresh',
    );
    final results = await transport.push([_minimalEnvelope()]);
    expect(results.single.applied, isTrue);
    expect(server.requestCount, 2);
    expect(calls, 2);
    expect(server.requests[0].authorization, 'Bearer stale');
    expect(server.requests[1].authorization, 'Bearer fresh');
  });

  test('two consecutive 401 responses throw UlsyncUnauthorized after exactly '
      'two requests', () async {
    var calls = 0;
    final server = await _bind([
      const ScriptedReply.json(status: 401, body: '{"error":"unauthorized"}'),
      const ScriptedReply.json(status: 401, body: '{"error":"unauthorized"}'),
    ]);
    final transport = _transport(
      server,
      tokenProvider: () async {
        calls++;
        return 'tok';
      },
    );
    await expectLater(
      transport.push([_minimalEnvelope()]),
      throwsA(
        isA<UlsyncUnauthorized>().having(
          (e) => e.statusCode,
          'statusCode',
          401,
        ),
      ),
    );
    expect(server.requestCount, 2);
    expect(calls, 2);
  });

  test(
    '500 throws UlsyncServerException, 400 and 413 throw UlsyncRequestRejected, '
    'dropped connection throws UlsyncNetworkException',
    () async {
      final distinctive = 'secret-payload-must-not-appear-in-tostring';
      final server = await _bind([
        const ScriptedReply.json(status: 500, body: '{"error":"boom"}'),
        ScriptedReply.json(status: 400, body: '{"error":"$distinctive"}'),
        const ScriptedReply.json(status: 413, body: '{"error":"too large"}'),
        const ScriptedReply.drop(),
      ]);
      final transport = _transport(server);

      await expectLater(
        transport.pull(since: 0),
        throwsA(
          isA<UlsyncServerException>().having(
            (e) => e.statusCode,
            'statusCode',
            500,
          ),
        ),
      );

      try {
        await transport.pull(since: 0);
        fail('expected 400');
      } on UlsyncRequestRejected catch (e) {
        expect(e.statusCode, 400);
        expect(e.toString(), isNot(contains(distinctive)));
        expect(e.bodySnippet, contains(distinctive));
      }

      await expectLater(
        transport.push([_minimalEnvelope()]),
        throwsA(
          isA<UlsyncRequestRejected>().having(
            (e) => e.statusCode,
            'statusCode',
            413,
          ),
        ),
      );

      await expectLater(
        transport.pull(since: 0),
        throwsA(isA<UlsyncNetworkException>()),
      );
    },
  );

  test('live emits envelope, envelope, then cursor in that order', () async {
    final first = jsonEncode(_pageEnvelope(serverSeq: 1));
    final second = jsonEncode(_pageEnvelope(serverSeq: 2));
    final server = await _bind([
      ScriptedReply.sse(
        chunks: [
          _sseEvent('envelope', first),
          _sseEvent('envelope', second),
          _sseEvent('cursor', '{"next_cursor":2}'),
        ],
        holdOpen: true,
      ),
    ]);
    final transport = _transport(server);
    final probe = _LiveProbe.listen(transport.live(appliedSince: () => 0));
    addTearDown(probe.subscription.cancel);
    await probe.waitForMessages(3);
    expect(probe.messages[0], isA<LiveEnvelope>());
    expect(probe.messages[1], isA<LiveEnvelope>());
    expect(probe.messages[2], isA<LiveCursor>());
    expect((probe.messages[0] as LiveEnvelope).envelope.serverSeq, 1);
    expect((probe.messages[1] as LiveEnvelope).envelope.serverSeq, 2);
    expect((probe.messages[2] as LiveCursor).nextCursor, 2);
  });

  test(
    'live heartbeat from : ping is a LiveHeartbeat and is not an envelope',
    () async {
      final server = await _bind([
        ScriptedReply.sse(chunks: [_ssePing()], holdOpen: true),
      ]);
      final transport = _transport(server);
      final probe = _LiveProbe.listen(transport.live(appliedSince: () => 0));
      addTearDown(probe.subscription.cancel);
      await probe.waitForMessages(1);
      expect(probe.messages.single, isA<LiveHeartbeat>());
      expect(probe.messages.single, isNot(isA<LiveEnvelope>()));
    },
  );

  test(
    'disconnect mid-stream reconnects and the outward stream does not complete',
    () async {
      final first = jsonEncode(_pageEnvelope(serverSeq: 1));
      final after = jsonEncode(_pageEnvelope(serverSeq: 2));
      final server = await _bind([
        ScriptedReply.sse(
          chunks: [
            _sseEvent('envelope', first),
            _sseEvent('cursor', '{"next_cursor":1}'),
          ],
        ),
        ScriptedReply.sse(
          chunks: [_sseEvent('envelope', after)],
          holdOpen: true,
        ),
      ]);
      final transport = _transport(server);
      final probe = _LiveProbe.listen(transport.live(appliedSince: () => 0));
      addTearDown(probe.subscription.cancel);
      await server.waitForRequests(2);
      expect(probe.done, isFalse);
      await probe.waitForMessages(3);
      expect(probe.done, isFalse);
      expect(probe.messages.last, isA<LiveEnvelope>());
      expect((probe.messages.last as LiveEnvelope).envelope.serverSeq, 2);
    },
  );

  test('silence longer than the watchdog timeout reconnects', () async {
    final server = await _bind([
      const ScriptedReply.sse(holdOpen: true),
      const ScriptedReply.sse(holdOpen: true),
    ]);
    final transport = _transport(
      server,
      silenceTimeout: const Duration(milliseconds: 300),
      reconnectInitial: const Duration(milliseconds: 20),
    );
    final probe = _LiveProbe.listen(transport.live(appliedSince: () => 0));
    addTearDown(probe.subscription.cancel);
    await server.waitForRequests(2, timeout: const Duration(seconds: 1));
    expect(probe.done, isFalse);
  });

  test('reconnect backoff grows and does not exceed the cap', () async {
    final server = await _bind([
      const ScriptedReply.sse(),
      const ScriptedReply.sse(),
      const ScriptedReply.sse(),
      const ScriptedReply.sse(),
    ]);
    final transport = _transport(
      server,
      reconnectInitial: const Duration(milliseconds: 50),
      reconnectCap: const Duration(milliseconds: 200),
      addJitter: _noJitter,
    );
    final probe = _LiveProbe.listen(transport.live(appliedSince: () => 0));
    addTearDown(probe.subscription.cancel);
    await server.waitForRequests(4, timeout: const Duration(seconds: 2));
    final times = server.requests.map((r) => r.receivedAt).toList();
    final intervals = [
      times[1].difference(times[0]),
      times[2].difference(times[1]),
      times[3].difference(times[2]),
    ];
    expect(intervals[0], greaterThan(const Duration(milliseconds: 20)));
    expect(intervals[1], greaterThan(intervals[0]));
    const slack = Duration(milliseconds: 80);
    expect(
      intervals.every((d) => d <= const Duration(milliseconds: 200) + slack),
      isTrue,
      reason: 'intervals $intervals',
    );
  });

  test('reconnect uses the appliedSince cursor from the engine, not zero and '
      'not last-seen', () async {
    final envelope = jsonEncode(_pageEnvelope(serverSeq: 100));
    final server = await _bind([
      ScriptedReply.sse(
        chunks: [
          _sseEvent('envelope', envelope),
          _sseEvent('cursor', '{"next_cursor":100}'),
        ],
      ),
      const ScriptedReply.sse(holdOpen: true),
    ]);
    final transport = _transport(server);
    var calls = 0;
    final probe = _LiveProbe.listen(
      transport.live(
        appliedSince: () {
          calls++;
          return 7;
        },
      ),
    );
    addTearDown(probe.subscription.cancel);
    await server.waitForRequests(2);
    expect(server.requests[0].query['since'], '7');
    expect(server.requests[1].query['since'], '7');
    expect(server.requests[1].query['since'], isNot('0'));
    expect(server.requests[1].query['since'], isNot('100'));
    expect(calls, greaterThanOrEqualTo(2));
  });

  test(
    'close completes the live stream and later calls throw StateError',
    () async {
      final server = await _bind([const ScriptedReply.sse(holdOpen: true)]);
      final transport = _transport(server);
      final probe = _LiveProbe.listen(transport.live(appliedSince: () => 0));
      await server.waitForRequests(1);
      await transport.close();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (!probe.done && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(probe.done, isTrue);
      await expectLater(
        transport.push([_minimalEnvelope()]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
      await transport.close();
    },
  );

  test('readable exp reopens before expiry and unreadable exp does not reopen '
      'immediately', () async {
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final expSeconds = nowMs ~/ 1000 + 2;
    final token = _mintJwt(expSeconds: expSeconds);
    expect(readJwtExpiry(token), isNotNull);

    final expServer = await _bind([
      const ScriptedReply.sse(holdOpen: true),
      const ScriptedReply.sse(holdOpen: true),
    ]);
    final expTransport = _transport(
      expServer,
      tokenProvider: () async => token,
      reopenBeforeExpiry: const Duration(milliseconds: 801),
      silenceTimeout: const Duration(seconds: 30),
    );
    final expProbe = _LiveProbe.listen(
      expTransport.live(appliedSince: () => 0),
    );
    addTearDown(expProbe.subscription.cancel);
    final expStarted = DateTime.now();
    await expServer.waitForRequests(2, timeout: const Duration(seconds: 3));
    final expWait = DateTime.now().difference(expStarted);
    expect(expWait, greaterThan(const Duration(milliseconds: 50)));
    expect(expWait, lessThan(const Duration(seconds: 3)));
    expect(expProbe.done, isFalse);

    final unreadServer = await _bind([
      const ScriptedReply.sse(holdOpen: true),
      const ScriptedReply.sse(holdOpen: true),
    ]);
    final unreadTransport = _transport(
      unreadServer,
      tokenProvider: () async => 'not-a-jwt',
      unreadableExpInterval: const Duration(milliseconds: 400),
      silenceTimeout: const Duration(seconds: 30),
    );
    final unreadProbe = _LiveProbe.listen(
      unreadTransport.live(appliedSince: () => 0),
    );
    addTearDown(unreadProbe.subscription.cancel);
    final unreadStarted = DateTime.now();
    await unreadServer.waitForRequests(2, timeout: const Duration(seconds: 2));
    final unreadWait = DateTime.now().difference(unreadStarted);
    expect(unreadWait, greaterThanOrEqualTo(const Duration(milliseconds: 300)));
    expect(unreadWait, lessThan(const Duration(seconds: 2)));
    expect(unreadProbe.done, isFalse);
  });

  test(
    'stable connection longer than stableConnection resets backoff to initial',
    () async {
      final server = await _bind([
        const ScriptedReply.sse(closeAfter: Duration(milliseconds: 120)),
        const ScriptedReply.sse(holdOpen: true),
      ]);
      final transport = _transport(
        server,
        stableConnection: const Duration(milliseconds: 80),
        reconnectInitial: const Duration(milliseconds: 50),
        reconnectCap: const Duration(milliseconds: 400),
        addJitter: _noJitter,
      );
      final probe = _LiveProbe.listen(transport.live(appliedSince: () => 0));
      addTearDown(probe.subscription.cancel);
      await server.waitForRequests(2, timeout: const Duration(seconds: 2));
      final gap = server.requests[1].receivedAt.difference(
        server.requests[0].receivedAt,
      );
      // Held ~120ms, then initial 50ms — not a doubled 100ms on top of 120.
      expect(gap, lessThan(const Duration(milliseconds: 280)));
      expect(gap, greaterThan(const Duration(milliseconds: 120)));
    },
  );

  test('second live() throws StateError while the first stream is alive', () {
    final transport = HttpSyncTransport(
      baseUrl: Uri.parse('http://127.0.0.1:1'),
      tokenProvider: () async => 'token',
    );
    addTearDown(transport.close);
    transport.live(appliedSince: () => 0);
    expect(
      () => transport.live(appliedSince: () => 0),
      throwsA(isA<StateError>()),
    );
  });
}
