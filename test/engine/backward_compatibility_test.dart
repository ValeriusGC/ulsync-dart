@TestOn('vm')
/// Pins the round-1 public constructors. A new required argument fails this file.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync/ulsync.dart';

import '../transport/json_map.dart';
import '../transport/scripted_http_server.dart';

void main() {
  test(
    'EntityAdapter and UlsyncClient still construct with the round-1 arguments and markChanged still reaches the transport',
    () async {
      final dir = await Directory.systemTemp.createTemp('ulsync_compat_');
      addTearDown(() => dir.delete(recursive: true));

      final appStore = <String, String>{};
      // Exact named arguments from triad plan §13.8. Adding a required field
      // here is the day this test must stop compiling.
      final adapter = EntityAdapter<String>(
        entityType: 'note',
        schemaVersion: 1,
        encode: (text) => Uint8List.fromList(utf8.encode(text)),
        decode: (bytes, schemaVersion) => utf8.decode(bytes),
        load: (id) async => appStore[id],
        apply: (text) async {
          appStore['applied'] = text;
        },
      );

      final server = await ScriptedHttpServer.start([
        ScriptedReply.json(
          status: 200,
          body: jsonEncode({
            'results': [
              {'id': 'e1', 'part': 'full', 'applied': true},
            ],
          }),
        ),
        const ScriptedReply.json(
          status: 200,
          body: '{"envelopes":[],"next_cursor":0}',
        ),
      ]);
      addTearDown(server.close);

      final store = await SembastMetadataStore.open(
        databasePath: '${dir.path}/ulsync.db',
      );

      final client = UlsyncClient(
        baseUrl: server.baseUrl,
        userScope: 'alice',
        sourceId: 'device-a',
        tokenProvider: () async => 'test-token',
        store: store,
        adapters: [adapter],
      );
      addTearDown(client.close);

      appStore['e1'] = 'hello-compat';
      await client.markChanged(entityType: 'note', id: 'e1');
      final report = await client.syncOnce();

      expect(report.pushed, 1);
      expect(report.accepted, 1);
      final push = server.requests.firstWhere(
        (request) => request.path == '/v1/sync/push',
      );
      expect(push.method, 'POST');
      final body = decodeJsonMap(push.body);
      final envelopes = body['envelopes']! as List<dynamic>;
      expect(envelopes, hasLength(1));
      final envelope = Map<String, Object?>.from(envelopes.single as Map);
      expect(envelope['id'], 'e1');
      expect(envelope['entity_type'], 'note');
      final payload = envelope['payload']! as String;
      expect(payload, isNotEmpty);
      expect(utf8.decode(base64Decode(payload)), 'hello-compat');
    },
  );
}
