/// Illegal instance names fail before the database or the network.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync/ulsync.dart';

import 'fake_sync_transport.dart';

const _origin = 'com.example.app/7c3e9a12-4b56-4d8e-9f01-2a3b4c5d6e7f';

void main() {
  test(
    'illegal instance name throws ArgumentError and does not touch the network',
    () async {
      final fake = FakeSyncTransport();
      fake.onPush = (_) async {
        fail('network must not be used for an illegal name');
      };
      fake.onPull = ({required int since, int? limit}) async {
        fail('network must not be used for an illegal name');
      };

      Future<UlsyncClient> open(String name) {
        return UlsyncClient.open(
          name: name,
          baseUrl: Uri.parse('http://open-name.test'),
          origin: _origin,
          userScope: 'alice',
          sourceId: 'device-a',
          tokenProvider: () async => 'test-token',
          adapters: [
            EntityAdapter<String>(
              entityType: 'note',
              schemaVersion: 1,
              encode: (text) => throw StateError('unused'),
              decode: (bytes, schemaVersion) => throw StateError('unused'),
              load: (id) async => null,
              apply: (value, meta) async {},
              listIds: () async => const [],
            ),
          ],
          transport: fake,
          inMemory: true,
        );
      }

      await expectLater(open(''), throwsA(isA<ArgumentError>()));
      await expectLater(open('..'), throwsA(isA<ArgumentError>()));
      await expectLater(open('a/b'), throwsA(isA<ArgumentError>()));
      expect(fake.pushCalls, isEmpty);
      expect(fake.pullCalls, isEmpty);
    },
  );
}
