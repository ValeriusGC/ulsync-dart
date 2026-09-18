/// Origin handshake: constructor, hello-before-self-check, one-shot, live.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:ulsync/src/store/entity_state.dart';
import 'package:ulsync/src/store/sembast_metadata_store.dart';
import 'package:ulsync/ulsync.dart';

import 'fake_hello_transport.dart';
import 'fake_sync_transport.dart';

const _origin = 'com.example.app/7c3e9a12-4b56-4d8e-9f01-2a3b4c5d6e7f';

var _pathCounter = 0;

/// In-memory metadata file plus the instance name [UlsyncClient.open] uses.
final class _Db {
  /// Creates a named in-memory store handle.
  _Db({required this.name, required this.store});

  /// Instance name, also the memory-database key.
  final String name;

  /// Direct store handle for seeding.
  final SembastMetadataStore store;
}

Future<_Db> _openStore() async {
  final factory = databaseFactoryMemory;
  final name = 'origin_handshake_${_pathCounter++}';
  await factory.deleteDatabase(name);
  final store = await SembastMetadataStore.open(
    databasePath: name,
    factory: factory,
  );
  addTearDown(() async {
    await factory.deleteDatabase(name);
  });
  return _Db(name: name, store: store);
}

final class _Memo {
  const _Memo({required this.id, required this.text});

  final String id;
  final String text;
}

Uint8List _memoBytes({required String id, required String text}) {
  return Uint8List.fromList(utf8.encode(jsonEncode({'id': id, 'text': text})));
}

_Memo _memoFrom(Uint8List bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  final map = Map<String, Object?>.from(decoded as Map);
  return _Memo(id: map['id']! as String, text: map['text']! as String);
}

EntityAdapter<_Memo> _adapter({
  required Map<String, String> appStore,
  Future<List<String>> Function()? listIds,
  int Function()? onListIds,
}) {
  final enumerate = listIds ?? () async => appStore.keys.toList();
  return EntityAdapter<_Memo>(
    entityType: 'note',
    schemaVersion: 1,
    encode: (memo) => _memoBytes(id: memo.id, text: memo.text),
    decode: (bytes, schemaVersion) => _memoFrom(bytes),
    load: (id) async {
      final text = appStore[id];
      if (text == null) {
        return null;
      }
      return _Memo(id: id, text: text);
    },
    apply: (memo, meta) async {
      appStore[memo.id] = memo.text;
    },
    listIds: () async {
      onListIds?.call();
      return enumerate();
    },
  );
}

Future<UlsyncClient> _client({
  required String name,
  required SyncTransport transport,
  required EntityAdapter<_Memo> adapter,
  String origin = _origin,
  String userScope = 'alice',
  String sourceId = 'device-a',
}) async {
  final client = await UlsyncClient.open(
    name: name,
    baseUrl: Uri.parse('http://origin.test'),
    origin: origin,
    userScope: userScope,
    sourceId: sourceId,
    tokenProvider: () async => 'test-token',
    adapters: [adapter],
    transport: transport,
    inMemory: true,
  );
  addTearDown(client.close);
  return client;
}

Future<void> _pumpUntil(bool Function() condition, {int max = 50}) async {
  for (var i = 0; i < max; i++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition not met after $max event-loop yields');
}

void main() {
  test(
    'empty or illegal origin throws ArgumentError and does not call hello',
    () async {
      final fake = FakeHelloTransport();
      final adapter = _adapter(appStore: {});

      Future<UlsyncClient> build(String origin) {
        return UlsyncClient.open(
          name: 'origin_illegal',
          baseUrl: Uri.parse('http://origin.test'),
          origin: origin,
          userScope: 'alice',
          sourceId: 'device-a',
          tokenProvider: () async => 'test-token',
          adapters: [adapter],
          transport: fake,
          inMemory: true,
        );
      }

      await expectLater(build(''), throwsA(isA<ArgumentError>()));
      await expectLater(build('   '), throwsA(isA<ArgumentError>()));
      await expectLater(build('has space'), throwsA(isA<ArgumentError>()));
      await expectLater(build('bad@char'), throwsA(isA<ArgumentError>()));
      await expectLater(build('a' * 257), throwsA(isA<ArgumentError>()));
      expect(fake.helloCalls, isEmpty);
      expect(fake.callOrder, isEmpty);
    },
  );

  test('hello null lets syncOnce reach push and pull', () async {
    final db = await _openStore();
    final fake = FakeHelloTransport();
    fake.onHello = (_) async => null;
    final appStore = <String, String>{'e1': 'hello'};
    final client = await _client(
      name: db.name,
      transport: fake,
      adapter: _adapter(appStore: appStore),
    );
    await client.markChanged(entityType: 'note', id: 'e1');
    final report = await client.syncOnce();
    expect(report.pushed, 1);
    expect(fake.helloCalls, hasLength(1));
    expect(fake.pushCalls, hasLength(1));
    expect(fake.pullCalls, isNotEmpty);
  });

  test('hello 409 throws OriginMismatchException before self-check', () async {
    var listCalls = 0;
    final db = await _openStore();
    final fake = FakeHelloTransport();
    fake.onHello = (_) async {
      throw OriginMismatchException(
        storeOrigin: _origin,
        requestOrigin: 'com.example.other/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
      );
    };
    final client = await _client(
      name: db.name,
      transport: fake,
      adapter: _adapter(
        appStore: {'e1': 'hello'},
        listIds: () async => ['e1'],
        onListIds: () => listCalls++,
      ),
    );
    await expectLater(
      client.syncOnce(),
      throwsA(
        isA<OriginMismatchException>()
            .having((e) => e.storeOrigin, 'storeOrigin', _origin)
            .having(
              (e) => e.requestOrigin,
              'requestOrigin',
              'com.example.other/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
            ),
      ),
    );
    expect(listCalls, 0);
    expect(fake.diffCalls, isEmpty);
    expect(fake.pushCalls, isEmpty);
    expect(fake.pullCalls, isEmpty);
    expect(fake.helloCalls, hasLength(1));
    await expectLater(
      client.syncOnce(),
      throwsA(isA<OriginMismatchException>()),
    );
    expect(fake.helloCalls, hasLength(2));
    expect(fake.diffCalls, isEmpty);
  });

  test('hello is recorded before the first diff and the first push', () async {
    var listCalls = 0;
    final db = await _openStore();
    await db.store.put(
      EntityState(
        userScope: 'alice',
        entityType: 'note',
        id: 'e1',
        part: 'full',
        createdAtMs: 1,
        lastEditedAtMs: 1,
        revision: 1,
        sourceId: 'device-a',
        schemaVersion: 1,
        dirty: false,
      ),
    );
    final fake = FakeHelloTransport();
    final appStore = <String, String>{'e1': 'clean', 'e2': 'dirty'};
    final client = await _client(
      name: db.name,
      transport: fake,
      adapter: _adapter(
        appStore: appStore,
        listIds: () async => ['e1', 'e2'],
        onListIds: () => listCalls++,
      ),
    );
    await client.markChanged(entityType: 'note', id: 'e2');
    await client.syncOnce();
    expect(listCalls, 1);
    expect(fake.callOrder.first, 'hello');
    final diffAt = fake.callOrder.indexOf('diff');
    final pushAt = fake.callOrder.indexOf('push');
    expect(diffAt, greaterThan(0));
    expect(pushAt, greaterThan(0));
    expect(fake.callOrder.indexOf('hello'), lessThan(diffAt));
    expect(fake.callOrder.indexOf('hello'), lessThan(pushAt));
  });

  test('two syncOnce calls invoke hello once', () async {
    final db = await _openStore();
    final fake = FakeHelloTransport();
    final client = await _client(
      name: db.name,
      transport: fake,
      adapter: _adapter(appStore: {}),
    );
    await client.syncOnce();
    await client.syncOnce();
    expect(fake.helloCalls, hasLength(1));
  });

  test('failed hello is retried on the next syncOnce', () async {
    final db = await _openStore();
    final fake = FakeHelloTransport();
    var hellos = 0;
    fake.onHello = (_) async {
      hellos++;
      if (hellos == 1) {
        throw const UlsyncNetworkException('offline');
      }
      return HelloResult(origin: _origin, userId: 'alice');
    };
    final client = await _client(
      name: db.name,
      transport: fake,
      adapter: _adapter(appStore: {}),
    );
    await expectLater(
      client.syncOnce(),
      throwsA(isA<UlsyncNetworkException>()),
    );
    expect(fake.helloCalls, hasLength(1));
    await client.syncOnce();
    expect(fake.helloCalls, hasLength(2));
  });

  test('live on 409 throws and does not open the feed', () async {
    final db = await _openStore();
    final fake = FakeHelloTransport();
    fake.onHello = (_) async {
      throw OriginMismatchException(
        storeOrigin: _origin,
        requestOrigin: 'com.example.other/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
      );
    };
    final client = await _client(
      name: db.name,
      transport: fake,
      adapter: _adapter(appStore: {}),
    );
    Object? error;
    final sub = client.live().listen(
      (_) {},
      onError: (Object e, StackTrace _) {
        error = e;
      },
    );
    addTearDown(sub.cancel);
    await _pumpUntil(() => error != null);
    expect(error, isA<OriginMismatchException>());
    expect(fake.liveCalls, 0);
    expect(fake.callOrder, ['hello']);
  });

  test('transport without SyncHelloTransport still exchanges', () async {
    final db = await _openStore();
    final fake = FakeSyncTransport();
    final appStore = <String, String>{'e1': 'hello'};
    final client = await _client(
      name: db.name,
      transport: fake,
      adapter: _adapter(appStore: appStore),
    );
    await client.markChanged(entityType: 'note', id: 'e1');
    final report = await client.syncOnce();
    expect(report.pushed, 1);
    expect(fake.pushCalls, hasLength(1));
  });

  test(
    'second client with another userScope and the same origin leaves the first intact',
    () async {
      final dbA = await _openStore();
      final dbB = await _openStore();
      final fakeA = FakeHelloTransport();
      final fakeB = FakeHelloTransport();
      final appA = <String, String>{'e1': 'alice-row'};
      final clientA = await _client(
        name: dbA.name,
        transport: fakeA,
        adapter: _adapter(appStore: appA),
        userScope: 'alice',
      );
      final clientB = await _client(
        name: dbB.name,
        transport: fakeB,
        adapter: _adapter(appStore: {}),
        userScope: 'bob',
        sourceId: 'device-b',
      );
      await clientA.markChanged(entityType: 'note', id: 'e1');
      await clientA.syncOnce();
      expect(fakeA.pushCalls, hasLength(1));
      await clientB.syncOnce();
      expect(clientA.origin, clientB.origin);
      expect(fakeA.helloCalls, [_origin]);
      expect(fakeB.helloCalls, [_origin]);
      final again = await clientA.syncOnce();
      expect(again.pushed, 0);
      expect(fakeA.pushCalls, hasLength(1));
      expect(fakeA.helloCalls, hasLength(1));
    },
  );

  test('write does not call hello', () async {
    final db = await _openStore();
    final fake = FakeHelloTransport();
    final appStore = <String, String>{};
    final client = await _client(
      name: db.name,
      transport: fake,
      adapter: _adapter(appStore: appStore),
    );
    await client.write(
      entityType: 'note',
      id: 'e1',
      persist: () async {
        appStore['e1'] = 'kept-local';
      },
    );
    expect(fake.helloCalls, isEmpty);
    expect(appStore['e1'], 'kept-local');
  });
}
