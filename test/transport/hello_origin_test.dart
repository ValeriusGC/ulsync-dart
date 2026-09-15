@TestOn('vm')
/// HTTP hello (SPEC section 3.5) and `Ulsync-Origin` on mail requests.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync/ulsync.dart';

import 'json_map.dart';
import 'scripted_http_server.dart';

const _origin = 'com.example.app/7c3e9a12-4b56-4d8e-9f01-2a3b4c5d6e7f';
const _submoduleHint = 'git submodule update --init';

String _fixture(String relative) {
  final path = 'protocol/fixtures/$relative';
  expect(File(path).existsSync(), isTrue, reason: _submoduleHint);
  return File(path).readAsStringSync();
}

Future<ScriptedHttpServer> _bind(List<ScriptedReply> replies) async {
  final server = await ScriptedHttpServer.start(replies);
  addTearDown(server.close);
  return server;
}

HttpSyncTransport _transport(ScriptedHttpServer server) {
  final transport = HttpSyncTransport(
    baseUrl: server.baseUrl,
    origin: _origin,
    tokenProvider: () async => 'token',
    pushPullTimeout: const Duration(seconds: 5),
  );
  addTearDown(transport.close);
  return transport;
}

void main() {
  test('hello 200 parses the origin fixture', () async {
    final server = await _bind([
      ScriptedReply.json(
        status: 200,
        body: _fixture('origin/hello_response.json'),
        path: '/v1/sync/hello',
      ),
    ]);
    final transport = _transport(server);
    final result = await transport.hello(_origin);
    expect(result, isNotNull);
    expect(result!.origin, _origin);
    expect(result.userId, 'alice');
    expect(server.requests.single.method, 'GET');
    expect(server.requests.single.path, '/v1/sync/hello');
    expect(server.requests.single.ulsyncOrigin, _origin);
  });

  test('hello returns null on HTTP 404 and 405', () async {
    final server = await _bind([
      const ScriptedReply.json(
        status: 404,
        body: 'not found',
        path: '/v1/sync/hello',
      ),
    ]);
    final transport = _transport(server);
    expect(await transport.hello(_origin), isNull);

    final methodServer = await _bind([
      const ScriptedReply.json(
        status: 405,
        body: 'nope',
        path: '/v1/sync/hello',
      ),
    ]);
    final methodTransport = _transport(methodServer);
    expect(await methodTransport.hello(_origin), isNull);
  });

  test(
    'hello 409 throws OriginMismatchException with both fixture fields',
    () async {
      final body = _fixture('origin/mismatch.json');
      final expected = decodeJsonMap(body);
      final server = await _bind([
        ScriptedReply.json(status: 409, body: body, path: '/v1/sync/hello'),
      ]);
      final transport = _transport(server);
      await expectLater(
        transport.hello(_origin),
        throwsA(
          isA<OriginMismatchException>()
              .having(
                (e) => e.storeOrigin,
                'storeOrigin',
                expected['store_origin'],
              )
              .having(
                (e) => e.requestOrigin,
                'requestOrigin',
                expected['request_origin'],
              ),
        ),
      );
    },
  );

  test('push sends Ulsync-Origin matching the constructor origin', () async {
    final server = await _bind([
      ScriptedReply.json(
        status: 200,
        body: _fixture('push/response_applied.json'),
      ),
    ]);
    final transport = _transport(server);
    final envelope = Envelope.fromJson(
      decodeJsonMap(_fixture('envelope/minimal.json')),
    );
    await transport.push([envelope]);
    expect(server.requests.single.path, '/v1/sync/push');
    expect(server.requests.single.ulsyncOrigin, _origin);
  });

  test('HttpSyncTransport rejects an illegal origin without a request', () {
    expect(
      () => HttpSyncTransport(
        baseUrl: Uri.parse('http://127.0.0.1:1'),
        origin: '',
        tokenProvider: () async => 'token',
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}
